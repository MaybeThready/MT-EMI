"""Generate listening references for the four S1 board-test top modules.

The source of waveform samples is assets/audio/wavetables.mi. This is an
audio-level reference, not a cycle-accurate model of the FPGA handshakes.
Run from any working directory with Python 3 and no third-party packages.
"""

from __future__ import annotations

import struct
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[2]
ROM_PATH = ROOT / "assets" / "audio" / "wavetables.mi"
OUTPUT_DIR = ROOT / "assets" / "audio" / "s1_expected"
SAMPLE_RATE = 48_000
PHASE_MASK = (1 << 32) - 1
PHASE_K = (1 << 32) // SAMPLE_RATE
STEP_SAMPLES = 12_000

C4 = 17_145_893
D4 = 19_245_614
E4 = 21_602_472
F4 = 22_887_021
G4 = 25_689_813
A4 = 28_835_840
STATIC_NOTES = (C4, C4, G4, G4, A4, A4, G4, None)
DYNAMIC_NOTES = (C4, C4, G4, G4, A4, A4, G4,
                 F4, F4, E4, E4, D4, D4, C4)


def read_rom(path: Path) -> tuple[int, ...]:
    with path.open("r", encoding="ascii") as source:
        lines = [line.strip() for line in source if line.strip()]
    if lines[:3] != ["#File_format=Hex", "#Address_depth=16384", "#Data_width=16"]:
        raise ValueError(f"Unexpected MI header: {path}")
    words = [int(line, 16) for line in lines[3:]]
    if len(words) != 16_384 or any(not 0 <= word <= 0xFFFF for word in words):
        raise ValueError(f"Expected 16384 16-bit ROM words: {path}")
    return tuple(word - 0x1_0000 if word & 0x8000 else word for word in words)


def phase_increment(freq_code: int) -> int:
    product = PHASE_K * freq_code
    return ((product >> 16) + ((product >> 15) & 1)) & PHASE_MASK


def phase_address(phase: int) -> int:
    upper = phase >> 20
    return min(4095, upper + ((phase >> 19) & 1))


