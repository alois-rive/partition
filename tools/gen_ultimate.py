#!/usr/bin/env python3
"""Generates the "Ultimate" example: a six-minute suite in six movements that
uses every part of Partition, with its own instruments and its own samples
(synthesized here, so they are free of any license). Writes
rive/assets/examples/example-ultimate.song.

    python3 tools/gen_ultimate.py

The form (one theme, carried through keys, metres and tunings):
  I    Dawn      D major, 72 bpm. Rain, an aurora pad sweeping its own
                 wavetable (a sample), glass bells; the theme alone on the
                 cello.
  II   Pulse     76 bpm. Taiko and kick under a heartbeat, Euclidean hats
                 and shakers that change on every bar, the bass ducking
                 under the kick, generative arpeggios, the theme on the
                 expressive lead.
  III  Chorale   B minor, 3/4, slowing to 60 bpm, in just intonation from a
                 Scala file: a stereo choir, strings, the theme in minor.
  IV   Ascent    Back to equal temperament, D major, 4/4, accelerating to
                 92 bpm: the arpeggios thicken, the filters open, a
                 reversed swell.
  V    Summit    E major (a step up): everything, the theme's answer on the
                 lead an octave up with strings and choir, then a
                 ritardando.
  VI   Coda      66 bpm: the layers leave one by one; a last phrase played
                 twice (a jump), different each time, and the rain.

Features: samples (zones, loops, one-shots, reverse, stereo), wavetables
(built-in and from a sample), the modulation matrix, voice LFOs, stereo
width, bend and pressure, Scala tuning, keys and degrees, progressions,
pattern variables, passes, prob, humanize, euclid, pick, a seed, mixer
effects, sidechain, group and send buses, master effects, tempo ramps,
signature changes, swing, glides, LFOs, ramps and jumps.
"""

import base64
import io
import math
import os
import random
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "rive", "assets", "examples", "example-ultimate.song")
rng = random.Random(1618)
TAU = 2 * math.pi


# --- DSP helpers -------------------------------------------------------------

def one_pole_lp(x, cutoff, fs):
    a = math.exp(-TAU * cutoff / fs)
    y, out = 0.0, []
    for v in x:
        y = (1 - a) * v + a * y
        out.append(y)
    return out


def normalize(x, peak=0.9):
    m = max(abs(v) for v in x) or 1
    return [v * peak / m for v in x]


def wav_text(left, fs, right=None):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1 if right is None else 2)
        w.setsampwidth(2)
        w.setframerate(fs)
        q = lambda v: struct.pack("<h", max(-32767, min(32767, int(round(v * 32767)))))
        if right is None:
            w.writeframes(b"".join(q(v) for v in left))
        else:
            w.writeframes(b"".join(q(a) + q(b) for a, b in zip(left, right)))
    data = base64.b64encode(buf.getvalue()).decode()
    return "\n".join(data[i:i + 76] for i in range(0, len(data), 76)) + "\n"


# --- Samples -------------------------------------------------------------------

def vowel_gain(f, formants):
    g = 0.0
    for fc, bw, amp in formants:
        g += amp / math.sqrt(1 + ((f - fc) / (bw / 2)) ** 2)
    return g


def choir(fs=22050):
    """A stereo choir "ah" on C4 that loops seamlessly over its last second:
    every voice is a whole number of cycles per second, and the vibrato too.
    Six singers, three a side, each slightly off the others."""
    seconds = 1.6
    n = int(fs * seconds)
    formants = ((700, 110, 1.0), (1150, 130, 0.55), (2600, 220, 0.22), (3300, 300, 0.12))
    sides = []
    for side, hz_list in ((0, (261, 262, 264)), (1, (260, 262, 263))):
        out = [0.0] * n
        for v, hz in enumerate(hz_list):
            vib_rate = 5 + v  # whole Hz: periodic over a second
            vib_depth = 0.004 * hz / vib_rate
            phase0 = rng.random() * TAU
            partials = [(k, vowel_gain(k * hz, formants) / k ** 0.5) for k in range(1, int(5000 / hz))]
            for i in range(n):
                t = i / fs
                ph = TAU * hz * t + TAU * vib_depth * math.sin(TAU * vib_rate * t + phase0)
                out[i] += sum(a * math.sin(k * ph) for k, a in partials)
        sides.append(out)
    attack = int(fs * 0.35)
    for s in sides:
        for i in range(attack):
            s[i] *= i / attack
    peak = max(max(abs(v) for v in s) for s in sides)
    return [[v * 0.8 / peak for v in s] for s in sides]


def glass_table():
    """Eight 2048-frame cycles, a wavetable for osc(wave: table, table: glass):
    from a soft hollow tone (odd partials) to a bright glassy spectrum whose
    upper partials gather around a resonance that climbs."""
    size, frames = 2048, 8
    out = []
    for f in range(frames):
        u = f / (frames - 1)
        cycle = [0.0] * size
        for k in range(1, 48):
            hollow = (1 / k ** 1.4) if k % 2 == 1 else 0.0
            centre = 4 + u * 20
            glassy = math.exp(-((k - centre) / (2 + 3 * u)) ** 2) * 0.8 + 0.3 / k
            amp = hollow * (1 - u) + glassy * u
            if amp < 1e-4:
                continue
            ph = rng.random() * TAU if f == 0 else (k * 0.7)  # a fixed phase per partial keeps frames blending smoothly
            step = TAU * k / size
            for i in range(size):
                cycle[i] += amp * math.sin(step * i + ph)
        out.extend(normalize(cycle, 0.9))
    return out


