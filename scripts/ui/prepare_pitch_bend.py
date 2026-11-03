"""弯音比例表生成，表值使用 60 位 Decimal 运算。"""
from pathlib import Path
from datetime import datetime
from decimal import Decimal, localcontext, ROUND_HALF_UP
import hashlib
import json
import shutil

WORK = Path(__file__).resolve().parents[2]
STAMP = datetime.now().strftime("%Y%m%d_%H%M%S")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def backup(path):
    if path.exists():
        history = path.parent / "history"
        history.mkdir(exist_ok=True)
        shutil.copy2(path, history / (STAMP + "_" + path.name))


def generate_table():
    with localcontext() as context:
        context.prec = 60
        nodes = []
        for index in range(257):
            position = min(index * 256, 65535)
            denominator = 32768 if position <= 32768 else 32767
            exponent = Decimal(position - 32768) / Decimal(denominator * 6)
            ratio = (Decimal(2).ln() * exponent).exp() * Decimal(131072)
            nodes.append(int(ratio.to_integral_value(rounding=ROUND_HALF_UP)))
    assert nodes[128] == 131072
    assert max(b - a for a, b in zip(nodes, nodes[1:])) < 256
    asset = WORK / "assets/ui/pitch_bend_nodes.json"
    asset_text = json.dumps({"positions": [min(i * 256, 65535) for i in range(257)],
                             "ratio_uq1_17": nodes}, indent=2) + "\n"
    if not asset.exists() or asset.read_text(encoding="utf-8") != asset_text:
        backup(asset)
        asset.write_text(asset_text, encoding="utf-8")
    # 使用常量 case，不依赖运行目录加载 ROM 文件，也不创建宏头文件。
    rtl = WORK / "src/ui/pitch_bend_controller.v"
    source = rtl.read_text(encoding="utf-8")
    start = source.index("            // BEGIN_GENERATED_TABLE")
    end = source.index("            // END_GENERATED_TABLE", start)
    cases = "            // BEGIN_GENERATED_TABLE\n" + "".join(
        f"                9'd{i}: lookup_ratio = 18'd{value};\n" for i, value in enumerate(nodes))
    updated = source[:start] + cases + source[end:]
    if updated != source:
        backup(rtl)
        rtl.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    generate_table()