def round_signed(numerator: int, denominator: int) -> int:
    magnitude = (abs(numerator) + denominator // 2) // denominator
    return -magnitude if numerator < 0 else magnitude


def clip16(value: int) -> int:
    return max(-32_768, min(32_767, value))


def wavetable_point(rom: tuple[int, ...], phase: int,
                    wave_0: int, wave_1: int, interp: int) -> int:
    address = phase_address(phase)
    left = rom[(wave_0 << 12) | address]
    right = rom[(wave_1 << 12) | address]
    return clip16(left + round_signed((right - left) * interp, 1 << 15))


@dataclass(frozen=True)
class Envelope:
    attack: int
    decay: int
    sustain: int
    release: int
    velocity: int


@dataclass
class Voice:
    freq_code: int = 0
    phase: int = 0
    age: int = 0
    release_age: int = 0
    release_start: int = 0
    last_volume: int = 0
    active: bool = False
    released: bool = False
    just_started: bool = False

    def note_on(self, freq_code: int) -> None:
        self.freq_code = freq_code
        self.phase = 0
        self.age = 0
        self.release_age = 0
        self.release_start = 0
        self.last_volume = 0
        self.active = True
        self.released = False
        self.just_started = True

    def note_off(self) -> None:
        if self.active and not self.released:
            self.release_start = self.last_volume
            self.release_age = 0
            self.released = True

    def render(self, rom: tuple[int, ...], envelope: Envelope,
               wave_0: int = 0, wave_1: int = 0, interp: int = 0,
               velocity: int | None = None) -> int:
        if not self.active:
            return 0
        if self.just_started:
            self.just_started = False
        else:
            self.phase = (self.phase + phase_increment(self.freq_code)) & PHASE_MASK

        if self.released:
            if self.release_age >= envelope.release:
                self.active = False
                self.last_volume = 0
                return 0
            volume = round(self.release_start *
                           (envelope.release - self.release_age) / envelope.release)
            self.release_age += 1
        elif self.age < envelope.attack:
            volume = round(65_535 * self.age / envelope.attack)
        elif self.age < envelope.attack + envelope.decay:
            elapsed = self.age - envelope.attack
            volume = 65_535 - round((65_535 - envelope.sustain) *
                                    elapsed / envelope.decay)
        else:
            volume = envelope.sustain

        self.last_volume = max(0, min(65_535, volume))
        self.age += 1
        level = envelope.velocity if velocity is None else velocity
        effective_volume = min(65_535, (self.last_volume * level + 32_768) >> 16)
        point = wavetable_point(rom, self.phase, wave_0, wave_1, interp)
        return clip16(round_signed(point * effective_volume, 1 << 16))


def tone_440(rom: tuple[int, ...]) -> Iterable[int]:
    phase = 0
    increment = phase_increment(28_835_840)
    for _ in range(2 * SAMPLE_RATE):
        yield rom[phase_address(phase)]
        phase = (phase + increment) & PHASE_MASK


def static_music(rom: tuple[int, ...]) -> Iterable[int]:
    voice = Voice()
    envelope = Envelope(attack=48, decay=48, sustain=0xB000,
                        release=240, velocity=0xC000)
    for sample in range(2 * len(STATIC_NOTES) * STEP_SAMPLES):
        note_index = (sample // STEP_SAMPLES) % len(STATIC_NOTES)
        position = sample % STEP_SAMPLES
        frequency = STATIC_NOTES[note_index]
        if frequency is not None and position == 0:
            voice.note_on(frequency)
        if frequency is not None and position == 10_800:
            voice.note_off()
        yield voice.render(rom, envelope)


def dynamic_music(rom: tuple[int, ...]) -> Iterable[int]:
    voices = [Voice() for _ in range(32)]
    envelope = Envelope(attack=240, decay=2400, sustain=0x9000,
                        release=4800, velocity=0x7000)
    for sample in range(2 * len(DYNAMIC_NOTES) * STEP_SAMPLES):
        step = sample // STEP_SAMPLES
        note_index = step % len(DYNAMIC_NOTES)
        position = sample % STEP_SAMPLES
        lane = step % len(voices)
        if position == 0:
            voices[lane].note_on(DYNAMIC_NOTES[note_index])
        if position == 10_000:
            voices[lane].note_off()
        interp = (note_index & 7) << 12
        mixed = sum(voice.render(rom, envelope, 0, 1, interp)
                    for voice in voices)
        yield clip16(mixed)


def keyboard_demo(rom: tuple[int, ...]) -> Iterable[int]:
    # Reproducible example: C4, A4, then a C4/E4/G4 chord.
    events = (
        (0.00, 0.45, C4),
        (0.70, 1.15, A4),
        (1.40, 2.10, C4),
        (1.40, 2.10, E4),
        (1.40, 2.10, G4),
    )
    start_events: dict[int, list[int]] = {}
    stop_events: dict[int, list[int]] = {}
    for lane, (start, stop, _) in enumerate(events):
        start_events.setdefault(round(start * SAMPLE_RATE), []).append(lane)
        stop_events.setdefault(round(stop * SAMPLE_RATE), []).append(lane)

    voices = [Voice() for _ in events]
    envelope = Envelope(attack=240, decay=7200, sustain=45_875,
                        release=9600, velocity=0xFFFF)
    for sample in range(round(2.55 * SAMPLE_RATE)):
        for lane in start_events.get(sample, ()):
            voices[lane].note_on(events[lane][2])
        for lane in stop_events.get(sample, ()):
            voices[lane].note_off()
        mixed = 0
        for voice in voices:
            # The current keyboard driver uses a fixed full-scale velocity.
            # The UI slews it over roughly 5 ms after note_on.
            velocity = min(0xFFFF, (voice.age + 1) * 274)
            mixed += voice.render(rom, envelope, velocity=velocity)
        yield clip16(mixed)


def write_wav(path: Path, samples: Iterable[int]) -> tuple[int, int]:
    count = 0
    peak = 0
    block: list[int] = []
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        for sample in samples:
            block.append(sample)
            count += 1
            peak = max(peak, abs(sample))
            if len(block) == 4096:
                output.writeframesraw(struct.pack(f"<{len(block)}h", *block))
                block.clear()
        if block:
            output.writeframesraw(struct.pack(f"<{len(block)}h", *block))
    return count, peak


def main() -> None:
    rom = read_rom(ROM_PATH)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    renderers = (
        ("test_i2s_440hz.wav", tone_440),
        ("test_static_music.wav", static_music),
        ("test_dynamic_music.wav", dynamic_music),
        ("test_keyboard_interaction_demo.wav", keyboard_demo),
    )
    for filename, render in renderers:
        count, peak = write_wav(OUTPUT_DIR / filename, render(rom))
        print(f"{filename}: {count / SAMPLE_RATE:.2f} s, {SAMPLE_RATE} Hz, "
              f"mono PCM16, peak {peak}")


if __name__ == "__main__":
    main()
