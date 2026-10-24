"""Generate a Gowin MI ROM image with four 4096-sample SQ1.15 wavetables."""

import math
from pathlib import Path


PHASE_BITS = 12
PHASE_COUNT = 1 << PHASE_BITS
WAVE_NAMES = ("sine", "triangle", "sawtooth", "square")
ROM_DEPTH = len(WAVE_NAMES) * PHASE_COUNT
ROM_WIDTH = 16
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "assets"


def waveform(wave_id: int, phase: int) -> float:
    fraction = phase / PHASE_COUNT
    if wave_id == 0:
        return math.sin(2 * math.pi * fraction)
    if wave_id == 1:
        if phase < PHASE_COUNT // 4:
            return 4 * fraction
        if phase < 3 * PHASE_COUNT // 4:
            return 2 - 4 * fraction
        return 4 * fraction - 4
    if wave_id == 2:
        return 2 * fraction - 1
    return 1.0 if phase < PHASE_COUNT // 2 else -1.0


def encode_sq1_15(sample: float) -> int:
    signed = max(-32768, min(32767, round(sample * (1 << 15))))
    return signed & 0xFFFF


def main() -> None:
    samples = [
        encode_sq1_15(waveform(wave_id, phase))
        for wave_id in range(len(WAVE_NAMES))
        for phase in range(PHASE_COUNT)
    ]

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    mi_path = OUTPUT_DIR / "wavetables.mi"

    with mi_path.open("w", encoding="ascii", newline="\n") as mi:
        mi.write(
            "#File_format=Hex\n"
            f"#Address_depth={ROM_DEPTH}\n"
            f"#Data_width={ROM_WIDTH}\n"
        )
        for sample in samples:
            mi.write(f"{sample:04X}\n")

    print(f"Generated {mi_path} ({ROM_DEPTH} x {ROM_WIDTH}).")


if __name__ == "__main__":
    main()
