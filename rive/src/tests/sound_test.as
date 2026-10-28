import { Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { EventKind } from "../score/events";
import { packScore } from "../audio/pack";
import { encodeWav, FORMAT_FLOAT32 } from "../audio/wav";
import { Engine } from "../synth/engine";
import { buildBank, decodeWav, encodeBase64 } from "../synth/samples";
import { builtinTuning, parseScala } from "../lang/tuning";

const SR: f64 = 48000;

// A one-channel song (120 bpm, a row 0.125 s) whose instrument `s` is `inst`,
// with `extra` files.
@editTime
function compile(inst: string, channel: string, extra: Array<SongFile> = [], conductor: string = ""): Score {
    return compileSong(songOf(inst, channel, extra, conductor), new CompileOptions());
}

@editTime
function songOf(inst: string, channel: string, extra: Array<SongFile>, conductor: string): Song {
    let files = [
        new SongFile("song.yaml", "bpm: 120\nrows_per_beat: 4\nchannels:\n  - file: c.ch\n"),
        new SongFile("conductor.ch", conductor),
        new SongFile("c.ch", channel),
        new SongFile("instruments/s.inst", inst),
    ];
    for (let i = 0; i < extra.length; i++) files.push(extra[i]);
    return Song.fromFiles(files);
}

// Renders the song, samples and all; interleaved stereo.
@editTime
function render(inst: string, channel: string, seconds: f64, extra: Array<SongFile> = []): Float32Array {
    let song = songOf(inst, channel, extra, "");
    let score = compileSong(song, new CompileOptions());
    let packed = packScore(score);
    let engine = new Engine(SR, 2);
    engine.attachSamples(buildBank(song.sampleTexts()).bank);
    engine.load(packed.events, packed.instruments, 0);
    engine.play();
    let frames = <i32>(seconds * SR);
    let out = new Float32Array(frames * 2);
    let done = 0;
    while (done < frames) {
        let n = min<i32>(333, frames - done);
        engine.renderStereo(out, done, n);
        done += n;
    }
    return out;
}

// Rising zero crossings of the left side per second, between two times.
@editTime
function frequency(buf: Float32Array, from: f64, to: f64): f64 {
    let a = <i32>(from * SR);
    let b = <i32>(to * SR);
    let count = 0;
    for (let i = a + 1; i < b; i++) if (buf[(i - 1) * 2] < 0 && buf[i * 2] >= 0) count++;
    return <f64>count / (to - from);
}

// The peak of one side (0 left, 1 right) between two times.
@editTime
function peak(buf: Float32Array, side: i32, from: f64, to: f64): f64 {
    let p = 0.0;
    for (let i = <i32>(from * SR); i < <i32>(to * SR); i++) p = Math.max(p, Math.abs(<f64>buf[i * 2 + side]));
    return p;
}

// The largest difference between the two sides.
@editTime
function sideDifference(buf: Float32Array): f64 {
    let d = 0.0;
    for (let i = 0; i < buf.length; i += 2) d = Math.max(d, Math.abs(<f64>buf[i] - <f64>buf[i + 1]));
    return d;
}

@editTime
function difference(a: Float32Array, b: Float32Array): f64 {
    let d = 0.0;
    for (let i = 0; i < min<i32>(a.length, b.length); i++) d = Math.max(d, Math.abs(<f64>a[i] - <f64>b[i]));
    return d;
}

@editTime
function finite(buf: Float32Array): bool {
    for (let i = 0; i < buf.length; i++) if (!isFinite(<f64>buf[i])) return false;
    return true;
}

@editTime
function problems(score: Score): string {
    let out = new Array<string>();
    for (let i = 0; i < score.diagnostics.length; i++) if (score.diagnostics[i].isError) out.push(score.diagnostics[i].message);
    return out.join("; ");
}

@editTime
function pitches(score: Score): Array<f64> {
    let out = new Array<f64>();
    for (let i = 0; i < score.events.length; i++) if (score.events[i].kind == EventKind.NoteOn) out.push(score.events[i].pitch);
    return out;
}

@editTime
function near(a: f64, b: f64, within: f64): bool {
    return Math.abs(a - b) <= within;
}

const SINE = "osc(wave: sine)\nenv(a: 0, d: 0, s: 1, r: 0.01)\n";

export class SoundTests extends Tests {
    override run(): void {
        group("tunings", () => {
            test("just, pythagorean and n equal steps", (expect) => {
                let just = builtinTuning("just", 12, 60);
                expect.that(near(just.tune(64), 60 + 3.8631, 1e-3)).is(true); // 5/4
                expect.that(near(just.tune(67), 60 + 7.0196, 1e-3)).is(true); // 3/2
                expect.that(near(just.tune(52), 48 + 3.8631, 1e-3)).is(true); // an octave down
                expect.that(near(builtinTuning("pythagorean", 12, 60).tune(64), 64.0782, 1e-3)).is(true);
                let edo = builtinTuning("edo", 19, 60);
                expect.that(near(edo.tune(61), 60 + 12.0 / 19, 1e-9)).is(true);
                expect.that(near(edo.tune(79), 72, 1e-9)).is(true); // 19 keys make an octave
                expect.that(near(edo.tune(41), 48, 1e-9)).is(true);
                expect.that(near(builtinTuning("equal", 12, 60).tune(65.5), 65.5, 1e-9)).is(true);
                // The root sounds as written, in any tuning.
                expect.that(near(builtinTuning("just", 12, 62).tune(62), 62, 1e-9)).is(true);
            });
            test("Scala files: cents, ratios, comments, and errors", (expect) => {
                let t = parseScala("! mine.scl\n!\nThree notes\n 3\n150.0\n5/4 a third\n2/1\n", 60);
                expect.that(t.error).is("");
                expect.that(t.steps).is(3);
                expect.that(near(t.tune(61), 61.5, 1e-9)).is(true);
                expect.that(near(t.tune(62), 63.8631, 1e-3)).is(true);
                expect.that(near(t.tune(63), 72, 1e-9)).is(true);
                expect.that(parseScala("x\nmany\n", 60).error.includes("not a number of notes")).is(true);
                expect.that(parseScala("x\n3\n100.0\n", 60).error.includes("lists 1 of its 3")).is(true);
                expect.that(parseScala("x\n1\n-1/2\n", 60).error.length > 0).is(true);
            });
            test("tuning() in a track, the conductor, or from a file", (expect) => {
                let own = compile(SINE, "tuning(v: just)\nnote(p: [C4, E4, G4])\n");
                expect.that(problems(own)).is("");
                let p = pitches(own);
                expect.that(near(p[0], 60, 1e-9) && near(p[1], 63.8631, 1e-3) && near(p[2], 67.0196, 1e-3)).is(true);
                let song = compile(SINE, "note(p: C#4)\n", [], "tuning(v: edo, steps: 24)\n");
                expect.that(near(pitches(song)[0], 60.5, 1e-9)).is(true);
                let file = compile(SINE, "tuning(file: mine, root: D4)\nnote(p: D#4)\n", [new SongFile("tunings/mine.scl", "m\n2\n300.0\n2/1\n")]);
                expect.that(problems(file)).is("");
                expect.that(near(pitches(file)[0], 65, 1e-9)).is(true);
                expect.that(problems(compile(SINE, "tuning(file: nope)\n")).includes("there is no tunings/nope.scl")).is(true);
                expect.that(problems(compile(SINE, "tuning(file: bad)\n", [new SongFile("tunings/bad.scl", "b\nzz\n")])).includes("not a number of notes")).is(true);
            });
        });

        group("expression", () => {
            test("bend slides the note's pitch over its length", (expect) => {
                let s = compile(SINE, "inst(name: s); note(p: A4, len: 8, bend: 12, press: 0.5)\n");
                expect.that(problems(s)).is("");
                let found = false;
                for (let i = 0; i < s.events.length; i++) {
                    let e = s.events[i];
                    if (e.kind == EventKind.NoteOn) {
                        expect.that(e.bend).is(12);
                        expect.that(e.press).is(0.5);
                        found = true;
                    }
                }
                expect.that(found).is(true);
                let out = render(SINE, "inst(name: s); note(p: A4, len: 8, bend: 12)\n", 1);
                let start = frequency(out, 0.0, 0.1);
                let late = frequency(out, 0.85, 0.95);
                expect.that(start > 430 && start < 500).is(true);
                expect.that(late > 760 && late < 860).is(true); // 9/10 of an octave up
                let flat = render(SINE, "inst(name: s); note(p: A4, len: 8)\n", 1);
                expect.that(near(frequency(flat, 0.85, 0.95), 440, 25)).is(true);
            });
        });

        group("modulation", () => {
            test("velocity to pitch, scaled by the route's amount", (expect) => {
                let inst = SINE + "mod(src: vel, dst: pitch, amt: 12)\n";
                let loud = render(inst, "inst(name: s); note(p: A4, len: 8, vel: 1)\n", 0.5);
                let soft = render(inst, "inst(name: s); note(p: A4, len: 8, vel: 0.5)\n", 0.5);
                expect.that(near(frequency(loud, 0.1, 0.4), 880, 30)).is(true);
                expect.that(near(frequency(soft, 0.1, 0.4), 622, 30)).is(true);
            });
            test("the second envelope closes the level; via scales a route", (expect) => {
                let shut = render(SINE + "mod_env(a: 0, d: 0, s: 1, r: 0.1)\nmod(src: env2, dst: level, amt: -1)\n", "inst(name: s); note(p: A4, len: 8)\n", 0.5);
                expect.that(peak(shut, 0, 0.1, 0.4) < 0.01).is(true);
                let open = render(SINE + "mod(src: env2, dst: level, amt: -1, via: press)\n", "inst(name: s); note(p: A4, len: 8, press: 0)\n", 0.5);
                expect.that(peak(open, 0, 0.1, 0.4) > 0.1).is(true);
            });
            test("a voice LFO wobbles the pitch; cutoff follows the key", (expect) => {
                let wobble = render(SINE + "vlfo(n: 1, rate: 4, shape: square)\nmod(src: lfo1, dst: pitch, amt: 7)\n", "inst(name: s); note(p: A4, len: 8)\n", 0.5);
                let up = frequency(wobble, 0.01, 0.12);
                let down = frequency(wobble, 0.135, 0.245);
                expect.that(up > 600 && down < 340).is(true);
                let saw = "osc(wave: saw)\nfilter(type: lowpass, cutoff: 400)\nenv(a: 0, d: 0, s: 1, r: 0.01)\n";
                let plain = render(saw, "inst(name: s); note(p: A2, len: 8)\n", 0.3);
                let keyed = render(saw + "mod(src: key, dst: cutoff, amt: -2)\n", "inst(name: s); note(p: A2, len: 8)\n", 0.3);
                expect.that(peak(keyed, 0, 0.1, 0.3) > peak(plain, 0, 0.1, 0.3) * 1.05).is(true); // below C4: opened
                expect.that(problems(compile("mod(src: nope, dst: pitch, amt: 1)\n", "")).length > 0).is(true);
            });
        });

        group("wavetables", () => {
            test("pos moves through a table's frames, within bounds", (expect) => {
                let a = render("osc(wave: table, table: basic, pos: 0)\nenv(a: 0, d: 0, s: 1, r: 0.01)\n", "inst(name: s); note(p: A3, len: 8)\n", 0.3);
                let b = render("osc(wave: table, table: basic, pos: 1)\nenv(a: 0, d: 0, s: 1, r: 0.01)\n", "inst(name: s); note(p: A3, len: 8)\n", 0.3);
                let sine = render(SINE, "inst(name: s); note(p: A3, len: 8)\n", 0.3);
                expect.that(finite(a) && finite(b)).is(true);
                expect.that(difference(a, sine) < 0.05).is(true); // frame 0 of basic is a sine
                expect.that(difference(a, b) > 0.1).is(true);
                expect.that(peak(b, 0, 0.05, 0.3) < 1.5).is(true);
                for (let k = 0; k < 4; k++) {
                    let name = ["basic", "harmonic", "formant", "pwm"][k];
                    let out = render(`osc(wave: table, table: ${name}, pos: 0.6)\n`, "inst(name: s); note(p: C6, len: 4)\n", 0.2);
                    expect.that(finite(out) && peak(out, 0, 0.02, 0.2) > 0.05).is(true);
                }
            });
            test("a sample's cycles as a table; unknown tables are reported", (expect) => {
                let cycles = new Float32Array(2048 * 2);
                for (let i = 0; i < cycles.length; i++) cycles[i] = <f32>(i < 2048 ? Math.sin(2 * Math.PI * <f64>i / 2048) : (i % 2048 < 1024 ? 0.5 : -0.5));
                let wav = new SongFile("samples/cyc.wav", encodeBase64(encodeWav(cycles, cycles.length, 1, 48000, FORMAT_FLOAT32, "", "")));
                let s = compile("osc(wave: table, table: cyc)\n", "inst(name: s); note(p: A3)\n", [wav]);
                expect.that(problems(s)).is("");
                let first = render("osc(wave: table, table: cyc, pos: 0)\nenv(a: 0, d: 0, s: 1, r: 0.01)\n", "inst(name: s); note(p: A3, len: 8)\n", 0.3, [wav]);
                let last = render("osc(wave: table, table: cyc, pos: 1)\nenv(a: 0, d: 0, s: 1, r: 0.01)\n", "inst(name: s); note(p: A3, len: 8)\n", 0.3, [wav]);
                expect.that(near(frequency(first, 0.05, 0.3), 220, 12)).is(true);
                expect.that(difference(first, last) > 0.1).is(true);
                expect.that(problems(compile("osc(wave: table, table: nope)\n", "")).length > 0).is(true);
            });
        });

        group("stereo", () => {
            test("width spreads unison voices across the sides", (expect) => {
                let inst = "osc(wave: saw, unison: 3, spread: 0.3)\nenv(a: 0, d: 0, s: 1, r: 0.01)\n";
                let narrow = render(inst, "inst(name: s); note(p: A3, len: 4)\n", 0.3);
                let wide = render(inst + "voice(width: 1)\n", "inst(name: s); note(p: A3, len: 4)\n", 0.3);
                expect.that(sideDifference(narrow) < 1e-6).is(true);
                expect.that(sideDifference(wide) > 0.05).is(true);
                expect.that(finite(wide)).is(true);
            });
            test("stereo samples keep their sides", (expect) => {
                let frames = 24000;
                let both = new Float32Array(frames * 2);
                for (let i = 0; i < frames; i++) both[i * 2] = <f32>(0.5 * Math.sin(2 * Math.PI * 220 * <f64>i / 48000));
                let bytes = encodeWav(both, frames, 2, 48000, FORMAT_FLOAT32, "", "");
                let d = decodeWav(bytes);
                expect.that(d.channels).is(2);
                expect.that(near(<f64>d.data[1000], <f64>d.left[1000] * 0.5, 1e-6)).is(true);
                let wav = new SongFile("samples/st.wav", encodeBase64(bytes));
                let out = render("sample(file: st, root: A3)\n", "inst(name: s); note(p: A3, len: 4)\n", 0.3, [wav]);
                expect.that(peak(out, 0, 0.05, 0.25) > 0.2).is(true);
                expect.that(peak(out, 1, 0.05, 0.25) < 0.01).is(true);
            });
        });

        test("sound design renders the same every time", (expect) => {
            let inst = "osc(wave: table, table: formant, unison: 4, spread: 0.2)\nvoice(width: 0.8)\nvlfo(n: 2, rate: 3, shape: random)\n" +
                "mod(src: lfo2, dst: pos, amt: 0.5)\nmod(src: random, dst: pan, amt: 0.4)\nmod(src: env2, dst: cutoff, amt: 2)\nfilter(type: lowpass, cutoff: 800)\n";
            let a = render(inst, "inst(name: s); chord(root: C4, type: min7, len: 8, bend: -2)\n", 0.6);
            let b = render(inst, "inst(name: s); chord(root: C4, type: min7, len: 8, bend: -2)\n", 0.6);
            expect.that(difference(a, b)).is(0);
            expect.that(finite(a) && peak(a, 0, 0.05, 0.5) > 0.01).is(true);
        });
    }
}
