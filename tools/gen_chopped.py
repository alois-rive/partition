#!/usr/bin/env python3
"""Generates the "Chopped" example (docs/spec.md §7.4, M9): a sampled
boom-bap song and the samples it plays, synthesized here so they are free of
any license. Writes rive/assets/examples/example-chopped.song.

    python3 tools/gen_chopped.py

The samples:
  break    a one-bar drum break at 90 bpm, played sliced (16 slices)
  kick, snare, rim, hat_closed, hat_open    a drum kit (one-shots, hats choke)
  vox      a sung "ah" with a seamless sustain loop, played as a melody
  keys_c3, keys_c4    an electric-piano tone sampled twice (two zones)
  vinyl    a looping crackle bed
  cymbal   a crash, played reversed as a swell
"""

import base64
import io
import math
import os
import random
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "rive", "assets", "examples", "example-chopped.song")
rng = random.Random(9)

BPM = 90
STEP = 60 / BPM / 4  # a sixteenth: one row


# --- DSP helpers ----------------------------------------------------------------

def noise(n):
    return [rng.uniform(-1, 1) for _ in range(n)]


def one_pole_lp(x, cutoff, fs):
    a = math.exp(-2 * math.pi * cutoff / fs)
    y, out = 0.0, []
    for v in x:
        y = (1 - a) * v + a * y
        out.append(y)
    return out


def highpass(x, cutoff, fs):
    lp = one_pole_lp(x, cutoff, fs)
    return [a - b for a, b in zip(x, lp)]


def bandpass(x, f, q, fs):
    # A two-pole resonator, normalised to unit gain at f.
    r = math.exp(-math.pi * (f / q) / fs)
    a1, a2 = 2 * r * math.cos(2 * math.pi * f / fs), -r * r
    g = 1 - r
    y1 = y2 = 0.0
    out = []
    for v in x:
        y = g * v + a1 * y1 + a2 * y2
        y2, y1 = y1, y
        out.append(y)
    return out


def normalize(x, peak=0.9):
    m = max(abs(v) for v in x) or 1
    return [v * peak / m for v in x]


def mix_into(dst, src, at, gain=1.0):
    for i, v in enumerate(src):
        j = at + i
        if j >= len(dst):
            break
        dst[j] += v * gain


def reverb(x, fs, mix=0.15):
    # A small Schroeder room: four combs, two allpasses.
    out = [0.0] * len(x)
    for ms, fb in ((29.7, 0.77), (37.1, 0.75), (41.1, 0.73), (43.7, 0.71)):
        d = int(fs * ms / 1000)
        buf = [0.0] * d
        k = 0
        for i, v in enumerate(x):
            y = buf[k]
            buf[k] = v + y * fb
            k = (k + 1) % d
            out[i] += y * 0.25
    for ms, g in ((5.0, 0.7), (1.7, 0.7)):
        d = int(fs * ms / 1000)
        buf = [0.0] * d
        k = 0
        res = []
        for v in out:
            b = buf[k]
            y = -g * v + b
            buf[k] = v + g * y
            k = (k + 1) % d
            res.append(y)
        out = res
    return [a + b * mix for a, b in zip(x, out)]


# --- Drum sounds ------------------------------------------------------------------

def kick(fs, length=0.5):
    n = int(fs * length)
    out, phase = [], 0.0
    for i in range(n):
        t = i / fs
        f = 48 + 95 * math.exp(-t / 0.035)
        phase += 2 * math.pi * f / fs
        body = math.sin(phase) * math.exp(-t / 0.22)
        click = (rng.uniform(-1, 1) * math.exp(-t / 0.0025)) * 0.35
        out.append(math.tanh(1.6 * (body + click)))
    return normalize(out, 0.95)


