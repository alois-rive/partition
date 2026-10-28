#!/usr/bin/env python3
"""Generates the "Wavefront" example (docs/spec.md §7.6, M13): sound design.
Writes rive/assets/examples/example-wavefront.song.

    python3 tools/gen_wavefront.py

- An evolving wavetable pad: two table oscillators swept by slow voice LFOs
  and by ramps of `pos`, wide in stereo, each voice panned at random.
- An expressive lead: notes that bend into and out of their pitch, pressure
  that opens the filter and brings in a delayed vibrato (mod via press).
- A plucked bass whose table position and cutoff follow the second envelope.
- The whole song in 5-limit just intonation on D, from a Scala file.
"""

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "rive", "assets", "examples", "example-wavefront.song")
BAR = 16
BARS = 32


class Lane:
    def __init__(self, rows):
        self.rows = [[] for _ in range(rows)]

    def at(self, row, *commands):
        self.rows[row].extend(commands)
        return self

    def text(self):
        return "".join("; ".join(r) + "\n" for r in self.rows)


# 5-limit just intonation on D; the minor seventh is 16/9, so the VII chord
# (C E G) keeps a pure fifth.
SCALA = """! d_just.scl
!
5-limit just intonation, for D minor
 12
!
 16/15
 9/8
 6/5
 5/4
 4/3
 45/32
 3/2
 8/5
 5/3
 16/9
 15/8
 2/1
"""

PAD = """osc(wave: table, table: formant, unison: 5, spread: 0.12, pos: 0.1)
osc(wave: table, table: harmonic, oct: -1, level: 0.55, pos: 0.3)
voice(poly: 12, width: 0.9)
env(a: 1.8s, d: 1s, s: 0.8, r: 2.5s)
filter(type: lowpass, cutoff: 1400, res: 0.2, keytrack: 0.3)
vlfo(n: 1, rate: 0.11, shape: tri)
vlfo(n: 2, rate: 0.27, delay: 1s)
mod(src: lfo1, dst: pos, amt: 0.35)
mod(src: lfo2, dst: cutoff, amt: 0.7)
mod(src: random, dst: pan, amt: 0.35)
mod(src: random, dst: pitch, amt: 0.08)
"""

LEAD = """osc(wave: table, table: basic, pos: 0.45)
osc(wave: saw, detune: 0.08, level: 0.35)
voice(mono: true, glide: 70ms, width: 0.25)
env(a: 25ms, d: 300ms, s: 0.75, r: 450ms)
filter(type: lowpass, cutoff: 1100, res: 0.3, env: 0.35)
vlfo(n: 1, rate: 5.6, delay: 300ms)
mod(src: lfo1, dst: pitch, amt: 0.45, via: press)
mod(src: press, dst: cutoff, amt: 1.6)
mod(src: vel, dst: pos, amt: 0.35)
mod_env(a: 5ms, d: 180ms, s: 0, r: 100ms)
mod(src: env2, dst: pitch, amt: 0.3)
"""

BASS = """osc(wave: table, table: pwm, pos: 0.1)
osc(wave: sine, oct: -1, level: 0.8)
env(a: 3ms, d: 500ms, s: 0.5, r: 150ms)
filter(type: lowpass, cutoff: 260, res: 0.25)
mod_env(a: 2ms, d: 260ms, s: 0, r: 100ms)
mod(src: env2, dst: cutoff, amt: 2.5)
mod(src: env2, dst: pos, amt: 0.6)
mod(src: vel, dst: cutoff, amt: 0.8)
"""

# The lead's two phrases: (row, degree, rows, bend, press, vel).
PHRASE_A = [
    (0, 5, 6, 0, 0.6, 0.8), (6, 4, 2, 0, 0.2, 0.6), (8, 3, 6, 0, 0.8, 0.75), (14, 2, 2, -1, 0.0, 0.55),
    (16, 1, 10, 0, 1.0, 0.85), (26, 3, 2, 0, 0.3, 0.6), (28, 4, 4, 1, 0.5, 0.7),
]
PHRASE_B = [
    (0, 8, 4, 0, 0.7, 0.9), (4, 7, 2, 0, 0.3, 0.6), (6, 5, 2, 0, 0.2, 0.6), (8, 6, 8, 2, 0.9, 0.85),
    (16, 5, 6, 0, 1.0, 0.8), (22, 4, 2, 0, 0.2, 0.55), (24, 3, 8, -2, 0.6, 0.7),
]


