"""Generate listening references from the fixed-point flow in chorus.v.

The musical input comes from the shared deterministic score generator; it is
not a cycle-accurate simulation of channel_rack. The chorus ring, triangular
LFO, startup mask, interpolation, rounding, and saturation follow the RTL.
Run: python scripts/audio/generate_chorus_comparison.py
Requires only the Python standard library.
"""

from __future__ import annotations

import math
from array import array

from generate_reverb_comparison import (
    MUSIC_SECONDS,
    PCM_TARGET_PEAK,
    ROOT,
    SAMPLE_RATE,
    TOTAL_SAMPLES,
    clamp,
    fp_mult,
    read_rom,
    render_input,
    write_wav,
)


OUTPUT_DIR = ROOT / "assets" / "audio" / "chorus_comparison"
CHORUS_MIX = 0x9000      # UQ0.16 = 0.5625
CHORUS_RATE = 0x3000     # UQ2.14 = 0.75 Hz
CHORUS_DEPTH = 96        # sample ticks
PHASE_STEP_K = round((1 << 48) / (SAMPLE_RATE * (1 << 14)))


class ChorusModel:
    def __init__(self) -> None:
        self.memory = array("i", [0]) * 1024
        self.pointer = 0
        self.valid_count = 0
        self.phase = 0

    def process(self, sample: int, mix: int, rate: int,
                depth: int) -> tuple[int, int]:
        """Return (RTL audio_out, wet_r) for one accepted sample."""
        sample = clamp(sample, 24)
        half = (self.phase >> 15) & 0xFFFF
        triangle = (~half & 0xFFFF) if self.phase & 0x80000000 else half
        offset = depth * triangle
        delay_samples = 256 + (offset >> 16)
        fraction = offset & 0xFFFF
        newer_ptr = (self.pointer - delay_samples) & 1023
        older_ptr = (newer_ptr - 1) & 1023
        newer = (self.memory[newer_ptr]
                 if self.valid_count >= delay_samples else 0)
        older = (self.memory[older_ptr]
                 if self.valid_count >= delay_samples + 1 else 0)

        self.phase = (self.phase + ((rate * PHASE_STEP_K) >> 16)) & 0xFFFFFFFF
        self.memory[self.pointer] = sample
        self.pointer = (self.pointer + 1) & 1023
        self.valid_count = min(1024, self.valid_count + 1)

        wet = clamp(newer + fp_mult(older - newer, fraction), 24)
        output = clamp(sample + fp_mult(wet - sample, mix), 24)
        return output, wet


def main() -> None:
    model = ChorusModel()
    dry = array("i")
    mixed = array("i")
    wet_only = array("i")
    for sample in render_input(read_rom()):
        processed, wet = model.process(sample, CHORUS_MIX,
                                       CHORUS_RATE, CHORUS_DEPTH)
        dry.append(sample)
        mixed.append(processed)
        wet_only.append(clamp(sample + fp_mult(wet - sample, 0xFFFF), 24))

    common_peak = max(max(map(abs, dry)), max(map(abs, mixed)),
                      max(map(abs, wet_only)))
    gain = PCM_TARGET_PEAK / max(common_peak, 1)
    music_samples = MUSIC_SECONDS * SAMPLE_RATE
    dry_energy = sum(value * value for value in dry[:music_samples])
    mixed_energy = sum(value * value for value in mixed[:music_samples])
    level_match = math.sqrt(dry_energy / max(mixed_energy, 1))
    matched_gain = min(gain * level_match,
                       PCM_TARGET_PEAK / max(map(abs, mixed)))

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, signal in (("dry.wav", dry), ("mixed.wav", mixed),
                         ("wet_only.wav", wet_only)):
        count, peak = write_wav(OUTPUT_DIR / name, signal, gain)
        print(f"{name}: {count / SAMPLE_RATE:.1f} s, 48 kHz mono PCM16, "
              f"peak={peak}")
    _, matched_peak = write_wav(OUTPUT_DIR / "mixed_level_matched.wav",
                                mixed, matched_gain)
    print(f"mixed_level_matched.wav: {TOTAL_SAMPLES / SAMPLE_RATE:.1f} s, "
          f"48 kHz mono PCM16, peak={matched_peak}; "
          f"listening gain relative to mixed.wav={matched_gain / gain:.3f}")
    print(f"RTL parameters: rate=0x{CHORUS_RATE:04X}, "
          f"depth={CHORUS_DEPTH} samples, mix=0x{CHORUS_MIX:04X}; "
          f"common WAV gain={gain:.6f}")


if __name__ == "__main__":
    main()