def snare(fs, length=0.35):
    n = int(fs * length)
    hiss = bandpass(noise(n), 3500, 0.9, fs)
    out = []
    for i in range(n):
        t = i / fs
        tone = math.sin(2 * math.pi * 185 * t) * math.exp(-t / 0.06) + 0.5 * math.sin(2 * math.pi * 330 * t) * math.exp(-t / 0.04)
        out.append(tone * 0.6 + hiss[i] * 2.2 * math.exp(-t / 0.11))
    return normalize(out, 0.9)


def hat(fs, length, decay):
    n = int(fs * length)
    metal = [0.0] * n
    for f in (317, 540, 802, 1001, 1330, 1597):
        phase = rng.random()
        for i in range(n):
            phase = (phase + f * 3.1 / fs) % 1
            metal[i] += 1 if phase < 0.5 else -1
    x = [m * 0.15 + v for m, v in zip(metal, noise(n))]
    x = highpass(highpass(x, 7000, fs), 7000, fs)
    return normalize([v * math.exp(-(i / fs) / decay) for i, v in enumerate(x)], 0.7)


def rim(fs, length=0.07):
    n = int(fs * length)
    out = []
    for i in range(n):
        t = i / fs
        out.append((math.sin(2 * math.pi * 1700 * t) * 0.6 + math.sin(2 * math.pi * 520 * t)) * math.exp(-t / 0.012))
    return normalize(out, 0.8)


def cymbal(fs, length=1.6):
    n = int(fs * length)
    x = [0.0] * n
    for f in (205.3, 304.4, 369.6, 522.7, 540.0, 800.0):
        phase = rng.random()
        for i in range(n):
            phase = (phase + f * 4.1 / fs) % 1
            x[i] += 1 if phase < 0.5 else -1
    x = [a * 0.08 + b for a, b in zip(x, noise(n))]
    x = highpass(x, 4500, fs)
    return normalize([v * math.exp(-(i / fs) / 0.45) for i, v in enumerate(x)], 0.8)


# --- The break: one bar, sixteen steps, each hit starting on its step ----------------

def drum_break(fs):
    step = int(round(STEP * fs))
    n = step * 16
    out = [0.0] * n
    k, s, hc = kick(fs, 0.45), snare(fs, 0.3), hat(fs, 0.08, 0.025)
    ho = hat(fs, 0.3, 0.12)
    for at, g in ((0, 1.0), (3, 0.55), (10, 0.9)):
        mix_into(out, k, at * step, g)
    for at, g in ((4, 1.0), (12, 1.0), (7, 0.28), (9, 0.22), (15, 0.32)):
        mix_into(out, s, at * step, g)
    for at in range(16):
        if at == 14:
            mix_into(out, ho, at * step, 0.5)
        else:
            mix_into(out, hc, at * step, 0.5 if at % 2 == 0 else 0.28)
    out = reverb(out, fs, 0.12)
    return normalize([math.tanh(1.3 * v) for v in out], 0.9)


# --- Tones --------------------------------------------------------------------------

def formant_gain(f):
    # The vowel "ah": three formant peaks.
    g = 0.0
    for fc, bw, amp in ((730, 90, 1.0), (1090, 110, 0.5), (2440, 170, 0.25)):
        g += amp / math.sqrt(1 + ((f - fc) / (bw / 2)) ** 2)
    return g


def vox(fs):
    # Exactly 92 samples per period, so a loop of whole periods is seamless:
    # f0 = 24000 / 92 = 260.87 Hz, 5 cents under C4 (the instrument tunes it up).
    period = 92
    f0 = fs / period
    harmonics = [(k, formant_gain(k * f0) / k ** 0.6) for k in range(1, int((fs / 2) / f0))]
    one = [sum(a * math.sin(2 * math.pi * k * i / period) for k, a in harmonics) for i in range(period)]
    breath_cycle = one_pole_lp(noise(period * 8), 3000, fs)
    n = int(fs * 0.9)
    attack, tail_from = int(fs * 0.04), int(fs * 0.62)
    out = []
    for i in range(n):
        env = min(i / attack, 1.0)
        if i > tail_from:
            env *= math.exp(-(i - tail_from) / (fs * 0.07))
        out.append(env * (one[i % period] + 0.04 * breath_cycle[i % len(breath_cycle)]))
    return normalize(out, 0.85)