def phrase(notes):
    p = Lane(2 * BAR)
    for row, degree, length, bend, press, vel in notes:
        bent = f", bend: {bend}" if bend else ""
        p.at(row, f"note(d: {degree}, len: {length}, vel: {vel}{bent}, press: {press})")
    return p.text()


def song():
    f = {}
    f["song.yaml"] = (
        "title: Wavefront\nauthor: Partition examples\nbpm: 84\nsignature: 4/4\nrows_per_beat: 4\n"
        "channels:\n"
        "  - name: pad\n    file: channels/pad.ch\n"
        "  - name: bass\n    file: channels/bass.ch\n"
        "  - name: drums\n    file: channels/drums.ch\n"
        "  - name: lead\n    file: channels/lead.ch\n"
    )
    rows = BARS * BAR
    c = Lane(rows + 1)
    c.at(0, "key(root: D, mode: minor)", "tuning(file: d_just, root: D)", "mark(name: rise)")
    c.at(8 * BAR, "mark(name: pulse)").at(16 * BAR, "mark(name: soar)").at(24 * BAR, "mark(name: fade)")
    c.at(rows, "end()")
    f["conductor.ch"] = c.text()
    f["tunings/d_just.scl"] = SCALA
    f["instruments/wave_pad.inst"] = PAD
    f["instruments/glass_lead.inst"] = LEAD
    f["instruments/table_bass.inst"] = BASS
    f["patterns/phrase_a.pat"] = phrase(PHRASE_A)
    f["patterns/phrase_b.pat"] = phrase(PHRASE_B)

    # The bass: a plucked figure on the chord's root.
    p = Lane(BAR)
    p.at(0, "args(deg: 1)", "note(d: $deg, len: 3, vel: 0.9)")
    p.at(6, "note(d: $deg, len: 1, vel: 0.6)")
    p.at(8, "oct(v: 3); note(d: $deg, len: 2, vel: 0.75); oct(v: 2)")
    p.at(11, "note(d: $deg, len: 2, vel: 0.8)")
    p.at(14, "note(d: 5, len: 2, vel: 0.5)")
    f["patterns/bass.pat"] = p.text()

    p = Lane(BAR)
    p.at(0, "note(p: C1, inst: kick, vel: 0.85)")
    p.at(8, "note(p: C1, inst: kick, vel: 0.7)").at(10, "note(p: C1, inst: kick, vel: 0.45)")
    p.at(4, "note(p: C4, inst: rim, vel: 0.5)").at(12, "note(p: C4, inst: snare, vel: 0.55)")
    for k in range(2, 16, 4):
        p.at(k, "note(p: C4, inst: hat_closed, vel: 0.25)")
    f["patterns/beat.pat"] = p.text()

    # The pad: a chord every two bars, its tables swept by ramps of pos.
    t = Lane(rows)
    t.at(0, "inst(name: wave_pad); vol(v: 0.3); oct(v: 3); set(reverb: 0.45, pos: -0.1)", "ramp(pos: 0.5, over: 8bar)")
    for bar in range(0, BARS, 8):
        t.at(bar * BAR, 'prog(chords: "i VI III VII", every: 2bar, strum: 80ms, vel: 0.6)')
    t.at(8 * BAR, "ramp(pos: 0.1, over: 8bar)")
    t.at(16 * BAR, "ramp(pos: 0.7, stereo: 1, over: 8bar)")
    t.at(24 * BAR, "ramp(pos: -0.3, cutoff: 500, over: 8bar)")
    f["channels/pad.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "inst(name: table_bass); vol(v: 0.5); oct(v: 2)")
    for bar in range(8, 24):
        t.at(bar * BAR, f"pattern(name: bass, deg: {[1, 6, 3, 7][(bar // 2) % 4]})")
    f["channels/bass.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "vol(v: 0.8)")
    t.at(8 * BAR, "pattern(name: beat, times: 16)")
    f["channels/drums.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "inst(name: glass_lead); vol(v: 0.5); oct(v: 4); set(delay: 0.3, reverb: 0.3)")
    t.at(10 * BAR, "pattern(name: phrase_a, times: 3)")
    t.at(16 * BAR, "oct(v: 5)", "pattern(name: phrase_b, times: 2)")
    t.at(20 * BAR, "pattern(name: phrase_a, times: 2)")
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
