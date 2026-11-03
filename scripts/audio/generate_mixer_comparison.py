"""Model the mixer effect order and fixed-point output; create WAVs and RTL vectors.

The source music is a deterministic channel-rack-like polyphonic sum. The four
effect models follow their Verilog sample arithmetic and startup masking.
Run: python scripts/audio/generate_mixer_comparison.py
Run: python scripts/audio/generate_mixer_comparison.py --vectors
"""

from __future__ import annotations

import argparse
import math
from array import array

from generate_chorus_comparison import ChorusModel
from generate_delay_comparison import DelayModel
from generate_distortion_comparison import DistortionModel
from generate_reverb_comparison import (
    ROOT, SAMPLE_RATE, clamp, read_rom, render_input, ReverbModel, write_wav,
)


OUTPUT_DIR = ROOT / "assets" / "audio" / "mixer_comparison"
VECTOR_PATH = ROOT / "sim" / "tb" / "mixer" / "mixer_vectors.mem"
VECTOR_COUNT = 1850

DISTORTION_MIX = 0x9000
DISTORTION_MAKE_UP = 0xA000
DISTORTION_GAIN = 0x3000
DISTORTION_TONE = 0xB000
CHORUS_MIX = 0x6000
CHORUS_MAKE_UP = 0xC000
CHORUS_RATE = 0x3000
CHORUS_DEPTH = 96
DELAY_MIX = 0x6000
DELAY_MAKE_UP = 0x6000
DELAY_TIME = 12000
DELAY_FEEDBACK = 0x8000
REVERB_MIX = 0x7000
REVERB_MAKE_UP = 0x9000
REVERB_FEEDBACK = 0xA000
REVERB_DAMPING = 0x2800
BALANCE_VOLUME = 0xF000
MASTER_VOLUME = 0xF000


def round_gain(value: int, coefficient: int) -> int:
    """Match signed_fp_mult: 15 fractional bits, negative half away from zero."""
    product = value * coefficient
    upper = product >> 15
    if upper == (1 << 26) - 1 or (product < 0 and
                                  (product & 0x7FFF) == 0x4000):
        return clamp(upper, 27)
    return clamp(upper + ((product >> 14) & 1), 27)


def pcm(sample: int, balance: int, master: int) -> int:
    balance_result = clamp(round_gain(sample, balance), 26)
    master_result = round_gain(balance_result, master)
    return clamp(master_result >> 3, 16)


def make_up(sample: int, coefficient: int) -> int:
    """Match the mixer multiplier and the SQ9.15 stage-output saturation."""
    return clamp(round_gain(sample, coefficient), 24)


class MixerModel:
    def __init__(self) -> None:
        self.distortion = DistortionModel()
        self.chorus = ChorusModel()
        self.delay = DelayModel()
        self.reverb = ReverbModel(input_width=24)

    def process(self, sample: int, balance: int, master: int) -> int:
        sample, _ = self.distortion.process(
            sample, DISTORTION_MIX, DISTORTION_GAIN, DISTORTION_TONE)
        sample = make_up(sample, DISTORTION_MAKE_UP)
        sample, _ = self.chorus.process(
            sample, CHORUS_MIX, CHORUS_RATE, CHORUS_DEPTH)
        sample = make_up(sample, CHORUS_MAKE_UP)
        sample, _ = self.delay.process(
            sample, DELAY_MIX, DELAY_TIME, DELAY_FEEDBACK)
        sample = make_up(sample, DELAY_MAKE_UP)
        sample, _ = self.reverb.process(
            sample, REVERB_MIX, REVERB_FEEDBACK, REVERB_DAMPING)
        sample = make_up(sample, REVERB_MAKE_UP)
        return pcm(sample, balance, master)


def make_vectors() -> None:
    model = MixerModel()
    peak = 0
    with VECTOR_PATH.open("w", encoding="ascii") as output:
        for index in range(VECTOR_COUNT):
            if index == 0:
                sample = 0
            elif index == 1:
                sample = 32767
            elif index == 2:
                sample = -32768
            elif index % 197 == 0:
                sample = 1048575 if index & 1 else -1048576
            else:
                sample = clamp(round(
                    550000 * math.sin(index * 0.17) +
                    170000 * math.sin(index * 0.041)), 21)
            balance = (0x8000, 0xF000, 0x4000)[(index // 300) % 3]
            master = (0x8000, 0xF000, 0x0000)[(index // 401) % 3]
            expected = model.process(sample, balance, master)
            peak = max(peak, abs(expected))
            packed = (((sample & 0x1FFFFF) << 48) |
                      (balance << 32) | (master << 16) |
                      (expected & 0xFFFF))
            output.write(f"{packed:018X}\n")
    print(f"{VECTOR_PATH.relative_to(ROOT)}: {VECTOR_COUNT} samples, peak={peak}")


def make_wavs() -> None:
    model = MixerModel()
    dry = array("i")
    processed = array("i")
    clipped = 0
    for sample in render_input(read_rom()):
        dry.append(pcm(sample, BALANCE_VOLUME, MASTER_VOLUME))
        value = model.process(sample, BALANCE_VOLUME, MASTER_VOLUME)
        processed.append(value)
        clipped += value in (-32768, 32767)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, signal in (("dry.wav", dry), ("processed.wav", processed)):
        count, peak = write_wav(OUTPUT_DIR / name, signal, 1.0)
        print(f"{name}: {count / SAMPLE_RATE:.1f}s, peak={peak}")
    dry_energy = sum(value * value for value in dry)
    processed_energy = sum(value * value for value in processed)
    matched_gain = math.sqrt(dry_energy / max(processed_energy, 1))
    matched_gain = min(matched_gain, 32767 / max(map(abs, processed)))
    _, matched_peak = write_wav(OUTPUT_DIR / "processed_level_matched.wav",
                                processed, matched_gain)
    print(f"processed_level_matched.wav: peak={matched_peak}, "
          f"listening gain={matched_gain:.3f}")
    print(f"Final PCM rail samples: {clipped}/{len(processed)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vectors", action="store_true", help="only write RTL test vectors")
    args = parser.parse_args()
    if args.vectors:
        make_vectors()
    else:
        make_wavs()