def bell(fs=22050):
    """A glass bell on C5: inharmonic partials that ring and beat."""
    f = 523.25
    n = int(fs * 1.8)
    partials = [(1.0, 1.0, 1.6), (2.0, 0.5, 1.1), (2.76, 0.42, 0.8), (5.4, 0.25, 0.4), (8.93, 0.12, 0.25), (4.07, 0.18, 0.5), (1.003, 0.6, 1.8)]
    out = []
    for i in range(n):
        t = i / fs
        v = sum(a * math.sin(TAU * f * r * t) * math.exp(-t / tau) for r, a, tau in partials)
        v *= min(i / (fs * 0.0015), 1.0)
        out.append(v)
    return normalize(out, 0.85)


def taiko(fs=22050):
    """A big low drum: a falling body, a skin slap, a long boom."""
    n = int(fs * 1.1)
    out = []
    ph = 0.0
    slap = one_pole_lp([rng.uniform(-1, 1) for _ in range(n)], 1800, fs)
    for i in range(n):
        t = i / fs
        f = 62 + 70 * math.exp(-t / 0.05)
        ph += TAU * f / fs
        v = math.sin(ph) * math.exp(-t / 0.42) + 0.35 * math.sin(ph * 1.52) * math.exp(-t / 0.12)
        v += slap[i] * 0.6 * math.exp(-t / 0.018)
        out.append(math.tanh(v * 1.4))
    return normalize(out, 0.9)


def swell(fs=16000):
    """A washed cymbal, played reversed as a rising swell."""
    n = int(fs * 2.2)
    noise = [rng.uniform(-1, 1) for _ in range(n)]
    hp = [a - b for a, b in zip(noise, one_pole_lp(noise, 3500, fs))]
    out = []
    for i in range(n):
        t = i / fs
        out.append(hp[i] * math.exp(-t / 0.7) * (1 + 0.3 * math.sin(TAU * 7.3 * t)))
    return normalize(out, 0.8)


def rain(fs=16000):
    """A stereo bed of rain that loops: soft hiss and droplets, wrapped round
    so the end flows into the start."""
    n = int(fs * 1.5)
    sides = []
    for _ in range(2):
        fade = int(fs * 0.1)
        x = one_pole_lp([rng.uniform(-1, 1) for _ in range(n * 2 + fade * 2)], 2400, fs)[n:]  # settled
        # A crossfade into what follows the end, so the loop has no step.
        out = [0.12 * (x[fade + i] if i >= fade else x[fade + i] * (i / fade) + x[fade + n + i] * (1 - i / fade)) for i in range(n)]
        for _ in range(70):
            at = rng.randrange(n)
            f = rng.uniform(1800, 4500)
            amp = rng.uniform(0.05, 0.35)
            for i in range(int(fs * 0.025)):
                out[(at + i) % n] += amp * math.sin(TAU * f * i / fs) * math.exp(-i / (fs * 0.004))
        sides.append(out)
    peak = max(max(abs(v) for v in s) for s in sides)
    return [[v * 0.7 / peak for v in s] for s in sides]


# --- Writing ---------------------------------------------------------------------

class Lane:
    def __init__(self, rows):
        self.rows = [[] for _ in range(rows)]

    def at(self, row, *commands):
        self.rows[row].extend(commands)
        return self

    def text(self):
        while self.rows and not self.rows[-1]:
            self.rows.pop()
        return "".join("; ".join(r) + "\n" for r in self.rows)


def num(v):
    return f"{v:g}"


# The form: (name, bars, rows per bar).
SECTIONS = [("dawn", 16, 16), ("pulse", 24, 16), ("chorale", 24, 12), ("ascent", 24, 16), ("summit", 16, 16), ("coda", 14, 16)]
START = {}
_r = 0
for _name, _bars, _per in SECTIONS:
    START[_name] = _r
    _r += _bars * _per
TOTAL = _r


def bar(section, b):
    per = dict((s[0], s[2]) for s in SECTIONS)[section]
    return START[section] + b * per


