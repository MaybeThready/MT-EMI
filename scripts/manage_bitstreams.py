"""Interactive archive manager for MT-EMI Gowin bitstreams."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import uuid
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path


KNOWN_FILES = {
    "bitstream.fs",
    "metadata.json",
    "timing.tr",
    "pnr_report.txt",
    "placement.p",
    "physical.cst",
    "timing.sdc",
}
REPORT_FILES = {
    "MT-EMI.tr": "timing.tr",
    "MT-EMI.rpt.txt": "pnr_report.txt",
    "MT-EMI.p": "placement.p",
}
INVALID_NAME = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
RESERVED_NAME = re.compile(r"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", re.I)


def read_text(path: Path) -> str:
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def report_field(text: str, label: str) -> str:
    match = re.search(rf"(?m)^\s*<{re.escape(label)}>\s*:\s*(.+?)\s*$", text)
    return match.group(1).strip() if match else ""


def report_count(text: str, label: str) -> int | None:
    value = report_field(text, label)
    return int(value) if value.isdigit() else None


def worst_slack(text: str, heading: str, next_heading: str) -> float | None:
    start = text.rfind(heading)
    if start < 0:
        return None
    end = text.find(next_heading, start + len(heading))
    section = text[start : end if end >= 0 else None]
    match = re.search(r"(?m)^Slack\s*:\s*(-?\d+(?:\.\d+)?)", section)
    return float(match.group(1)) if match else None


def git_value(root: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def local_time(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp).astimezone().isoformat()


def valid_name(name: str) -> bool:
    return bool(
        name
        and len(name) <= 64
        and name not in {".", ".."}
        and not name.endswith((".", " "))
        and not INVALID_NAME.search(name)
        and not RESERVED_NAME.fullmatch(name)
    )


class ArchiveManager:
    def __init__(self, project_root: Path) -> None:
        self.root = project_root.resolve()
        self.archive_root = self.root / "assets" / "fs"
        self.pnr_root = self.root / "impl" / "pnr"

    def project_files(self, bitstream_time: float) -> tuple[list[str], list[str], list[str]]:
        project_path = self.root / "MT-EMI.gprj"
        cst: list[str] = []
        sdc: list[str] = []
        newer: list[str] = []
        if not project_path.is_file():
            return cst, sdc, newer
        project = ET.parse(project_path)
        for file in project.findall("./FileList/File"):
            if file.get("enable") != "1":
                continue
            file_type = file.get("type")
            relative = file.get("path", "")
            if file_type == "file.cst":
                cst.append(relative)
            elif file_type == "file.sdc":
                sdc.append(relative)
            if file_type not in {"file.verilog", "file.cst", "file.sdc"}:
                continue
            source = self.root / relative
            if source.is_file() and source.stat().st_mtime > bitstream_time + 1:
                newer.append(relative)
        if project_path.stat().st_mtime > bitstream_time + 1:
            newer.append("MT-EMI.gprj")
        return cst, sdc, newer

    def build_metadata(self, bitstream: Path) -> dict:
        report = read_text(self.pnr_root / "MT-EMI.rpt.txt")
        timing = read_text(self.pnr_root / "MT-EMI.tr")
        synthesis_log = self.root / "impl" / "gwsynthesis" / "MT-EMI.log"
        tops = re.findall(r'Current top module is "([^"]+)"', read_text(synthesis_log))
        built_at = bitstream.stat().st_mtime
        top = "未知"
        if tops and synthesis_log.stat().st_mtime <= built_at + 60:
            top = tops[-1]
        cst, sdc, newer = self.project_files(built_at)
        return {
            "format_version": 1,
            "saved_at": datetime.now().astimezone().isoformat(),
            "top_module": top,
            "bitstream_built_at": local_time(built_at),
            "bitstream_bytes": bitstream.stat().st_size,
            "bitstream_sha256": "",
            "part_number": report_field(report, "Part Number"),
            "device": report_field(report, "Device"),
            "device_version": report_field(report, "Device Version"),
            "tool_version": report_field(report, "Tool Version"),
            "build_physical_constraint": report_field(report, "Physical Constraints File"),
            "build_timing_constraint": report_field(report, "Timing Constraints File"),
            "project_active_cst_at_save": cst,
            "project_active_sdc_at_save": sdc,
            "setup_violated_endpoints": report_count(timing, "Numbers of Setup Violated Endpoints"),
            "hold_violated_endpoints": report_count(timing, "Numbers of Hold Violated Endpoints"),
            "worst_setup_slack_ns": worst_slack(timing, "3.3.1 Setup Analysis Report", "3.3.2 Hold Analysis Report"),
            "worst_hold_slack_ns": worst_slack(timing, "3.3.2 Hold Analysis Report", "3.3.3 Recovery Analysis Report"),
            "git_commit_at_save": git_value(self.root, "rev-parse", "HEAD"),
            "git_branch_at_save": git_value(self.root, "branch", "--show-current"),
            "git_dirty_at_save": bool(git_value(self.root, "status", "--porcelain")),
            "files_newer_than_bitstream": newer,
            "archived_files": [],
        }

    def copy_constraint(self, reported: str, destination: Path, bitstream_time: float) -> bool:
        if not reported:
            return False
        try:
            source = Path(reported).resolve(strict=True)
            source.relative_to(self.root)
        except (OSError, ValueError):
            return False
        if not source.is_file() or source.stat().st_mtime > bitstream_time + 1:
            return False
        shutil.copy2(source, destination)
        return True

    def archive_contents(self, directory: Path, *, require_metadata: bool = True) -> list[Path]:
        # Used before replacing or deleting a directory; never traverse arbitrary trees.
        if directory.parent != self.archive_root or directory.is_symlink() or not directory.is_dir():
            raise ValueError("归档目录不在 assets/fs 的直接子目录内。")
        children = list(directory.iterdir())
        if require_metadata and not (directory / "metadata.json").is_file():
            raise ValueError("目录不是脚本创建的归档，已停止操作。")
        if any(child.name not in KNOWN_FILES or child.is_symlink() or not child.is_file() for child in children):
            raise ValueError("目录中有额外文件、子目录或链接，已停止操作。")
        return children

    def remove_archive_directory(self, directory: Path, *, require_metadata: bool = True) -> None:
        for child in self.archive_contents(directory, require_metadata=require_metadata):
            child.unlink()
        directory.rmdir()

    def next_name(self, base: str) -> str:
        number = 1
        while True:
            suffix = f"({number})"
            candidate = base[: 64 - len(suffix)] + suffix
            if not (self.archive_root / candidate).exists():
                return candidate
            number += 1

    def save(self) -> None:
        source = self.pnr_root / "MT-EMI.fs"
        if not source.is_file() or source.stat().st_size == 0:
            print("找不到有效的 impl/pnr/MT-EMI.fs，请先完成 Gowin 布局布线。")
            return
        name = input("请输入保存名（最多 64 字符）：").strip()
        if not valid_name(name):
            print("保存名无效。")
            return
        self.archive_root.mkdir(parents=True, exist_ok=True)
        target = self.archive_root / name
        overwrite = False
        if target.exists():
            print(f"'{name}' 已存在：1. 覆盖保存  2. 自动添加编号  0. 取消")
            choice = input("请选择：").strip()
            if choice == "1":
                self.archive_contents(target)
                overwrite = True
            elif choice == "2":
                name = self.next_name(name)
                target = self.archive_root / name
                print(f"将保存为：{name}")
            else:
                print("已取消保存。")
                return

        temporary = Path(tempfile.mkdtemp(prefix=".tmp-", dir=self.archive_root))
        backup: Path | None = None
        try:
            before = source.stat()
            metadata = self.build_metadata(source)
            saved_fs = temporary / "bitstream.fs"
            shutil.copy2(source, saved_fs)
            after = source.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise RuntimeError("保存过程中 Gowin 更新了位流，请等构建完成后重试。")
            metadata["bitstream_sha256"] = sha256(saved_fs)
            metadata["archived_files"].append("bitstream.fs")
            for source_name, saved_name in REPORT_FILES.items():
                report = self.pnr_root / source_name
                if report.is_file():
                    shutil.copy2(report, temporary / saved_name)
                    metadata["archived_files"].append(saved_name)
            for key, saved_name in (
                ("build_physical_constraint", "physical.cst"),
                ("build_timing_constraint", "timing.sdc"),
            ):
                if self.copy_constraint(metadata[key], temporary / saved_name, before.st_mtime):
                    metadata["archived_files"].append(saved_name)
            metadata["archived_files"].append("metadata.json")
            (temporary / "metadata.json").write_text(
                json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
            if overwrite:
                backup = self.archive_root / f".backup-{uuid.uuid4().hex}"
                target.rename(backup)
            try:
                temporary.rename(target)
            except OSError:
                if backup is not None:
                    backup.rename(target)
                    backup = None
                raise
            if backup is not None:
                self.remove_archive_directory(backup)
                backup = None
            print(f"已保存：{target}")
            print(f"顶层：{metadata['top_module']}；SHA256：{metadata['bitstream_sha256']}")
            if metadata["files_newer_than_bitstream"]:
                count = len(metadata["files_newer_than_bitstream"])
                print(f"注意：有 {count} 个工程文件比位流新，当前源码可能并非该位流的构建版本。")
        finally:
            if temporary.exists():
                self.remove_archive_directory(temporary, require_metadata=False)

    def archives(self) -> list[Path]:
        if not self.archive_root.is_dir():
            return []
        return sorted(
            (path for path in self.archive_root.iterdir()
             if path.is_dir() and not path.is_symlink()
             and not path.name.startswith((".tmp-", ".backup-"))
             and (path / "metadata.json").is_file()),
            key=lambda path: path.name.casefold(),
        )

    def select(self) -> Path | None:
        archives = self.archives()
        if not archives:
            print("尚无已保存的布线。")
            return None
        print()
        for index, archive in enumerate(archives, 1):
            try:
                top = json.loads((archive / "metadata.json").read_text(encoding="utf-8-sig")).get("top_module", "?")
            except (OSError, ValueError):
                top = "元数据损坏"
            print(f"{index:3}. {archive.name}  [顶层: {top}]")
        choice = input("请选择编号（回车取消）：").strip()
        if not choice:
            return None
        if not choice.isdigit() or not 1 <= int(choice) <= len(archives):
            print("编号无效。")
            return None
        return archives[int(choice) - 1]

    def show(self) -> None:
        archive = self.select()
        if archive is None:
            return
        metadata = json.loads((archive / "metadata.json").read_text(encoding="utf-8-sig"))
        bitstream = archive / "bitstream.fs"
        if not bitstream.is_file():
            integrity = "位流缺失"
        elif sha256(bitstream) == metadata.get("bitstream_sha256"):
            integrity = "SHA256 校验通过"
        else:
            integrity = "SHA256 不匹配，请勿烧录"
        field = lambda key: metadata.get(key) if metadata.get(key) is not None else "未知"
        print(f"\n名称：{archive.name}")
        print(f"顶层模块：{field('top_module')}")
        print(f"保存时间：{field('saved_at')}")
        print(f"位流生成时间：{field('bitstream_built_at')}")
        print(f"位流大小：{field('bitstream_bytes')} 字节")
        print(f"完整性：{integrity}")
        print(f"位流文件：{bitstream}")
        print(f"器件：{field('part_number')}；版本：{field('device_version')}")
        print(f"Gowin 版本：{field('tool_version')}")
        print(f"构建使用的 CST：{field('build_physical_constraint')}")
        print(f"构建使用的 SDC：{field('build_timing_constraint')}")
        print("归档时工程启用的 CST：" + ", ".join(metadata.get("project_active_cst_at_save") or []))
        print("归档时工程启用的 SDC：" + ", ".join(metadata.get("project_active_sdc_at_save") or []))
        print(f"Setup 违例端点：{field('setup_violated_endpoints')}；最差余量：{field('worst_setup_slack_ns')} ns")
        print(f"Hold 违例端点：{field('hold_violated_endpoints')}；最差余量：{field('worst_hold_slack_ns')} ns")
        print(f"归档时 Git：{field('git_branch_at_save')} {field('git_commit_at_save')}；未提交更改：{field('git_dirty_at_save')}")
        newer = metadata.get("files_newer_than_bitstream") or []
        print(f"比位流更新的工程文件数：{len(newer)}")
        if newer:
            print("其中：" + ", ".join(newer[:8]))
        print("附带文件：" + ", ".join(metadata.get("archived_files") or []))
        print("读取归档不会替换当前工程输出；可在 Gowin Programmer 中选择该 .fs 烧录。")

    def delete(self) -> None:
        archive = self.select()
        if archive is None:
            return
        self.archive_contents(archive)
        answer = input(f"确认删除 '{archive.name}'？请完整输入保存名：")
        if answer != archive.name:
            print("已取消删除。")
            return
        self.remove_archive_directory(archive)
        print(f"已删除：{archive.name}")

    def menu(self) -> None:
        while True:
            print("\n==== MT-EMI 布线归档 ====")
            print("1. 保存布线\n2. 读取布线信息\n3. 删除布线\n0. 退出")
            try:
                choice = input("请选择：").strip()
                if choice == "0":
                    return
                action = {"1": self.save, "2": self.show, "3": self.delete}.get(choice)
                if action is None:
                    print("请输入 0、1、2 或 3。")
                else:
                    action()
            except EOFError:
                return
            except (OSError, ValueError, RuntimeError, ET.ParseError) as exc:
                print(f"操作失败：{exc}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="项目根目录；默认是脚本所在目录的上级")
    args = parser.parse_args()
    ArchiveManager(args.project_root).menu()


if __name__ == "__main__":
    main()
