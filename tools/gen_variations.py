#!/usr/bin/env python3
"""Generates the "Variations" example (docs/spec.md §5.6, §8.1, §8.2, M11):
one set of patterns played in three keys and two densities. Writes
rive/assets/examples/example-variations.song.

    python3 tools/gen_variations.py

- The conductor changes key: A minor, then C major, then D dorian.
- The chords are progressions of Roman numerals (prog), so they follow the key.
- The bass and the motif are written in scale degrees, and take arguments:
  the bass its degree, the motif whether it is busy and its octave.
- The groove plays a fill on every 4th pass, and its 16th hats only when busy.
"""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "rive", "assets", "examples", "example-variations.song")
BAR = 16


class Lane:
    def __init__(self, rows):
        self.rows = [[] for _ in range(rows)]

    def at(self, row, *commands):
        self.rows[row].extend(commands)
        return self

    def text(self):
        return "".join("; ".join(r) + "\n" for r in self.rows)


# Sections: (first bar, key, mode, progression, the bass's degree per bar, busy).
SECTIONS = [
    (0, "A", "minor", "i VI III VII", [1, 6, 3, 7], False),
    (8, "C", "major", "I vi IV V", [1, 6, 4, 5], True),
    (16, "D", "dorian", "i IV i bVII", [1, 4, 1, 7], True),
]
END = 24


def song():
    f = {}
    f["song.yaml"] = (
        "title: Variations\nauthor: Partition examples\nbpm: 112\nsignature: 4/4\nrows_per_beat: 4\nswing: 0.12\n"
        "channels:\n"
        "  - name: drums\n    file: channels/drums.ch\n"
        "  - name: bass\n    file: channels/bass.ch\n"
        "  - name: keys\n    file: channels/keys.ch\n"
        "  - name: motif\n    file: channels/motif.ch\n"
    )
    rows = END * BAR
    c = Lane(rows)
    for bar, key, mode, _, _, _ in SECTIONS:
        c.at(bar * BAR, f"key(root: {key}, mode: {mode})")
    c.at(0, "mark(name: a_minor)").at(8 * BAR, "mark(name: c_major)").at(16 * BAR, "mark(name: d_dorian)")
    c.at(rows - 1, "end()")
    f["conductor.ch"] = c.text()

    # The groove: a fill on every 4th pass; 16th hats only when busy.
    p = Lane(BAR)
    p.at(0, "args(busy: false)", "note(p: C1, inst: kick)")
    p.at(4, "note(p: C4, inst: snare, vel: 0.7, except: 4/4)")
    p.at(8, "note(p: C1, inst: kick)")
    p.at(10, "note(p: C1, inst: kick, vel: 0.6)")
    p.at(12, "note(p: C4, inst: snare, vel: 0.7, except: 4/4)")
    for k in range(0, 16, 2):
        p.at(k, "note(p: C4, inst: hat_closed, vel: 0.35)")
    for k in range(1, 16, 2):
        p.at(k, "note(p: C4, inst: hat_closed, vel: 0.18, if: $busy)")
    # The fill: snare hits rising through the last beats.
    for i, k in enumerate((4, 9, 11, 12, 13, 14, 15)):
        p.at(k, f"note(p: C4, inst: snare, vel: {0.4 + 0.08 * i:.2f}, on: 4/4)")
    f["patterns/groove.pat"] = p.text()

    # The bass: a degree of the key, with an octave jump.
    p = Lane(BAR)
    p.at(0, "args(deg: 1)", "oct(v: 2); note(d: $deg, len: 3)")
    p.at(6, "note(d: $deg, len: 1, vel: 0.6)")
    p.at(8, "oct(v: 3); note(d: $deg, len: 2, vel: 0.7)")
    p.at(11, "oct(v: 2); note(d: $deg, len: 2)")
    p.at(14, "note(d: $deg, len: 1, vel: 0.55)")
    f["patterns/bass.pat"] = p.text()

    # The motif: two bars of scale degrees, filled in when busy.
    p = Lane(2 * BAR)
    p.at(0, "args(busy: false, octave: 5)", "oct(v: $octave); note(d: 5, len: 3)")
    p.at(4, "note(d: 3, len: 2)")
    p.at(6, "note(d: 4, len: 1, if: $busy)")
    p.at(8, "note(d: 5, len: 4)")
    p.at(13, "note(d: 6, len: 1, if: $busy)")
    p.at(14, "note(d: 7, len: 2, if: $busy)")
    p.at(16, "note(d: 8, len: 3)")
    p.at(20, "note(d: 7, len: 2)")
    p.at(22, "note(d: 5, len: 1, if: $busy)")
    p.at(24, "note(d: 3, len: 6)")
    p.at(30, "note(d: 2, len: 2, if: $busy)")
    f["patterns/motif.pat"] = p.text()

    drums = Lane(rows)
    bass = Lane(rows)
    keys = Lane(rows)
    motif = Lane(rows)
    drums.at(0, "vol(v: 0.9)")
    bass.at(0, "inst(name: deep_bass); vol(v: 0.8)")
    keys.at(0, "inst(name: epiano); vol(v: 0.5); oct(v: 3); set(reverb: 0.25)")
    motif.at(0, "inst(name: pluck); vol(v: 0.45); set(delay: 0.3, reverb: 0.2)")
    for bar, _, _, chords, degrees, busy in SECTIONS:
        r = bar * BAR
        drums.at(r, f"pattern(name: groove, times: 8, busy: {'true' if busy else 'false'})")
        keys.at(r, f"prog(chords: \"{chords}\", every: 1bar, strum: 20ms, vel: 0.55)")
        keys.at(r + 4 * BAR, f"prog(chords: \"{chords}\", every: 1bar, strum: 20ms, vel: 0.55)")
        for i in range(8):
            bass.at(r + i * BAR, f"pattern(name: bass, deg: {degrees[i % 4]})")
        if bar == 0:
            motif.at(r + 4 * BAR, "pattern(name: motif, times: 2)")
        elif bar == 8:
            motif.at(r, "pattern(name: motif, times: 4, busy: true)")
        else:
            motif.at(r, "pattern(name: motif, times: 2, busy: true, octave: 4)")
            motif.at(r + 4 * BAR, "pattern(name: motif, times: 2, busy: true)")
    f["channels/drums.ch"] = drums.text()
    f["channels/bass.ch"] = bass.text()
    f["channels/keys.ch"] = keys.text()
    f["channels/motif.ch"] = motif.text()
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