# The theme: (beat, degree, beats, press, bend). Eight 4/4 bars over
# "Iadd9 iii7 vi9 IVmaj7 Iadd9 Vsus4 vi7 IVmaj7".
THEME_A = [
    (0, 5, 1.5, 0.5, 0), (1.5, 6, 0.5, 0.2, 0), (2, 5, 1, 0.3, 0), (3, 3, 1, 0.4, 0),
    (4, 2, 2, 0.9, 0), (6, 3, 0.5, 0.2, 0), (6.5, 5, 1.5, 0.6, 0),
    (8, 6, 1, 0.4, 0), (9, 8, 1, 0.6, 0), (10, 7, 1, 0.5, 0), (11, 6, 1, 0.3, 0),
    (12, 5, 3, 1.0, 0), (15, 3, 1, 0.3, 0),
    (16, 3, 1, 0.4, 0), (17, 2, 0.5, 0.2, 0), (17.5, 1, 0.5, 0.2, 0), (18, 2, 2, 0.8, 0),
    (20, 8, 1.5, 0.6, 0), (21.5, 9, 0.5, 0.3, 0), (22, 8, 2, 0.7, -1),
    (24, 10, 1.5, 0.8, 0), (25.5, 9, 0.5, 0.3, 0), (26, 8, 1, 0.5, 0), (27, 6, 1, 0.4, 0),
    (28, 7, 2, 1.0, 0), (30, 6, 1, 0.5, 0), (31, 5, 1, 0.4, 0),
]
# Its answer, higher, ending home: "Iadd9 iii7 vi9 IVmaj7 Iadd9 ii7 V Iadd9".
THEME_B = [
    (0, 10, 2, 0.7, 0), (2, 9, 1, 0.4, 0), (3, 8, 1, 0.4, 0),
    (4, 9, 3, 1.0, 0), (7, 7, 1, 0.3, 0),
    (8, 8, 1.5, 0.5, 0), (9.5, 10, 0.5, 0.4, 0), (10, 12, 2, 1.0, 0),
    (12, 11, 1, 0.6, 0), (13, 10, 1, 0.5, 0), (14, 9, 2, 0.8, 0),
    (16, 8, 1, 0.5, 0), (17, 9, 1, 0.5, 0), (18, 10, 2, 0.9, 0),
    (20, 11, 2, 0.8, 0), (22, 10, 1, 0.5, 0), (23, 9, 1, 0.4, 0),
    (24, 9, 2, 0.9, 0), (26, 7, 2, 0.7, 0),
    (28, 8, 4, 1.0, 0),
]
PROG_A = "Iadd9 iii7 vi9 IVmaj7 Iadd9 Vsus4 vi7 IVmaj7"
PROG_B = "Iadd9 iii7 vi9 IVmaj7 Iadd9 ii7 V Iadd9"
# Each bar's chord as a scale degree, for the arpeggios and the bass.
ROOTS_A = [1, 3, 6, 4, 1, 5, 6, 4]
ROOTS_B = [1, 3, 6, 4, 1, 2, 5, 1]
# The chorale in B minor, 3/4: the descending line under the theme's minor form.
PROG_C = "i VII VI iv i VII VI iv"
ROOTS_C = [1, 7, 6, 4, 1, 7, 6, 4]


