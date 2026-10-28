"""Generate dry, mixed, and wet listening references for src/mixer/reverb.v.

The six delay lines, startup masking, coefficient clamps, fixed-point rounding,
and saturation follow the RTL at MAX_POLYPHONY=32. The musical input is a
deterministic test signal made from assets/audio/wavetables.mi; it is not a
simulation of the upstream channel rack. WAV export applies one common gain
after the 24-bit reverb output, representing a simple final mixer gain.

Run from any directory: python scripts/audio/generate_reverb_comparison.py
Requires only the Python standard library.
"""

from __future__ import annotations

import math
import random
import struct
import wave
from array import array
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ROM_PATH = ROOT / "assets" / "audio" / "wavetables.mi"
OUTPUT_DIR = ROOT / "assets" / "audio" / "reverb_comparison"
SAMPLE_RATE = 48_000
MUSIC_SECONDS = 16
TAIL_SECONDS = 3
TOTAL_SAMPLES = (MUSIC_SECONDS + TAIL_SECONDS) * SAMPLE_RATE
DELAY_LENGTHS = (1499, 1601, 1747, 1867, 223, 557)
REVERB_FEEDBACK = 0xB000
REVERB_DAMPING = 0x2800
REVERB_MIX = 0xC000
PCM_TARGET_PEAK = 29_000


def clamp(value: int, width: int) -> int:
    return max(-(1 << (width - 1)), min((1 << (width - 1)) - 1, value))


def wrap(value: int, width: int) -> int:
    value &= (1 << width) - 1
    return value - (1 << width) if value & (1 << (width - 1)) else value


def fp_mult(a: int, coeff: int) -> int:
    """signed_fp_mult at QIF_A=15, QIF_B=16, QOF=15.

    signed_rnd drops 16 fractional bits. Its negative half case rounds away
    from zero, while the positive maximum is protected from overflow.
    """
    product = a * coeff
    upper = product >> 16
    fraction = product & 0xFFFF
    if upper == (1 << 25) - 1 or (product < 0 and fraction == 0x8000):
        return upper
    return upper + (fraction >= 0x8000)


class ReverbModel:
    def __init__(self) -> None:
        self.memory = [array("i", [0]) * length for length in DELAY_LENGTHS]
        self.pointer = [0] * 6
        self.valid_count = [0] * 6
        self.filter_state = [0] * 4

    def process(self, audio_in: int, mix: int, feedback: int,
                damping: int) -> tuple[int, int]:
        """Return (RTL audio_out, wet_r) for one accepted sample."""
        audio_in = clamp(audio_in, 21)
        feedback = min(feedback, 0xF000)
        damping = min(damping, 0xF000)
        comb_input = audio_in >> 2
        comb_sum = 0

        for stage in range(4):
            position = self.pointer[stage]
            delayed = (self.memory[stage][position]
                       if self.valid_count[stage] == DELAY_LENGTHS[stage] else 0)
            damped = clamp(delayed + fp_mult(self.filter_state[stage] - delayed,
                                             damping), 24)
            self.filter_state[stage] = damped
            next_history = clamp(comb_input + fp_mult(damped - comb_input,
                                                        feedback), 24)
            self.memory[stage][position] = next_history
            comb_sum = wrap(comb_sum + delayed, 26)
            self._advance(stage)

        stage_input = clamp(comb_sum, 24)
        for stage in (4, 5):
            position = self.pointer[stage]
            delayed = (self.memory[stage][position]
                       if self.valid_count[stage] == DELAY_LENGTHS[stage] else 0)
            allpass_output = delayed - (stage_input >> 1)
            allpass_write = stage_input + (allpass_output >> 1)
            self.memory[stage][position] = clamp(allpass_write, 24)
            stage_input = clamp(allpass_output, 24)
            self._advance(stage)

        wet = stage_input
        output = clamp(audio_in + fp_mult(wet - audio_in, mix), 24)
        return output, wet

    def _advance(self, stage: int) -> None:
        length = DELAY_LENGTHS[stage]
        self.pointer[stage] = (self.pointer[stage] + 1) % length
        if self.valid_count[stage] < length:
            self.valid_count[stage] += 1


def read_rom() -> tuple[int, ...]:
    with ROM_PATH.open("r", encoding="ascii") as source:
        lines = [line.strip() for line in source if line.strip()]
    if lines[:3] != ["#File_format=Hex", "#Address_depth=16384", "#Data_width=16"]:
        raise ValueError(f"Unexpected MI header: {ROM_PATH}")
    words = [int(line, 16) for line in lines[3:]]
    if len(words) != 16_384:
        raise ValueError(f"Expected 16384 wavetable samples in {ROM_PATH}")
    return tuple(word - 0x10000 if word & 0x8000 else word for word in words)


@dataclass(frozen=True)
class Note:
    start: int
    off: int
    release: int
    increment: int
    wave_id: int
    amplitude: float
    attack: int
    decay: int
    sustain: float

    def sample(self, now: int, rom: tuple[int, ...]) -> float:
        age = now - self.start
        if age < self.attack:
            level = age / max(self.attack, 1)
        elif age < self.attack + self.decay:
            decay_age = age - self.attack
            level = 1.0 - (1.0 - self.sustain) * decay_age / max(self.decay, 1)
        else:
            level = self.sustain
        if now >= self.off:
            level *= max(0.0, 1.0 - (now - self.off) / max(self.release, 1))
        phase = (age * self.increment) & 0xFFFFFFFF
        address = min(4095, (phase >> 20) + ((phase >> 19) & 1))
        return rom[(self.wave_id << 12) | address] * self.amplitude * level