def epiano(fs, midi, length=1.2):
    f = 440 * 2 ** ((midi - 69) / 12)
    n = int(fs * length)
    partials = [(k, 1 / k ** 1.5, 1.4 / k ** 0.7) for k in range(1, 13) if k * f < fs / 2.2]
    out = []
    for i in range(n):
        t = i / fs
        v = sum(a * math.sin(2 * math.pi * k * f * t) * math.exp(-t / tau) for k, a, tau in partials)
        v += 0.25 * math.sin(2 * math.pi * 7.1 * f * t) * math.exp(-t / 0.05)  # the tine
        out.append(v * min(i / (fs * 0.002), 1.0))
    return normalize(out, 0.8)


def vinyl(fs, length=1.0):
    n = int(fs * length)
    hiss = one_pole_lp(noise(n * 2), 5000, fs)[n:]  # settled, so the loop has no step
    out = [h * 0.05 for h in hiss]
    for _ in range(int(length * 24)):
        at = rng.randrange(n)
        amp = rng.uniform(0.2, 0.9) * rng.choice((-1, 1))
        for i in range(40):
            out[(at + i) % n] += amp * math.exp(-i / 4) * (1 if i % 2 == 0 else -0.6)
    return normalize(out, 0.6)


# --- Files --------------------------------------------------------------------------

def wav_text(samples, fs):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(b"".join(struct.pack("<h", max(-32767, min(32767, int(round(v * 32767))))) for v in samples))
    data = base64.b64encode(buf.getvalue()).decode()
    return "\n".join(data[i:i + 76] for i in range(0, len(data), 76)) + "\n"


NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def pitch(midi):
    return f"{NAMES[midi % 12]}{midi // 12 - 1}"


class Lane:
    """A channel or pattern: commands by row, written one row per line."""

    def __init__(self, rows):
        self.rows = [[] for _ in range(rows)]

    def at(self, row, *commands):
        self.rows[row].extend(commands)
        return self

    def text(self):
        return "".join("; ".join(r) + "\n" for r in self.rows)


BAR = 16


