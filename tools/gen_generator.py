#!/usr/bin/env python3
"""Generates the "Drift Machine" example (docs/spec.md §6.5, M12): a
generative loop. Four bars play 16 times, and no two passes are the same,
yet every render of the song is the same, because the randomness comes from
song.yaml's seed. Writes rive/assets/examples/example-generator.song.

    python3 tools/gen_generator.py

- Euclidean rhythms (euclid) for kick ghosts, hats, rims and the bass, some
  hits left to chance (prob).
- humanize on the hats and the lead.
- The lead picks one note of the scale per step (note(d: […], pick: 1)), with
  prob, so the melody is new on every pass.
- A fill on the 4th bar, picked from three (pick(from: […])).
"""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "rive", "assets", "examples", "example-generator.song")
BAR = 16
LOOP = 4  # bars
PASSES = 16


class Lane:
    def __init__(self, rows):
        self.rows = [[] for _ in range(rows)]

    def at(self, row, *commands):
        self.rows[row].extend(commands)
        return self

    def text(self):
        return "".join("; ".join(r) + "\n" for r in self.rows)


def song():
    f = {}
    f["song.yaml"] = (
        "title: Drift Machine\nauthor: Partition examples\nbpm: 118\nsignature: 4/4\nrows_per_beat: 4\nseed: 2718\n"
        "channels:\n"
        "  - name: kick\n    file: channels/kick.ch\n"
        "  - name: hats\n    file: channels/hats.ch\n"
        "  - name: perc\n    file: channels/perc.ch\n"
        "  - name: bass\n    file: channels/bass.ch\n"
        "  - name: pad\n    file: channels/pad.ch\n"
        "  - name: lead\n    file: channels/lead.ch\n"
    )
    rows = LOOP * BAR
    c = Lane(rows + 1)
    c.at(0, "key(root: E, mode: dorian)", "mark(name: loop)")
    c.at(rows - 1, f"jump(to: loop, times: {PASSES - 1})")
    c.at(rows, "end()")
    f["conductor.ch"] = c.text()

    # Fills for the 4th bar, one picked each time round.
    p = Lane(BAR)
    for k in (8, 10, 12, 13, 14, 15):
        p.at(k, f"note(p: C4, inst: snare, vel: {0.35 + 0.05 * (k - 8):.2f})")
    f["patterns/fill_roll.pat"] = p.text()
    p = Lane(BAR)
    p.at(8, "euclid(hits: 5, steps: 8, p: C4, inst: tom, vel: 0.6)")
    f["patterns/fill_toms.pat"] = p.text()
    p = Lane(BAR)
    p.at(12, "note(p: C4, inst: clap, vel: 0.7)").at(14, "note(p: C4, inst: clap, vel: 0.5)").at(15, "note(p: C4, inst: clap, vel: 0.8)")
    f["patterns/fill_claps.pat"] = p.text()

    # The lead's step: one scale note, picked, sometimes.
    p = Lane(2)
    p.at(0, "note(d: [5, 7, 8, 9, 10, 12], pick: 1, prob: 0.55, len: 2)")
    f["patterns/step.pat"] = p.text()

    t = Lane(rows)
    t.at(0, "inst(name: kick)", f"euclid(hits: 4, steps: 16, p: C1, times: {LOOP})")
    t.at(0, f"euclid(hits: 3, steps: 16, rot: 3, p: C1, vel: 0.45, prob: 0.4, times: {LOOP})")
    t.at(3 * BAR, "pick(from: [fill_roll, fill_toms, fill_claps], prob: 0.8)")
    f["channels/kick.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "inst(name: hat_closed); humanize(time: 6ms, vel: 0.15)", f"euclid(hits: 11, steps: 16, p: C4, vel: 0.35, prob: 0.85, times: {LOOP})")
    t.at(0, f"euclid(hits: 3, steps: 8, rot: 2, p: C4, inst: hat_open, vel: 0.3, prob: 0.35, times: {LOOP * 2})")
    f["channels/hats.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "inst(name: rim); pan(v: 0.4); set(delay: 0.25)", f"euclid(hits: 5, steps: 16, rot: 1, p: C4, vel: 0.5, prob: 0.7, times: {LOOP})")
    t.at(0, f"euclid(hits: 2, steps: 16, rot: 4, p: C4, inst: clap, vel: 0.6, times: {LOOP})")
    f["channels/perc.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "inst(name: acid_bass); vol(v: 0.6); oct(v: 2)", "lfo(param: cutoff, rate: 4bar, depth: 1.5)")
    for bar in range(LOOP):
        degree = [1, 1, 4, 7][bar]
        t.at(bar * BAR, f"euclid(hits: 7, steps: 16, rot: {bar}, d: {degree}, len: 1, prob: 0.9)")
    f["channels/bass.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "inst(name: pad); vol(v: 0.35); oct(v: 3); set(reverb: 0.5)", "prog(chords: \"i IV i VII\", every: 1bar, strum: 40ms)")
    f["channels/pad.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "inst(name: pluck); vol(v: 0.45); oct(v: 4); set(delay: 0.35, reverb: 0.3); humanize(time: 12ms, vel: 0.2)", f"pattern(name: step, times: {rows // 2})")
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
