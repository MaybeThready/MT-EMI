"""Generate listening references from the exact fixed-point flow in delay.v.

The source music and WAV writer are shared with the reverb comparison script;
the delay history, parameter clamps, rounding, saturation, and dry/wet mix are
modeled independently here. The music is a deterministic upstream test signal,
not a cycle-accurate simulation of channel_rack.

Run: python scripts/audio/generate_delay_comparison.py
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


OUTPUT_DIR = ROOT / "assets" / "audio" / "delay_comparison"
DELAY_TIME = SAMPLE_RATE // 4  # 12000 samples = 250 ms, an eighth note at 120 BPM
DELAY_FEEDBACK = 0x9000  # UQ0.16 = 0.5625
DELAY_MIX = 0x7000  # UQ0.16 = 0.4375


class DelayModel:
    def __init__(self) -> None:
        self.memory = array("i", [0]) * 65536
        self.pointer = 0
        self.valid_count = 0

    def process(self, audio_in: int, mix: int, time_value: int,
                feedback: int) -> tuple[int, int]:
        """Return (RTL audio_out, delayed_r) for one accepted sample."""
        audio_in = clamp(audio_in, 24)
        time_value = max(1, time_value)
        feedback = min(feedback, 0xF000)
        read_ptr = (self.pointer - time_value) & 0xFFFF
        delayed = (self.memory[read_ptr]
                   if self.valid_count >= time_value else 0)

        # FEEDBACK_SETUP/MULT/APPLY, then RAM_WRITE.
        history = clamp(audio_in + fp_mult(delayed, feedback), 24)
        self.memory[self.pointer] = history
        self.pointer = (self.pointer + 1) & 0xFFFF
        self.valid_count = min(self.valid_count + 1, 65536)

        # MIX_SETUP/MULT/APPLY; feedback uses the previously read sample.
        output = clamp(audio_in + fp_mult(delayed - audio_in, mix), 24)
        return output, delayed


def main() -> None:
    model = DelayModel()
    dry = array("i")
    mixed = array("i")
    wet_only = array("i")
    for sample in render_input(read_rom()):
        processed, delayed = model.process(sample, DELAY_MIX,
                                            DELAY_TIME, DELAY_FEEDBACK)
        dry.append(sample)
        mixed.append(processed)
        # The RAM history is unchanged if only the final mix coefficient changes.
        wet_only.append(clamp(sample + fp_mult(delayed - sample, 0xFFFF), 24))

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
    print(f"RTL parameters: time={DELAY_TIME} samples, "
          f"feedback=0x{DELAY_FEEDBACK:04X}, mix=0x{DELAY_MIX:04X}; "
          f"common WAV gain={gain:.6f}")


if __name__ == "__main__":
    main()
