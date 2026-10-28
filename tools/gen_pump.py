#!/usr/bin/env python3
"""Generates the "Pump" example (docs/spec.md §7.5, M10): a house track that
uses the mixer. Writes rive/assets/examples/example-pump.song.

    python3 tools/gen_pump.py

- The bass and chords duck under the kick: compressors keyed by it.
- The claps and hats play into the "drums" bus (EQ and glue compression).
- Chords and lead send to the "space" bus (high-pass, chorus, reverb, delay).
- Effects on tracks: distortion on the bass, chorus and a filter on the chords,
  a phaser on the lead, each automated somewhere.
- The master chain: a low-pass that opens over the intro and closes over the
  outro, a gentle compressor and an EQ.
"""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "rive", "assets", "examples", "example-pump.song")
BAR = 16


class Lane:
    def __init__(self, rows):
        self.rows = [[] for _ in range(rows)]

    def at(self, row, *commands):
        self.rows[row].extend(commands)
        return self

    def text(self):
        return "".join("; ".join(r) + "\n" for r in self.rows)


# Sections, in bars.
INTRO, DROP, BREAK, DROP2, OUTRO = 0, 4, 12, 16, 24
END = 28


def song():
    f = {}
    f["song.yaml"] = (
        "title: Pump\nauthor: Partition examples\nbpm: 124\nsignature: 4/4\nrows_per_beat: 4\n"
        "channels:\n"
        "  - name: kick\n    file: channels/kick.ch\n"
        "  - name: tops\n    file: channels/tops.ch\n    bus: drums\n"
        "  - name: bass\n    file: channels/bass.ch\n"
        "  - name: chords\n    file: channels/chords.ch\n"
        "  - name: lead\n    file: channels/lead.ch\n"
        "buses:\n"
        "  - name: drums\n    file: buses/drums.ch\n"
        "  - name: space\n    file: buses/space.ch\n"
    )
    rows = END * BAR
    c = Lane(rows)
    # The master: a low-pass that opens over the intro, glue, and a smile EQ.
    c.at(0, "mark(name: intro)", "fx(type: filter, cutoff: 300)", "fx(type: comp, threshold: -12dB, ratio: 2, attack: 20ms, release: 250ms)",
         "fx(type: eq, low: 1.5dB, high: 2dB)")
    c.at(0, "ramp(filter.cutoff: 20k, over: 4bar, curve: exp)")
    c.at(DROP * BAR, "mark(name: drop)")
    c.at(BREAK * BAR, "mark(name: break)")
    c.at(DROP2 * BAR, "mark(name: drop2)")
    c.at(OUTRO * BAR, "mark(name: outro)", "ramp(filter.cutoff: 250, over: 4bar, curve: exp)")
    c.at(rows - 1, "end()")
    f["conductor.ch"] = c.text()

    # Buses.
    f["buses/drums.ch"] = (
        "fx(type: eq, low: -6dB, low_freq: 250, high: 3dB, high_freq: 9k)\n"
        "fx(type: comp, threshold: -20dB, ratio: 3, attack: 8ms, release: 90ms, makeup: 3dB)\n"
        "vol(v: 0.9)\n"
    )
    f["buses/space.ch"] = (
        "fx(type: filter, mode: highpass, cutoff: 500)\n"
        "fx(type: chorus, rate: 0.3, depth: 0.8, mix: 0.7)\n"
        "set(reverb: 0.7, delay: 0.35); vol(v: 0.7)\n"
    )

    # Patterns.
    p = Lane(BAR)
    for b in range(4):
        p.at(b * 4, "note(p: C1, vel: 0.95)")
    f["patterns/four_floor.pat"] = p.text()

    p = Lane(BAR)
    for k in range(0, 16, 2):
        if k % 4 == 2:
            p.at(k, "note(p: C4, inst: hat_open, vel: 0.45)" if k == 14 else "note(p: C4, inst: hat_closed, vel: 0.55)")
        else:
            p.at(k, "note(p: C4, inst: hat_closed, vel: 0.3)")
    p.at(4, "note(p: C4, inst: clap, vel: 0.8)").at(12, "note(p: C4, inst: clap, vel: 0.8)")
    p.at(15, "note(p: C4, inst: hat_closed, vel: 0.25)")
    f["patterns/tops.pat"] = p.text()

    progression = [("A1", "A3", "min7"), ("F1", "F3", "maj7"), ("C2", "C3", "maj7"), ("G1", "G3", "dom7")]
    p = Lane(4 * BAR)
    for bar, (bass, _, _) in enumerate(progression):
        for k in (2, 6, 10, 14):
            p.at(bar * BAR + k, f"note(p: {bass}, len: 2, vel: {0.9 if k == 2 else 0.75})")
        p.at(bar * BAR + 15, f"note(p: {bass[0]}{int(bass[1]) + 1}, len: 1, vel: 0.5)")
    f["patterns/bassline.pat"] = p.text()

    p = Lane(4 * BAR)
    for bar, (_, root, kind) in enumerate(progression):
        p.at(bar * BAR, f"chord(root: {root}, type: {kind}, len: 1bar, vel: 0.6)")
    f["patterns/chords.pat"] = p.text()

    p = Lane(4 * BAR)
    arps = [["A4", "C5", "E5", "G5"], ["A4", "C5", "F5", "E5"], ["G4", "C5", "E5", "B4"], ["G4", "B4", "D5", "F5"]]
    for bar, notes in enumerate(arps):
        for k in range(16):
            if k % 4 == 3:
                continue
            p.at(bar * BAR + k, f"note(p: {notes[(k // 2) % 4]}, len: 1, vel: {0.7 if k % 4 == 0 else 0.5})")
    f["patterns/arp.pat"] = p.text()

    # Tracks.
    t = Lane(rows)
    t.at(0, "inst(name: kick); vol(v: 1)", "pattern(name: four_floor, times: 12)")
    t.at(DROP2 * BAR, "pattern(name: four_floor, times: 10)")
    f["channels/kick.ch"] = t.text()

    t = Lane(rows)
    t.at(2 * BAR, "pattern(name: tops, times: 10)")
    t.at(DROP2 * BAR, "pattern(name: tops, times: 10)")
    f["channels/tops.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "fx(type: comp, threshold: -32dB, ratio: 10, attack: 1ms, release: 170ms, sidechain: kick)", "fx(type: dist, drive: 0.15, tone: 3k, mix: 0.35)")
    t.at(DROP * BAR, "inst(name: deep_bass); vol(v: 0.75)", "pattern(name: bassline, times: 2)")
    t.at(DROP2 * BAR, "pattern(name: bassline, times: 2)", "ramp(dist.drive: 0.55, over: 8bar)")
    f["channels/bass.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "fx(type: comp, threshold: -34dB, ratio: 12, attack: 1ms, release: 220ms, sidechain: kick)", "fx(type: chorus, depth: 0.6, mix: 0.4)",
         "fx(type: filter, cutoff: 1.8k, res: 0.2)", "set(send.space: 0.35)")
    t.at(0, "inst(name: pad); vol(v: 0.55)", "pattern(name: chords, times: 7)")
    # The break: the kick stops, the chords stop pumping and open up.
    t.at(BREAK * BAR, "ramp(filter.cutoff: 9k, over: 4bar, curve: exp)", "lfo(param: chorus.depth, rate: 2bar, depth: 0.3)")
    t.at(DROP2 * BAR, "set(filter.cutoff: 2.5k)", "pattern(name: chords, times: 3)")
    f["channels/chords.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "fx(type: phaser, rate: 0.2, depth: 0.8, feedback: 0.6, mix: 0.6)", "fx(type: eq, low: -9dB, low_freq: 300)", "set(send.space: 0.5)")
    t.at(DROP * BAR, "inst(name: pluck); vol(v: 0.4)", "pattern(name: arp, times: 2)")
    t.at(BREAK * BAR, "ramp(phaser.rate: 1.5Hz, over: 4bar)", "pattern(name: arp)")
    t.at(DROP2 * BAR, "set(phaser.rate: 0.2Hz)", "pattern(name: arp, times: 2)")
    f["channels/lead.ch"] = t.text()
    return f


def main():
    files = song()
    order = ["song.yaml", "conductor.ch"] + sorted(p for p in files if p not in ("song.yaml", "conductor.ch"))
    out = "%partition-bundle 1\n" + "".join(f"=== {p}\n{files[p]}" for p in order)
    with open(OUT, "w") as fh:
        fh.write(out)
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(out) // 1024} KB, {len(files)} files)")


if __name__ == "__main__":
    main()
