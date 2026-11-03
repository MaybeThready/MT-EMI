"""Generate listening references following the fixed-point path in distortion.v.

The music is a deterministic upstream test signal, not a cycle-accurate model
of channel_rack. WAV export applies one common final PCM gain after the 24-bit
effect output. Run: python scripts/audio/generate_distortion_comparison.py
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
    read_rom,
    render_input,
    write_wav,
)


OUTPUT_DIR = ROOT / "assets" / "audio" / "distortion_comparison"
DISTORTION_MIX = 0xC000       # UQ0.16 = 0.75
DISTORTION_GAIN = 0x4000      # UQ4.12 = 4.0
DISTORTION_TONE = 0xB000      # UQ0.16 = 0.6875


def round_mult(value: int, coeff: int) -> int:
    """signed_fp_mult with a 30-bit SQ15.15 result and 16-bit fraction drop."""
    product = value * coeff
    upper = product >> 16
    if upper == (1 << 29) - 1 or (product < 0 and
                                  (product & 0xFFFF) == 0x8000):
        return upper
    return upper + ((product >> 15) & 1)


class DistortionModel:
    def __init__(self) -> None:
        self.tone_state = 0

    def process(self, sample: int, mix: int, gain: int,
                tone: int) -> tuple[int, int]:
        """Return (RTL audio_out, tone_state_r) for one accepted sample."""
        sample = clamp(sample, 24)
        clipped = clamp(round_mult(sample, gain << 4), 16)
        alpha = min(0xFFFF, tone - (tone >> 8) + 256)
        self.tone_state = clamp(
            self.tone_state + round_mult(clipped - self.tone_state, alpha),
            16,
        )
        output = clamp(sample + round_mult(self.tone_state - sample, mix), 24)
        return output, self.tone_state


def main() -> None:
    model = DistortionModel()
    dry = array("i")
    mixed = array("i")
    wet_only = array("i")
    for sample in render_input(read_rom()):
        processed, wet = model.process(sample, DISTORTION_MIX,
                                       DISTORTION_GAIN, DISTORTION_TONE)
        dry.append(sample)
        mixed.append(processed)
        wet_only.append(clamp(sample + round_mult(wet - sample, 0xFFFF), 24))

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
    print(f"RTL parameters: gain=0x{DISTORTION_GAIN:04X}, "
          f"tone=0x{DISTORTION_TONE:04X}, mix=0x{DISTORTION_MIX:04X}; "
          f"common WAV gain={gain:.6f}")


if __name__ == "__main__":
    main()