def song():
    files = {}
    files["song.yaml"] = (
        "title: Chopped\nauthor: Partition examples\nbpm: 90\nsignature: 4/4\nrows_per_beat: 4\nswing: 0.08\n"
        "channels:\n"
        "  - name: break\n    file: channels/break.ch\n"
        "  - name: kit\n    file: channels/kit.ch\n"
        "  - name: keys\n    file: channels/keys.ch\n"
        "  - name: vox\n    file: channels/vox.ch\n"
        "  - name: bass\n    file: channels/bass.ch\n"
        "  - name: fx\n    file: channels/fx.ch\n"
    )
    bars = 24
    conductor = Lane(bars * BAR)
    conductor.at(0, "mark(name: intro)").at(4 * BAR, "mark(name: verse)").at(12 * BAR, "mark(name: hook)")
    conductor.at(20 * BAR, "mark(name: outro)").at(bars * BAR - 1, "end()")
    files["conductor.ch"] = conductor.text()

    # Instruments
    files["instruments/breaks.inst"] = (
        "sample(file: break, root: C2, slices: 16)\nfilter(type: lowpass, cutoff: 18k)\ndefaults(vol: 0.85)\n"
    )
    files["instruments/breaks_rev.inst"] = "sample(file: break, root: C2, slices: 16, reverse: true)\ndefaults(vol: 0.7)\n"
    files["instruments/kit.inst"] = (
        "sample(file: kick, key: C2, oneshot: true)\n"
        "sample(file: rim, key: C#2, oneshot: true)\n"
        "sample(file: snare, key: D2, oneshot: true)\n"
        "sample(file: hat_closed, key: F#2, oneshot: true, choke: 1)\n"
        "sample(file: hat_open, key: A#2, oneshot: true, choke: 1)\n"
        "voice(poly: 12)\n"
    )
    files["instruments/keys.inst"] = (
        "sample(file: keys_c3, root: C3, hi: B3)\nsample(file: keys_c4, root: C4, lo: C4)\n"
        "env(a: 2ms, d: 1.5s, s: 0.6, r: 450ms)\nfilter(type: lowpass, cutoff: 3.2k, res: 0.1)\n"
        "defaults(vol: 0.55, reverb: 0.25)\n"
    )
    files["instruments/vox.inst"] = (
        "sample(file: vox, root: C4, tune: 5c, loop: true, loop_start: 0.3066667s, loop_end: 0.6133333s)\n"
        "env(a: 25ms, d: 0ms, s: 1, r: 180ms)\nvoice(mono: true, glide: 45ms)\n"
        "filter(type: lowpass, cutoff: 5k)\ndefaults(vol: 0.5, delay: 0.22, reverb: 0.3)\n"
    )
    files["instruments/vinyl.inst"] = "sample(file: vinyl, loop: true)\nenv(a: 800ms, d: 0ms, s: 1, r: 2s)\n"
    files["instruments/swell.inst"] = "sample(file: cymbal, reverse: true, oneshot: true)\ndefaults(vol: 0.6, reverb: 0.35)\n"

    c2 = 36
    # Patterns
    p = Lane(BAR)
    for k in range(16):
        p.at(k, f"note(p: {pitch(c2 + k)})")
    files["patterns/break_a.pat"] = p.text()
    chop = [0, 1, 2, 3, 4, 5, 4, 5, 8, 9, 10, 11, 12, 12, 14, -15]
    p = Lane(BAR)
    for k, s in enumerate(chop):
        p.at(k, f"note(p: {pitch(c2 + abs(s))}, inst: breaks_rev)" if s < 0 else f"note(p: {pitch(c2 + s)})")
    files["patterns/break_b.pat"] = p.text()

    p = Lane(BAR)
    for k in (0, 7, 10):
        p.at(k, f"note(p: C2, vel: {0.95 if k == 0 else 0.7})")
    for k in (4, 12):
        p.at(k, "note(p: D2)")
    for k in (6, 15):
        p.at(k, "note(p: C#2, vel: 0.45)")
    for k in range(0, 16, 2):
        p.at(k, "note(p: A#2, vel: 0.5)" if k == 14 else f"note(p: F#2, vel: {0.55 if k % 4 == 0 else 0.4})")
    files["patterns/kit_a.pat"] = p.text()

    p = Lane(4 * BAR)
    for bar, (root, kind) in enumerate((("F3", "maj7"), ("E3", "min7"), ("D3", "min9"), ("C3", "maj7"))):
        p.at(bar * BAR, f"chord(root: {root}, type: {kind}, len: 10, strum: 35ms, vel: 0.6)")
        p.at(bar * BAR + 11, f"chord(root: {root}, type: {kind}, len: 4, strum: 15ms, vel: 0.35)")
    files["patterns/keys_prog.pat"] = p.text()

    p = Lane(4 * BAR)
    melody = [(0, "A4", 6), (6, "G4", 2), (8, "E4", 8), (16, "G4", 4), (20, "E4", 2), (22, "D4", 10),
              (32, "F4", 6), (38, "E4", 2), (40, "C4", 8), (48, "D4", 4), (52, "E4", 4), (56, "C4", 8)]
    for at, note, length in melody:
        p.at(at, f"note(p: {note}, len: {length})")
    files["patterns/vox_hook.pat"] = p.text()

    p = Lane(4 * BAR)
    for bar, root in enumerate(("F2", "E2", "D2", "C2")):
        p.at(bar * BAR, f"note(p: {root}, len: 6)").at(bar * BAR + 7, f"note(p: {root}, len: 2, vel: 0.6)")
        p.at(bar * BAR + 10, f"note(p: {root}, len: 5)")
    files["patterns/bass.pat"] = p.text()

    rows = bars * BAR
    # Channels
    ch = Lane(rows)
    ch.at(0, "inst(name: breaks); set(cutoff: 500)", "pattern(name: break_a, times: 4)")
    ch.at(3 * BAR, "ramp(cutoff: 18k, over: 1bar, curve: exp)")
    for i, name in enumerate(["break_a", "break_a", "break_a", "break_b"] * 2):
        ch.at((4 + i) * BAR, f"pattern(name: {name})")
    ch.at(12 * BAR, "vol(v: 0.45)", "pattern(name: break_b, times: 8)")
    ch.at(20 * BAR, "vol(v: 0.85)", "pattern(name: break_a, times: 4)", "ramp(cutoff: 400, over: 4bar, curve: exp)")
    files["channels/break.ch"] = ch.text()

    ch = Lane(rows)
    ch.at(12 * BAR, "inst(name: kit)", "pattern(name: kit_a, times: 8)")
    files["channels/kit.ch"] = ch.text()

    ch = Lane(rows)
    ch.at(0, "inst(name: keys)", "pattern(name: keys_prog, times: 6)")
    files["channels/keys.ch"] = ch.text()

    ch = Lane(rows)
    ch.at(12 * BAR, "inst(name: vox)", "lfo(param: detune, rate: 5.5Hz, depth: 0.12)", "pattern(name: vox_hook, times: 2)")
    ch.at(20 * BAR, "pattern(name: vox_hook)")
    files["channels/vox.ch"] = ch.text()

    ch = Lane(rows)
    ch.at(4 * BAR, "inst(name: sub_bass); vol(v: 0.7)", "pattern(name: bass, times: 4)")
    files["channels/bass.ch"] = ch.text()

    ch = Lane(rows)
    ch.at(0, f"note(p: C4, inst: vinyl, len: {rows}, vel: 0.35)")
    # The reversed crash ends on each section's downbeat: 1.6 s is 9.6 rows at 90 bpm.
    for bar in (4, 12, 20):
        ch.at(bar * BAR - 10, "note(p: C4, inst: swell, vel: 0.7)")
    files["channels/fx.ch"] = ch.text()

    # Samples
    files["samples/break.wav"] = wav_text(drum_break(22050), 22050)
    files["samples/kick.wav"] = wav_text(kick(24000), 24000)
    files["samples/snare.wav"] = wav_text(snare(24000), 24000)
    files["samples/rim.wav"] = wav_text(rim(24000), 24000)
    files["samples/hat_closed.wav"] = wav_text(hat(24000, 0.09, 0.03), 24000)
    files["samples/hat_open.wav"] = wav_text(hat(24000, 0.5, 0.16), 24000)
    files["samples/vox.wav"] = wav_text(vox(24000), 24000)
    files["samples/keys_c3.wav"] = wav_text(epiano(24000, 48), 24000)
    files["samples/keys_c4.wav"] = wav_text(epiano(24000, 60), 24000)
    files["samples/vinyl.wav"] = wav_text(vinyl(16000), 16000)
    files["samples/cymbal.wav"] = wav_text(cymbal(22050), 22050)
    return files


def main():
    files = song()
    order = ["song.yaml", "conductor.ch"] + sorted(p for p in files if p not in ("song.yaml", "conductor.ch"))
    out = "%partition-bundle 1\n" + "".join(f"=== {p}\n{files[p]}" for p in order)
    with open(OUT, "w") as f:
        f.write(out)
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(out) // 1024} KB, {len(files)} files)")


if __name__ == "__main__":
    main()
