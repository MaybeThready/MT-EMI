"""Append AutoPlay labels to the spare LCD text bank and one glyph bank.

The existing v4 asset data and labels are left intact. Re-running is safe.
"""

from pathlib import Path
import re

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
LABELS = {
    153: "AutoPlay",
    154: "The Star",
    155: "Everlasting Dirge",
    156: "Playing",
    157: "Ready",
    158: "B1 Start",
    159: "5",
}
BASE_ENTRY = 2855
BASE_TILE = 1977


def init_lines(words: list[int], bits: int) -> str:
    width = bits // 4
    return "\n".join(
        f"        .INIT_RAM_{i:02X}(256'h" +
        "".join(f"{word:0{width}x}" for word in reversed(words[i * (256 // bits):(i + 1) * (256 // bits)])) +
        (")," if i != 63 else ")")
        for i in range(64)
    )


def main() -> None:
    chars = sorted(set("".join(LABELS.values())))
    tile = {char: BASE_TILE + i for i, char in enumerate(chars)}
    font_path = Path("C:/Windows/Fonts/consola.ttf")
    font = ImageFont.truetype(str(font_path), 13) if font_path.exists() else ImageFont.load_default()
    assert len(chars) <= 2048 - BASE_TILE
    glyph_bytes = [0] * ((2048 - BASE_TILE) * 16)
    for char, tile_id in tile.items():
        image = Image.new("L", (8, 16), 0)
        draw = ImageDraw.Draw(image)
        draw.text((0, -1), char, font=font, fill=255)
        for y in range(16):
            glyph_bytes[(tile_id - BASE_TILE) * 16 + y] = sum(
                (1 << (7 - x)) for x in range(8) if image.getpixel((x, y)) >= 96
            )

    text_words = [int(x, 16) for x in (ROOT / "assets/lcd_ui/v4/text.hex").read_text().splitlines()]
    assert len(text_words) == 3072 and all(x == 0 for x in text_words[BASE_ENTRY:])
    entries: dict[int, tuple[int, int]] = {}
    cursor = BASE_ENTRY
    for label_id, caption in LABELS.items():
        entries[label_id] = (cursor, len(caption))
        for col, char in enumerate(caption):
            text_words[cursor] = (col << 13) | tile[char]
            cursor += 1
    assert cursor <= 3072

    info_path = ROOT / "src/lcd_ui/lcd_text_info.v"
    info = info_path.read_text(encoding="utf-8")
    info = re.sub(r"\s*8'd15[3-9]: info=20'h[0-9a-f]+;", "", info)
    additions = "".join(
        f"\n            8'd{label_id}: info=20'h{(start << 8) | count:05x};"
        for label_id, (start, count) in entries.items()
    )
    info = info.replace("            default: info=20'd0;", additions + "\n            default: info=20'd0;")
    info_path.write_text(info, encoding="utf-8")

    text_path = ROOT / "src/lcd_ui/lcd_text_rom.v"
    text = text_path.read_text(encoding="utf-8")
    start = text.index("    SDPB #", text.index("    ) rom_u4"))
    end = text.index("    ) rom_u5", start)
    bank = text_words[2560:3072]
    text = text[:start] + re.sub(
        r"        \.INIT_RAM_00\(256'h[0-9a-fA-F]+\),.*?        \.INIT_RAM_3F\(256'h[0-9a-fA-F]+\)",
        init_lines(bank, 32), text[start:end], flags=re.S
    ) + text[end:]
    text_path.write_text(text, encoding="utf-8")

    tile_path = ROOT / "src/lcd_ui/lcd_tile_rom.v"
    source = tile_path.read_text(encoding="utf-8")
    source = source.replace("bank_data [0:16]", "bank_data [0:15]").replace("reg [4:0] bank_r", "reg [3:0] bank_r")
    if "    ) rom_u16 (" in source:
        start = source.rfind("\n    SDPB #", 0, source.index("    ) rom_u16 ("))
        end = source.index(");", source.index("    ) rom_u16 (")) + 2
        source = source[:start] + source[end:]
    bank = [int(x, 16) for x in (ROOT / "assets/lcd_ui/v4/tiles.hex").read_text().splitlines()][15 * 2048:16 * 2048]
    offset = (BASE_TILE - 15 * 128) * 16
    assert len(bank) == 2048 and all(x == 0 for x in bank[offset:])
    bank[offset:] = glyph_bytes
    start = source.rfind("    SDPB #", 0, source.index("    ) rom_u15 ("))
    end = source.index("    ) rom_u15 (", start)
    updated, count = re.subn(
        r"        \.INIT_RAM_00\(256'h[0-9a-fA-F]+\),.*?        \.INIT_RAM_3F\(256'h[0-9a-fA-F]+\)",
        init_lines(bank, 8), source[start:end], flags=re.S
    )
    assert count == 1
    source = source[:start] + updated + source[end:]
    tile_path.write_text(source, encoding="utf-8")

    (ROOT / "assets/lcd_ui/autoplay_glyphs.hex").write_text(
        "\n".join(f"{byte:02x}" for byte in glyph_bytes) + "\n", encoding="ascii"
    )
    (ROOT / "assets/lcd_ui/autoplay_text.hex").write_text(
        "\n".join(f"{word:08x}" for word in text_words[BASE_ENTRY:cursor]) + "\n",
        encoding="ascii",
    )
    print(f"AutoPlay LCD: {len(LABELS)} labels, {len(chars)} glyphs, {cursor - BASE_ENTRY} text words")


if __name__ == "__main__":
    main()
