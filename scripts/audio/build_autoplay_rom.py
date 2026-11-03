"""Convert the two user-supplied MIDI files into SDPB-backed event ROM.

The original .mid files are never modified. Run from any directory:
    python scripts/audio/build_autoplay_rom.py
"""

from __future__ import annotations

import struct
from collections import defaultdict, deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIDI_DIR = ROOT / "assets" / "midi"
SOURCES = ("The Star.mid", "Everlasting Dirge.mid")
SAMPLE_RATE = 48_000
MAX_VOICES = 8  # Must match autoplay_player.AUTO_VOICES.
RELEASE_GUARD_SAMPLES = 9_600  # Preserve up to 200 ms of release at 48 kHz.
ROM_DEPTH = 1536  # Three 512-word SDPB banks, each paired for 41-bit events.


def read_vlq(data: bytes, cursor: int) -> tuple[int, int]:
    value = 0
    for _ in range(4):
        byte = data[cursor]
        cursor += 1
        value = (value << 7) | (byte & 0x7F)
        if byte < 0x80:
            return value, cursor
    raise ValueError("MIDI variable-length quantity exceeds four bytes")


def parse_midi(path: Path) -> tuple[int, list[tuple[int, int, int, int, int, bool]]]:
    data = path.read_bytes()
    if data[:4] != b"MThd" or struct.unpack_from(">I", data, 4)[0] != 6:
        raise ValueError(f"Invalid MIDI header: {path}")
    fmt, track_count, ppq = struct.unpack_from(">HHH", data, 8)
    if fmt not in (0, 1) or ppq & 0x8000:
        raise ValueError(f"Expected PPQ MIDI format 0/1: {path}")
    cursor = 14
    raw_notes = []
    tempos = [(0, 500_000, -1)]
    end_tick = 0
    serial = 0
    for track in range(track_count):
        if data[cursor:cursor + 4] != b"MTrk":
            raise ValueError(f"Missing track {track}: {path}")
        length = struct.unpack_from(">I", data, cursor + 4)[0]
        body = data[cursor + 8:cursor + 8 + length]
        cursor += 8 + length
        pos = 0
        tick = 0
        running_status = 0
        while pos < len(body):
            delta, pos = read_vlq(body, pos)
            tick += delta
            if body[pos] & 0x80:
                running_status = body[pos]
                pos += 1
            status = running_status
            if status == 0xFF:
                kind = body[pos]
                pos += 1
                size, pos = read_vlq(body, pos)
                payload = body[pos:pos + size]
                pos += size
                if kind == 0x51:
                    tempos.append((tick, int.from_bytes(payload, "big"), serial))
                if kind == 0x2F:
                    end_tick = max(end_tick, tick)
                running_status = 0
            elif status in (0xF0, 0xF7):
                size, pos = read_vlq(body, pos)
                pos += size
                running_status = 0
            elif 0x80 <= status <= 0xEF:
                kind, channel = status & 0xF0, status & 0x0F
                size = 1 if kind in (0xC0, 0xD0) else 2
                payload = body[pos:pos + size]
                pos += size
                if kind in (0x80, 0x90):
                    pitch, velocity = payload
                    on = kind == 0x90 and velocity != 0
                    raw_notes.append((tick, serial, track, channel, pitch, velocity, on))
            else:
                raise ValueError(f"Unsupported MIDI status {status:02x}: {path}")
            serial += 1
        if pos != len(body):
            raise ValueError(f"Track length mismatch: {path}")
    if cursor != len(data):
        raise ValueError(f"Unexpected trailing bytes: {path}")

    tempos.sort(key=lambda item: (item[0], item[2]))
    def tick_to_sample(target: int) -> int:
        elapsed = 0
        previous_tick = 0
        tempo = 500_000
        for tick, next_tempo, _ in tempos:
            if tick > target:
                break
            elapsed += (tick - previous_tick) * tempo
            previous_tick = tick
            tempo = next_tempo
        elapsed += (target - previous_tick) * tempo
        return (elapsed * SAMPLE_RATE + ppq * 500_000) // (ppq * 1_000_000)

    by_note = defaultdict(deque)
    samples = []
    # At a shared tick the original ordering is preserved; output sorting later
    # places note-off before note-on so a repeated note has a clean boundary.
    for tick, order, track, channel, pitch, velocity, on in sorted(raw_notes):
        if channel == 9:
            # The synth has pitched oscillators only; drum mapping is a future feature.
            raise ValueError(f"Drum channel present; decide mapping first: {path}")
        sample = tick_to_sample(tick)
        key = (track, channel, pitch)
        if on:
            by_note[key].append((sample, velocity, order))
        else:
            if not by_note[key]:
                raise ValueError(f"Orphan note-off {key}: {path}")
            start, attack_velocity, start_order = by_note[key].popleft()
            samples.append((start, 1, start_order, pitch, attack_velocity, sample))
    if any(by_note.values()):
        raise ValueError(f"Unclosed MIDI notes: {path}")

    used = [-1] * MAX_VOICES
    events = []
    for start, _, order, pitch, velocity, stop in sorted(samples):
        # Reserve a lane through the note-off sample. This avoids simultaneous
        # note_on/note_off on the same lane in one channel-rack transaction.
        lane = next((i for i, available_after in enumerate(used) if available_after < start), None)
        if lane is None:
            raise ValueError(f"More than {MAX_VOICES} concurrent notes: {path}")
        used[lane] = max(stop + RELEASE_GUARD_SAMPLES, start + 1)
        events.append((start, 1, lane, pitch, velocity))
        events.append((stop, 0, lane, pitch, 0))
    events.sort(key=lambda item: (item[0], item[1]))
    return tick_to_sample(end_tick), events