def theme_pattern(theme, per_beat, beats_per_bar_from=4, beats_per_bar_to=4, expressive=True):
    """A theme as a pattern: rows per beat, and, for 3/4, each 4/4 bar folded
    into three beats (the notes keep their order and their proportions)."""
    scale = beats_per_bar_to / beats_per_bar_from
    bars = int(max(b + l for b, _, l, _, _ in theme) // beats_per_bar_from + 0.999)
    p = Lane(int(bars * beats_per_bar_to * per_beat))
    p.at(0, "args(octave: 4, level: 0.8)", "oct(v: $octave)")
    for beat, degree, length, press, bend in theme:
        row = int(round(beat * scale * per_beat))
        rows = max(1, int(round(length * scale * per_beat)))
        extra = ""
        if expressive:
            extra += f", press: {num(press)}"
            if bend:
                extra += f", bend: {bend}st"
        vel = 0.62 + 0.25 * press
        p.at(row, f"note(d: {degree}, len: {rows}, vel: {num(round(vel, 2))}{extra})")
    return p.text()


def song():
    f = {}
    f["song.yaml"] = (
        "title: Ultimate\nauthor: Partition examples\nbpm: 72\nsignature: 4/4\nrows_per_beat: 4\nseed: 1618\nmaster_volume: 0.8\n"
        "channels:\n"
        "  - name: taiko\n    file: channels/taiko.ch\n    bus: drums\n"
        "  - name: perc\n    file: channels/perc.ch\n    bus: drums\n"
        "  - name: bass\n    file: channels/bass.ch\n"
        "  - name: pad\n    file: channels/pad.ch\n"
        "  - name: bells\n    file: channels/bells.ch\n"
        "  - name: arp\n    file: channels/arp.ch\n"
        "  - name: choir\n    file: channels/choir.ch\n"
        "  - name: strings\n    file: channels/strings.ch\n"
        "  - name: cello\n    file: channels/cello.ch\n"
        "  - name: lead\n    file: channels/lead.ch\n"
        "  - name: air\n    file: channels/air.ch\n"
        "buses:\n"
        "  - name: drums\n    file: buses/drums.ch\n"
        "  - name: hall\n    file: buses/hall.ch\n"
    )

    # --- Samples ---
    left, right = choir()
    f["samples/choir.wav"] = wav_text(left, 22050, right)
    f["samples/glass.wav"] = wav_text(glass_table(), 48000)
    f["samples/bell.wav"] = wav_text(bell(), 22050)
    f["samples/taiko.wav"] = wav_text(taiko(), 22050)
    f["samples/swell.wav"] = wav_text(swell(), 16000)
    rl, rr = rain()
    f["samples/rain.wav"] = wav_text(rl, 16000, rr)
    f["tunings/b_just.scl"] = (
        "! b_just.scl\n!\n5-limit just intonation for B minor; the minor seventh is 16/9, so VII keeps a pure fifth\n 12\n!\n"
        " 16/15\n 9/8\n 6/5\n 5/4\n 4/3\n 45/32\n 3/2\n 8/5\n 5/3\n 16/9\n 15/8\n 2/1\n"
    )

    # --- Instruments ---
    f["instruments/aurora.inst"] = (
        "osc(wave: table, table: glass, unison: 5, spread: 0.1, pos: 0.15)\n"
        "osc(wave: table, table: formant, oct: -1, level: 0.5, pos: 0.2)\n"
        "voice(poly: 12, width: 1)\n"
        "env(a: 2.5s, d: 2s, s: 0.85, r: 3s)\n"
        "filter(type: lowpass, cutoff: 1500, res: 0.15, keytrack: 0.3)\n"
        "vlfo(n: 1, rate: 0.07, shape: tri)\n"
        "vlfo(n: 2, rate: 0.19, delay: 1s)\n"
        "mod(src: lfo1, dst: pos, amt: 0.4)\n"
        "mod(src: lfo2, dst: cutoff, amt: 0.5)\n"
        "mod(src: random, dst: pan, amt: 0.3)\n"
        "mod(src: random, dst: pitch, amt: 0.07)\n"
        "mod(src: vel, dst: cutoff, amt: 1)\n"
        "defaults(vol: 0.3)\n"
    )
    f["instruments/glass_bell.inst"] = (
        "sample(file: bell, root: C5)\n"
        "osc(wave: sine, oct: -1, level: 0.12)\n"
        "env(a: 0, d: 2.2s, s: 0, r: 1.6s)\n"
        "filter(type: lowpass, cutoff: 7k)\n"
        "voice(poly: 10)\n"
        "mod(src: random, dst: pan, amt: 0.55)\n"
        "mod(src: vel, dst: cutoff, amt: 1.5)\n"
    )
    f["instruments/choir.inst"] = (
        "sample(file: choir, root: C4, loop: true, loop_start: 0.6s, loop_end: 1.6s)\n"
        "env(a: 1.4s, d: 1s, s: 0.9, r: 2.2s)\n"
        "filter(type: lowpass, cutoff: 3.2k, res: 0.1)\n"
        "voice(poly: 12)\n"
        "vlfo(n: 1, rate: 4.6, delay: 0.8s)\n"
        "mod(src: lfo1, dst: pitch, amt: 0.1)\n"
        "mod(src: vel, dst: cutoff, amt: 1)\n"
    )
    f["instruments/ensemble.inst"] = (
        "osc(wave: saw, unison: 7, spread: 0.22, level: 0.6)\n"
        "osc(wave: table, table: harmonic, oct: -1, level: 0.35, pos: 0.4)\n"
        "voice(poly: 12, width: 0.9)\n"
        "env(a: 700ms, d: 1s, s: 0.85, r: 1.4s)\n"
        "filter(type: lowpass, cutoff: 1800, res: 0.1, keytrack: 0.5)\n"
        "mod_env(a: 1.2s, d: 2s, s: 0.4, r: 1s)\n"
        "mod(src: env2, dst: cutoff, amt: 1.2)\n"
        "vlfo(n: 1, rate: 5.1, delay: 600ms)\n"
        "mod(src: lfo1, dst: pitch, amt: 0.08)\n"
        "mod(src: press, dst: cutoff, amt: 1.2)\n"
        "mod(src: random, dst: pan, amt: 0.2)\n"
    )
    f["instruments/cello.inst"] = (
        "osc(wave: saw, level: 0.7)\n"
        "osc(wave: pulse, pw: 0.3, level: 0.4, detune: 6c)\n"
        "voice(mono: true, glide: 120ms, width: 0.15)\n"
        "env(a: 180ms, d: 400ms, s: 0.85, r: 900ms)\n"
        "filter(type: lowpass, cutoff: 850, res: 0.2, env: 0.35, keytrack: 0.4)\n"
        "filter_env(a: 300ms, d: 900ms, s: 0.5, r: 800ms)\n"
        "vlfo(n: 1, rate: 4.9, delay: 450ms)\n"
        "mod(src: lfo1, dst: pitch, amt: 0.3, via: press)\n"
        "mod(src: press, dst: cutoff, amt: 1)\n"
        "mod(src: vel, dst: level, amt: 0.3)\n"
    )
    f["instruments/voice_lead.inst"] = (
        "osc(wave: table, table: basic, pos: 0.35)\n"
        "osc(wave: table, table: glass, level: 0.45, pos: 0.5)\n"
        "voice(mono: true, glide: 90ms, width: 0.3)\n"
        "env(a: 40ms, d: 400ms, s: 0.8, r: 700ms)\n"
        "filter(type: lowpass, cutoff: 1300, res: 0.25, env: 0.3)\n"
        "vlfo(n: 1, rate: 5.3, delay: 350ms)\n"
        "mod(src: lfo1, dst: pitch, amt: 0.45, via: press)\n"
        "mod(src: press, dst: cutoff, amt: 1.6)\n"
        "mod(src: press, dst: pos, amt: 0.3)\n"
        "mod(src: vel, dst: pos, amt: 0.2)\n"
        "mod_env(a: 4ms, d: 160ms, s: 0, r: 100ms)\n"
        "mod(src: env2, dst: pitch, amt: -0.3)\n"
    )
    f["instruments/deep.inst"] = (
        "osc(wave: table, table: pwm, pos: 0.1)\n"
        "osc(wave: sine, oct: -1, level: 0.9)\n"
        "env(a: 4ms, d: 600ms, s: 0.6, r: 250ms)\n"
        "filter(type: lowpass, cutoff: 240, res: 0.2)\n"
        "drive(v: 0.15)\n"
        "voice(mono: true, glide: 40ms)\n"
        "mod_env(a: 2ms, d: 280ms, s: 0, r: 100ms)\n"
        "mod(src: env2, dst: cutoff, amt: 2.2)\n"
        "mod(src: env2, dst: pos, amt: 0.5)\n"
        "mod(src: vel, dst: cutoff, amt: 0.7)\n"
    )
    f["instruments/shimmer.inst"] = (
        "osc(wave: table, table: glass, pos: 0.6)\n"
        "osc(wave: sine, oct: 1, level: 0.25)\n"
        "env(a: 2ms, d: 500ms, s: 0.15, r: 700ms)\n"
        "filter(type: lowpass, cutoff: 3k, env: 0.4, keytrack: 0.3)\n"
        "voice(poly: 8)\n"
        "mod(src: key, dst: pos, amt: 0.15)\n"
        "mod(src: random, dst: pos, amt: 0.3)\n"
        "mod(src: random, dst: pan, amt: 0.7)\n"
        "param(name: glow, target: osc2.level, min: 0, max: 0.6)\n"
    )
    f["instruments/taiko.inst"] = "sample(file: taiko, root: C2, oneshot: true)\nvoice(poly: 4)\n"
    f["instruments/swell.inst"] = "sample(file: swell, root: C4, reverse: true, oneshot: true)\nvoice(poly: 2)\n"
    f["instruments/rain.inst"] = (
        "sample(file: rain, root: C4, loop: true, loop_start: 0, loop_end: 1.5s)\n"
        "env(a: 4s, d: 1s, s: 1, r: 6s)\n"
        "filter(type: lowpass, cutoff: 6k)\n"
    )

    # --- Buses ---
    f["buses/drums.ch"] = (
        "fx(type: eq, low: 2dB, low_freq: 120, mid: -2dB, mid_freq: 500, high: 2dB, high_freq: 8k)\n"
        "fx(type: comp, threshold: -18dB, ratio: 3, attack: 10ms, release: 120ms, makeup: 2dB)\n"
        "vol(v: 0.85); set(reverb: 0.15)\n"
    )
    f["buses/hall.ch"] = (
        "fx(type: filter, mode: highpass, cutoff: 350)\n"
        "fx(type: chorus, rate: 0.25, depth: 0.7, mix: 0.6)\n"
        "set(reverb: 0.85, delay: 0.25); vol(v: 0.75)\n"
    )

    # --- Conductor ---
    c = Lane(TOTAL + 1)
    c.at(0, "mark(name: dawn)", "key(root: D, mode: major)",
         "fx(type: filter, cutoff: 600)", "fx(type: eq, low: 1dB, high: 1.5dB, high_freq: 10k)",
         "fx(type: comp, threshold: -14dB, ratio: 2, attack: 25ms, release: 300ms)",
         "ramp(filter.cutoff: 20k, over: 12bar, curve: exp)")
    c.at(START["pulse"], "mark(name: pulse)", "bpm(v: 76)", "swing(v: 0.06)")
    c.at(bar("pulse", 20), "ramp(bpm: 66, over: 4bar)")
    c.at(START["chorale"], "mark(name: chorale)", "sig(v: 3/4)", "swing(v: 0)", "key(root: B, mode: minor)",
         "tuning(file: b_just, root: B)")
    c.at(bar("chorale", 16), "ramp(bpm: 60, over: 8bar)")
    c.at(START["ascent"], "mark(name: ascent)", "sig(v: 4/4)", "bpm(v: 72)", "key(root: D, mode: major)", "tuning(v: equal)",
         "ramp(bpm: 92, over: 16bar, curve: smooth)")
    c.at(START["summit"], "mark(name: summit)", "key(root: E, mode: major)")
    c.at(bar("summit", 12), "ramp(bpm: 70, over: 4bar)")
    c.at(START["coda"], "mark(name: coda)", "bpm(v: 66)")
    c.at(bar("coda", 6), "mark(name: echo)")
    c.at(bar("coda", 8) - 1, "jump(to: echo, times: 1)")
    c.at(bar("coda", 8), "ramp(filter.cutoff: 900, over: 6bar, curve: exp)", "ramp(master: 0.5, over: 6bar)")
    c.at(TOTAL, "end()")
    f["conductor.ch"] = c.text()

    # --- Patterns ---
    f["patterns/theme_a.pat"] = theme_pattern(THEME_A, 4)
    f["patterns/theme_b.pat"] = theme_pattern(THEME_B, 4)
    f["patterns/theme_waltz.pat"] = theme_pattern(THEME_A, 4, 4, 3)
    # The arpeggio on each degree's triad: in any key and mode, it follows.
    for d in range(1, 8):
        p = Lane(16)
        tones = [d, d + 2, d + 4, d + 7, d + 9, d + 11]
        p.at(0, f"note(d: {d + 7}, len: 2, vel: 0.6)")
        for k in range(2, 16, 2):
            p.at(k, f"note(d: [{', '.join(str(t) for t in tones)}], pick: 1, len: 2, vel: 0.45, prob: 0.85)")
        p.at(15, f"note(d: {d + 4}, len: 1, vel: 0.3, on: 2/2)")
        f[f"patterns/arp_{d}.pat"] = p.text()
    # The heartbeat: two hits, the second softer; a third on every fourth pass.
    p = Lane(16)
    p.at(0, "args(big: false)", "note(p: C1, inst: kick, vel: 0.9)")
    p.at(3, "note(p: C1, inst: kick, vel: 0.55)")
    p.at(8, "note(p: C2, inst: taiko, vel: 0.85, if: $big)", "note(p: C1, inst: kick, vel: 0.7)")
    p.at(11, "note(p: C1, inst: kick, vel: 0.45, prob: 0.5)")
    p.at(14, "note(p: C2, inst: taiko, vel: 0.5, on: 4/4)")
    f["patterns/heartbeat.pat"] = p.text()
    # Fills, one picked each time.
    p = Lane(16)
    for i, k in enumerate((8, 10, 12, 13, 14, 15)):
        p.at(k, f"note(p: C2, inst: taiko, vel: {num(0.45 + 0.09 * i)})")
    f["patterns/fill_taiko.pat"] = p.text()
    p = Lane(16)
    p.at(8, "euclid(hits: 5, steps: 8, p: C4, inst: snare, vel: 0.5)")
    p.at(15, "note(p: C4, inst: clap, vel: 0.8)")
    f["patterns/fill_snare.pat"] = p.text()
    p = Lane(16)
    p.at(4, "note(p: C4, inst: swell, vel: 0.6)")
    p.at(12, "note(p: G2, inst: tom, vel: 0.7)").at(14, "note(p: D2, inst: tom, vel: 0.8)")
    f["patterns/fill_toms.pat"] = p.text()
    # The bass under one bar: the root, its octave, a push into the next bar.
    p = Lane(16)
    p.at(0, "args(deg: 1, busy: false)", "note(d: $deg, len: 6, vel: 0.95)")
    p.at(6, "note(d: $deg, len: 2, vel: 0.6, if: $busy)")
    p.at(8, "note(d: $deg, len: 4, vel: 0.8)")
    p.at(12, "oct(v: 3); note(d: $deg, len: 2, vel: 0.65, if: $busy); oct(v: 2)")
    p.at(14, "note(d: $deg, len: 2, vel: 0.55, prob: 0.6)")
    f["patterns/bass_bar.pat"] = p.text()

    # --- Tracks ---
    rows = TOTAL

    # Rain: from the first second, out at the summit, back for the coda.
    t = Lane(rows)
    t.at(0, "inst(name: rain); vol(v: 0.22); set(stereo: 1)", "note(p: C4, len: 40bar)")
    t.at(START["coda"], "note(p: C4, len: 14bar, vel: 0.9)")
    f["channels/air.ch"] = t.text()

    # Pad: the harmony of every section, its wavetable swept by ramps.
    t = Lane(rows)
    t.at(0, "inst(name: aurora); oct(v: 3); set(send.hall: 0.35, pos: -0.2)", "ramp(pos: 0.3, over: 16bar)")
    t.at(0, 'prog(chords: "Iadd9 iii7 vi9 IVmaj7", every: 2bar, strum: 90ms, vel: 0.5)')
    t.at(bar("dawn", 8), f'prog(chords: "{PROG_A}", every: 1bar, strum: 90ms, vel: 0.55)')
    for b in range(0, 24, 8):
        prog = PROG_B if b == 16 else PROG_A
        t.at(bar("pulse", b), f'prog(chords: "{prog}", every: 1bar, strum: 60ms, vel: {num(0.55 + 0.05 * (b // 8))})')
    t.at(bar("pulse", 8), "lfo(param: cutoff, rate: 4bar, depth: 0.5, shape: sine)")
    t.at(START["chorale"], "lfo_off(param: cutoff)", f'prog(chords: "{PROG_C} {PROG_C} {PROG_C}", every: 1bar, vel: 0.45)')
    for b in range(0, 24, 8):
        t.at(bar("ascent", b), f'prog(chords: "{PROG_A}", every: 1bar, strum: 40ms, vel: {num(0.5 + 0.08 * (b // 8))})')
    t.at(START["ascent"], "ramp(pos: 0.8, cutoff: 3k, over: 24bar)")
    t.at(START["summit"], f'prog(chords: "{PROG_A}", every: 1bar, strum: 30ms, vel: 0.6)', "set(pos: 0.5)")
    t.at(bar("summit", 8), f'prog(chords: "{PROG_B}", every: 1bar, strum: 30ms, vel: 0.62)')
    t.at(START["coda"], 'prog(chords: "Iadd9 IVmaj7 vi9 IVmaj7 Iadd9 - - -", every: 2bar, strum: 120ms, vel: 0.5)',
         "ramp(pos: -0.3, cutoff: 700, over: 14bar)")
    f["channels/pad.ch"] = t.text()

    # Bells: a few notes in the dawn; the theme's echo at the summit.
    t = Lane(rows)
    t.at(0, "inst(name: glass_bell); vol(v: 0.4); oct(v: 5); set(send.hall: 0.5, delay: 0.3)", "humanize(time: 15ms, vel: 0.15)")
    for b in range(2, 16, 2):
        root = ROOTS_A[b // 2] if b < 8 else ROOTS_A[b - 8]
        t.at(bar("dawn", b) + 4, f"note(d: [{root + 4}, {root + 7}, {root + 9}], pick: 2, len: 8, vel: 0.5, prob: 0.8)")
    for b in range(0, 24, 4):
        t.at(bar("pulse", b) + 14, f"note(d: {ROOTS_A[b % 8] + 7}, len: 4, vel: 0.35, prob: 0.6)")
    for b in range(0, 16):
        roots = ROOTS_A if b < 8 else ROOTS_B
        t.at(bar("summit", b) + 6, f"note(d: [{roots[b % 8] + 7}, {roots[b % 8] + 9}], pick: 1, len: 6, vel: 0.45)")
    t.at(START["coda"] + 8, "note(d: 8, len: 2bar, vel: 0.5)")
    t.at(bar("coda", 6), "note(d: [8, 10, 12, 9], pick: 2, len: 1bar, vel: 0.4)")
    t.at(bar("coda", 12), "note(d: 8, len: 4bar, vel: 0.45)")
    f["channels/bells.ch"] = t.text()

    # Cello: the theme, alone, at dawn; the chorale's bass line; a counter-line later.
    t = Lane(rows)
    t.at(0, "inst(name: cello); vol(v: 0.42); set(send.hall: 0.3, reverb: 0.2)")
    t.at(bar("dawn", 8), "pattern(name: theme_a, octave: 3)")
    for b, deg in enumerate(ROOTS_C * 3):
        t.at(bar("chorale", b), f"oct(v: 2); note(d: {deg}, len: 1bar, vel: 0.6, press: {num(0.3 + 0.05 * (b % 4))})")
    for b in range(0, 24):
        if b % 2 == 0:
            deg = ROOTS_A[(b // 1) % 8]
            t.at(bar("ascent", b), f"oct(v: 3); note(d: {deg + 2}, len: 1bar, vel: 0.55, press: 0.6)")
    t.at(START["summit"], "pattern(name: theme_a, octave: 3, level: 0.7)")
    t.at(bar("summit", 8), "transpose(v: 0); pattern(name: theme_b, octave: 3)")
    t.at(START["coda"], "oct(v: 3); note(d: 5, len: 2bar, vel: 0.5, press: 0.6)")
    t.at(START["coda"] + 32, "note(d: 3, len: 2bar, vel: 0.45, press: 0.5)", )
    t.at(bar("coda", 12), "glide(to: E3, over: 1bar)")
    f["channels/cello.ch"] = t.text()

    # Lead: the theme in the pulse, its answer at the summit.
    t = Lane(rows)
    t.at(0, "inst(name: voice_lead); vol(v: 0.5); set(delay: 0.28, send.hall: 0.4)")
    t.at(bar("pulse", 8), "pattern(name: theme_a, octave: 4)")
    t.at(bar("pulse", 16), "pattern(name: theme_b, octave: 4)")
    t.at(START["summit"], "pattern(name: theme_a, octave: 5)")
    t.at(bar("summit", 8), "pattern(name: theme_b, octave: 5)")
    t.at(bar("coda", 6), "oct(v: 5); note(d: 5, len: 1bar, vel: 0.6, press: 0.8, bend: -2st)")
    t.at(bar("coda", 7), "note(d: [3, 2], pick: 1, len: 1bar, vel: 0.55, press: 0.9)")
    f["channels/lead.ch"] = t.text()

    # Choir: the chorale; the summit's long chords.
    t = Lane(rows)
    t.at(0, "inst(name: choir); vol(v: 0.5); oct(v: 3); set(send.hall: 0.5, reverb: 0.3)")
    t.at(START["chorale"], f'prog(chords: "{PROG_C} {PROG_C}", every: 1bar, strum: 80ms, vel: 0.6)')
    t.at(bar("chorale", 16), "pattern(name: theme_waltz, octave: 4)")
    t.at(START["summit"], f'prog(chords: "{PROG_A}", every: 1bar, inv: 1, vel: 0.45)')
    t.at(bar("summit", 8), f'prog(chords: "{PROG_B}", every: 1bar, inv: 1, vel: 0.5)')
    t.at(START["coda"], 'chord(d: 1, size: 3, len: 4bar, vel: 0.45)')
    f["channels/choir.ch"] = t.text()

    # Strings: the theme in minor in the chorale, the ascent's long swell, the summit.
    t = Lane(rows)
    t.at(0, "inst(name: ensemble); vol(v: 0.4); set(send.hall: 0.45)")
    t.at(bar("pulse", 16), f'prog(chords: "{PROG_B}", every: 1bar, len: 1bar, vel: 0.45, spread: 1)')
    t.at(START["chorale"], "pattern(name: theme_waltz, octave: 4)")
    t.at(bar("chorale", 8), "pattern(name: theme_waltz, octave: 5)")
    t.at(START["ascent"], "oct(v: 3)", "ramp(cutoff: 5k, over: 24bar, curve: exp)")
    for b in range(0, 24, 8):
        t.at(bar("ascent", b), f'prog(chords: "{PROG_A}", every: 1bar, spread: 1, vel: {num(0.45 + 0.1 * (b // 8))})')
    t.at(START["summit"], "oct(v: 4)", f'prog(chords: "{PROG_A}", every: 1bar, spread: 1, vel: 0.6)')
    t.at(bar("summit", 8), f'prog(chords: "{PROG_B}", every: 1bar, spread: 1, vel: 0.65)')
    t.at(START["coda"], "oct(v: 3)", 'chord(d: 1, size: 4, len: 6bar, vel: 0.4, press: 0.3)')
    f["channels/strings.ch"] = t.text()

    # Arpeggios: generative, on each bar's triad; brighter as the piece climbs.
    t = Lane(rows)
    t.at(0, "inst(name: shimmer); vol(v: 0.32); oct(v: 4); set(delay: 0.4, send.hall: 0.35, glow: 0); humanize(time: 8ms, vel: 0.12)",
         "fx(type: eq, low: -8dB, low_freq: 300)", "fx(type: phaser, rate: 0.15, depth: 0.6, feedback: 0.4, mix: 0.4)")
    for b in range(4, 24):
        roots = ROOTS_B if b >= 16 else ROOTS_A
        t.at(bar("pulse", b), f"pattern(name: arp_{roots[b % 8]})")
    for b in range(24):
        roots = ROOTS_A
        t.at(bar("ascent", b), f"pattern(name: arp_{roots[b % 8]})")
    t.at(START["ascent"], "ramp(glow: 0.6, over: 24bar)", "ramp(phaser.rate: 1.2Hz, over: 24bar)")
    for b in range(16):
        roots = ROOTS_A if b < 8 else ROOTS_B
        t.at(bar("summit", b), f"pattern(name: arp_{roots[b % 8]})")
    t.at(START["summit"], "oct(v: 5)")
    t.at(START["coda"], "oct(v: 4); set(glow: 0.1); ramp(vol: 0.1, over: 6bar)")
    for b in range(6):
        t.at(bar("coda", b), f"pattern(name: arp_{[1, 1, 4, 4, 6, 6][b]})")
    f["channels/arp.ch"] = t.text()

    # Bass: under the pulse, the ascent and the summit, ducking under the kick.
    t = Lane(rows)
    t.at(0, "inst(name: deep); vol(v: 0.6); oct(v: 2)",
         "fx(type: comp, threshold: -30dB, ratio: 8, attack: 2ms, release: 160ms, sidechain: taiko)")
    for b in range(24):
        roots = ROOTS_B if b >= 16 else ROOTS_A
        t.at(bar("pulse", b), f"pattern(name: bass_bar, deg: {roots[b % 8]}, busy: {'true' if b >= 8 else 'false'})")
    for b in range(4, 24):
        t.at(bar("ascent", b), f"pattern(name: bass_bar, deg: {ROOTS_A[b % 8]}, busy: true)")
    for b in range(16):
        roots = ROOTS_A if b < 8 else ROOTS_B
        t.at(bar("summit", b), f"pattern(name: bass_bar, deg: {roots[b % 8]}, busy: true)")
    t.at(START["coda"], "note(d: 1, len: 4bar, vel: 0.7)")
    f["channels/bass.ch"] = t.text()

    # Drums: the heartbeat, its fills picked at random; the summit hits harder.
    t = Lane(rows)
    t.at(0, "vol(v: 0.95)")
    t.at(bar("dawn", 12), "note(p: C2, inst: swell, vel: 0.5)")
    t.at(START["pulse"], "pattern(name: heartbeat, times: 7)")
    t.at(bar("pulse", 7), "pick(from: [fill_taiko, fill_snare, fill_toms])")
    t.at(bar("pulse", 8), "pattern(name: heartbeat, times: 11, big: true)")
    t.at(bar("pulse", 19), "pick(from: [fill_taiko, fill_snare, fill_toms])")
    t.at(bar("pulse", 20), "note(p: C2, inst: taiko, vel: 0.7)")
    t.at(bar("chorale", 22), "note(p: C2, inst: taiko, vel: 0.4)")
    t.at(bar("ascent", 4), "pattern(name: heartbeat, times: 19)")
    t.at(bar("ascent", 22), "note(p: C4, inst: swell, vel: 0.8)")
    t.at(bar("ascent", 23), "pick(from: [fill_taiko, fill_toms])")
    t.at(START["summit"], "note(p: C2, inst: taiko, vel: 1)", "pattern(name: heartbeat, times: 15, big: true)")
    t.at(bar("summit", 15), "pattern(name: fill_taiko)")
    t.at(START["coda"], "note(p: C2, inst: taiko, vel: 0.8)")
    t.at(bar("coda", 12), "note(p: C2, inst: taiko, vel: 0.5)")
    f["channels/taiko.ch"] = t.text()

    t = Lane(rows)
    t.at(0, "humanize(time: 7ms, vel: 0.15); pan(v: 0.15)")
    t.at(bar("pulse", 4), "euclid(hits: 7, steps: 16, p: C4, inst: shaker, vel: 0.3, prob: 0.8, times: 4)")
    t.at(bar("pulse", 8), "euclid(hits: 11, steps: 16, p: C4, inst: hat_closed, vel: 0.28, prob: 0.85, times: 12)",
         "euclid(hits: 3, steps: 8, rot: 2, p: C4, inst: rim, vel: 0.4, prob: 0.6, times: 24)")
    t.at(bar("pulse", 12), "euclid(hits: 2, steps: 16, rot: 4, p: C4, inst: clap, vel: 0.5, times: 8)")
    t.at(bar("ascent", 8), "euclid(hits: 7, steps: 16, p: C4, inst: shaker, vel: 0.3, prob: 0.9, times: 8)")
    t.at(bar("ascent", 12), "euclid(hits: 13, steps: 16, p: C4, inst: hat_closed, vel: 0.3, prob: 0.9, times: 12)",
         "euclid(hits: 2, steps: 16, rot: 4, p: C4, inst: clap, vel: 0.55, times: 12)")
    t.at(START["summit"], "euclid(hits: 11, steps: 16, p: C4, inst: hat_closed, vel: 0.32, prob: 0.9, times: 15)",
         "euclid(hits: 2, steps: 16, rot: 4, p: C4, inst: snare, vel: 0.6, times: 15)",
         "euclid(hits: 3, steps: 8, rot: 1, p: C4, inst: hat_open, vel: 0.25, prob: 0.5, times: 30)")
    f["channels/perc.ch"] = t.text()
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