def make_note(start: float, duration: float, midi: int, wave_id: int,
              amplitude: float, *, pad: bool = False) -> Note:
    frequency = 440.0 * 2.0 ** ((midi - 69) / 12)
    return Note(
        start=round(start * SAMPLE_RATE),
        off=round((start + duration) * SAMPLE_RATE),
        release=round((0.34 if pad else 0.12) * SAMPLE_RATE),
        increment=round(frequency * (1 << 32) / SAMPLE_RATE),
        wave_id=wave_id,
        amplitude=amplitude,
        attack=round((0.06 if pad else 0.004) * SAMPLE_RATE),
        decay=round((0.3 if pad else 0.14) * SAMPLE_RATE),
        sustain=0.68 if pad else 0.35,
    )


def make_score() -> list[Note]:
    # Eight two-second bars: pads, arpeggios, bass, and a changing lead line.
    chords = ((60, 64, 67), (57, 60, 64), (53, 57, 60), (55, 59, 62),
              (52, 55, 59), (57, 60, 64), (50, 53, 57), (55, 59, 62))
    melody = (72, 74, 76, 79, 76, 74, 72, 67,
              69, 72, 76, 81, 79, 76, 74, 72,
              72, 76, 79, 84, 81, 79, 76, 72,
              74, 77, 81, 79, 77, 74, 72, 67)
    score: list[Note] = []
    for bar, chord in enumerate(chords):
        start = bar * 2.0
        for pitch in chord:
            score.append(make_note(start, 1.63, pitch, bar % 2,
                                   0.09 if bar < 4 else 0.12, pad=True))
        for beat in range(4):
            score.append(make_note(start + beat * 0.5, 0.33,
                                   chord[0] - 12, 1, 0.30))
        for step in range(8):
            score.append(make_note(start + step * 0.25, 0.19,
                                   chord[step % 3] + 12,
                                   (step // 2 + bar) % 3, 0.18))
        for step in range(4):
            score.append(make_note(start + step * 0.5 + 0.04, 0.37,
                                   melody[bar * 4 + step],
                                   0 if bar < 4 else 2, 0.17))
    return score


def make_drums() -> tuple[tuple[int, ...], tuple[int, ...]]:
    rng = random.Random(0x5EED)
    kick = tuple(round(12_000 * math.sin(2 * math.pi * (82 * t - 72 * t * t))
                       * math.exp(-24 * t))
                 for t in (index / SAMPLE_RATE for index in range(7_200)))
    snare = tuple(round(8_000 * (0.72 * rng.uniform(-1, 1) +
                                 0.28 * math.sin(2 * math.pi * 180 * index / SAMPLE_RATE))
                        * math.exp(-25 * index / SAMPLE_RATE))
                  for index in range(7_200))
    return kick, snare


def render_input(rom: tuple[int, ...]):
    note_starts: dict[int, list[Note]] = {}
    for note in make_score():
        note_starts.setdefault(note.start, []).append(note)
    kick, snare = make_drums()
    drum_starts: dict[int, list[tuple[int, ...]]] = {}
    for beat in range(MUSIC_SECONDS * 2):
        drum_starts.setdefault(beat * SAMPLE_RATE // 2, []).append(
            kick if beat % 2 == 0 else snare)

    active_notes: list[Note] = []
    active_drums: list[tuple[int, tuple[int, ...]]] = []
    for now in range(TOTAL_SAMPLES):
        active_notes.extend(note_starts.get(now, ()))
        active_notes = [note for note in active_notes
                        if now < note.off + note.release]
        active_drums.extend((now, drum) for drum in drum_starts.get(now, ()))
        active_drums = [(start, drum) for start, drum in active_drums
                        if now - start < len(drum)]
        value = sum(note.sample(now, rom) for note in active_notes)
        value += sum(drum[now - start] for start, drum in active_drums)
        yield clamp(round(value), 21)


def write_wav(path: Path, samples: array, gain: float) -> tuple[int, int]:
    peak = 0
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        for offset in range(0, len(samples), 4096):
            block = [clamp(round(value * gain), 16)
                     for value in samples[offset:offset + 4096]]
            peak = max(peak, *(abs(value) for value in block))
            output.writeframesraw(struct.pack(f"<{len(block)}h", *block))
    return len(samples), peak


def main() -> None:
    rom = read_rom()
    model = ReverbModel()
    dry = array("i")
    mixed = array("i")
    wet_only = array("i")
    for sample in render_input(rom):
        processed, wet = model.process(sample, REVERB_MIX,
                                       REVERB_FEEDBACK, REVERB_DAMPING)
        dry.append(sample)
        mixed.append(processed)
        # Same RAM history; only the final dry/wet coefficient differs.
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
    print(f"RTL coefficients: feedback=0x{REVERB_FEEDBACK:04X}, "
          f"damping=0x{REVERB_DAMPING:04X}, mix=0x{REVERB_MIX:04X}; "
          f"common WAV gain={gain:.6f}")


if __name__ == "__main__":
    main()