def pack(event: tuple[int, int, int, int, int]) -> int:
    sample, on, lane, pitch, velocity = event
    if not (0 <= sample < 2**21 and 0 <= lane < 32 and 0 <= pitch < 128 and 0 <= velocity < 128):
        raise ValueError(event)
    return (sample << 20) | (on << 19) | (lane << 14) | (pitch << 7) | velocity


def sd_p_bank(words: list[int], bank: int, part: int) -> str:
    local_words = words[bank * 512:(bank + 1) * 512]
    lines = [
        '    SDPB #(.READ_MODE(1\'b0), .BIT_WIDTH_0(32), .BIT_WIDTH_1(32),',
        '        .RESET_MODE("ASYNC"), .BLK_SEL_0(3\'b000), .BLK_SEL_1(3\'b000),',
    ]
    for row in range(64):
        chunk = local_words[row * 8:(row + 1) * 8]
        values = [(value >> (32 * part)) & 0xFFFFFFFF for value in chunk]
        init = ''.join(f"{value:08x}" for value in reversed(values))
        suffix = ',' if row < 63 else ''
        lines.append(f"        .INIT_RAM_{row:02X}(256'h{init}){suffix}")
    lines.extend([
        f"    ) rom_{bank}_{part} (",
        "        .CLKA(clk_sys), .CLKB(clk_sys), .CEA(1'b0),",
        f"        .CEB(rst_n && rd_en && (address[10:9] == 2'd{bank})),",
        "        .OCE(1'b1), .RESET(!rst_n), .ADA(14'd0),",
        "        .ADB({address[8:0], 5'd0}), .DI(32'd0),",
        f"        .DO({('low' if part == 0 else 'high')}[{bank}]),",
        "        .BLKSELA(3'b000), .BLKSELB(3'b000));",
    ])
    return '\n'.join(lines)


def main() -> None:
    words = []
    metadata = []
    pitches = set()
    for name in SOURCES:
        duration, events = parse_midi(MIDI_DIR / name)
        start = len(words)
        words.extend(pack(event) for event in events)
        metadata.append((start, len(words), duration))
        pitches.update(event[3] for event in events)
        print(f"{name}: {len(events)//2} notes, {len(events)} events, {duration} samples, ROM [{start},{len(words)})")
    if len(words) > ROM_DEPTH:
        raise ValueError(f"ROM depth {ROM_DEPTH} too small for {len(words)} events")
    padded = words + [0] * (ROM_DEPTH - len(words))
    (MIDI_DIR / "autoplay_events.mi").write_text(
        '\n'.join(f"{word:011x}" for word in padded) + '\n', encoding='ascii')

    rom = [
        '/** Two user MIDI arrangements converted to 48 kHz events; regenerated by scripts/audio/build_autoplay_rom.py. */',
        'module autoplay_event_rom(',
        '    input clk_sys, input rst_n, input rd_en, input [10:0] address,',
        '    output [40:0] event_data,',
        '    input song_select, output [10:0] song_start, output [10:0] song_end,',
        '    output [20:0] song_samples',
        ');',
        f"    assign song_start = song_select ? 11'd{metadata[1][0]} : 11'd{metadata[0][0]};",
        f"    assign song_end = song_select ? 11'd{metadata[1][1]} : 11'd{metadata[0][1]};",
        f"    assign song_samples = song_select ? 21'd{metadata[1][2]} : 21'd{metadata[0][2]};",
        '    wire [31:0] low [0:2];',
        '    wire [31:0] high [0:2];',
        '    reg [1:0] bank_r;',
        '    assign event_data = {high[bank_r][8:0], low[bank_r]};',
        '    always @(posedge clk_sys or negedge rst_n)',
        "        if (!rst_n) bank_r <= 2'd0;",
        '        else if (rd_en) bank_r <= address[10:9];',
    ]
    for bank in range(3):
        for part in range(2):
            rom.append(sd_p_bank(padded, bank, part))
    rom.append('endmodule')
    (ROOT / 'src/system/autoplay_event_rom.v').write_text('\n'.join(rom) + '\n', encoding='ascii')

    frequency = [
        '/** Shared 46..97 MIDI note to UQ16.16 Hz table for AutoPlay. */',
        'module autoplay_frequency_lut(input [6:0] pitch, output reg [31:0] frequency);',
        '    always @(*) begin',
        '        case (pitch)',
    ]
    for pitch in range(min(pitches), max(pitches) + 1):
        hz = 440.0 * 2.0 ** ((pitch - 69) / 12.0)
        code = round(hz * 65536)
        frequency.append(f"            7'd{pitch}: frequency = 32'd{code};")
    frequency += ["            default: frequency = 32'd0;", '        endcase', '    end', 'endmodule']
    (ROOT / 'src/system/autoplay_frequency_lut.v').write_text('\n'.join(frequency) + '\n', encoding='ascii')


if __name__ == '__main__':
    main()
