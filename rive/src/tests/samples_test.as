import { Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { packScore } from "../audio/pack";
import { encodeWav, FORMAT_FLOAT32, FORMAT_PCM16 } from "../audio/wav";
import { Engine } from "../synth/engine";
import { BANK_HEADER, BANK_RECORD, buildBank, decodeBase64, decodeWav, encodeBase64 } from "../synth/samples";

const SR: f64 = 48000;

// A WAV file of `data` (mono), as the base64 text a song carries.
@editTime
function wavText(data: Float32Array, rate: i32, format: i32 = FORMAT_FLOAT32): string {
    return encodeBase64(encodeWav(data, data.length, 1, rate, format, "", ""));
}

@editTime
function sine(hz: f64, seconds: f64, rate: i32): Float32Array {
    let n = <i32>(seconds * <f64>rate);
    let out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = <f32>(0.5 * Math.sin(2 * Math.PI * hz * <f64>i / <f64>rate));
    return out;
}

// Four equal steps of 0.1, 0.2, 0.3 and 0.4: one level per slice.
@editTime
function steps(frames: i32): Float32Array {
    let out = new Float32Array(frames * 4);
    for (let i = 0; i < out.length; i++) out[i] = <f32>(0.1 * <f64>(i / frames + 1));
    return out;
}

class Rendered {
    constructor(public score: Score, public out: Float32Array) {}
}

// Renders a one-channel song whose instrument `s` is `inst`, with `samples` as samples/<name>.wav.
@editTime
function render(inst: string, channel: string, names: Array<string>, texts: Array<string>, seconds: f64): Rendered {
    let files = [
        new SongFile("song.yaml", "bpm: 120\nrows_per_beat: 4\nchannels:\n  - file: c.ch\n"),
        new SongFile("conductor.ch", ""),
        new SongFile("c.ch", channel),
        new SongFile("instruments/s.inst", inst),
    ];
    for (let i = 0; i < names.length; i++) files.push(new SongFile(`samples/${names[i]}.wav`, texts[i]));
    let song = Song.fromFiles(files);
    let score = compileSong(song, new CompileOptions());
    let bank = buildBank(song.sampleTexts()).bank!;
    let packed = packScore(score);
    let engine = new Engine(SR, 2);
    engine.attachSamples(bank);
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
    return new Rendered(score, out);
}

@editTime
function frequency(buf: Float32Array, from: i32, to: i32): f64 {
    let count = 0;
    for (let i = from + 1; i < to; i++) if (buf[(i - 1) * 2] < 0 && buf[i * 2] >= 0) count++;
    return <f64>count / (<f64>(to - from) / SR);
}

@editTime
function mean(buf: Float32Array, from: i32, to: i32): f64 {
    let sum = 0.0;
    for (let i = from; i < to; i++) sum += <f64>buf[i * 2];
    return sum / <f64>(to - from);
}

@editTime
function peak(buf: Float32Array, from: i32, to: i32): f64 {
    let p = 0.0;
    for (let i = from; i < to; i++) p = Math.max(p, Math.abs(<f64>buf[i * 2]));
    return p;
}

@editTime
function errorsOf(score: Score): string {
    let out = new Array<string>();
    for (let i = 0; i < score.diagnostics.length; i++) if (score.diagnostics[i].isError) out.push(score.diagnostics[i].message);
    return out.join("; ");
}

export class SampleTests extends Tests {
    override run(): void {
        group("sample files", () => {
            test("base64 round trips, whitespace and all", (expect) => {
                let bytes = new Uint8Array(5);
                for (let i = 0; i < 5; i++) bytes[i] = <u8>(i * 61);
                let text = encodeBase64(bytes);
                expect.that(text).is("AD16t/Q=\n");
                let back = decodeBase64("AD16\n t/Q=")!;
                expect.that(back.length).is(5);
                expect.that(back[4]).is(244);
                expect.that(decodeBase64("AD!6") == null).is(true);
            });
            test("WAV files decode to mono at their own rate", (expect) => {
                let stereo = new Float32Array(4);
                stereo[0] = 0.5;
                stereo[1] = -0.5; // frame 0 sums to 0
                stereo[2] = 0.25;
                stereo[3] = 0.25; // frame 1 averages to 0.25
                let s = decodeWav(encodeWav(stereo, 2, 2, 22050, FORMAT_PCM16, "", ""));
                expect.that(s.error).is("");
                expect.that(s.rate).is(22050);
                expect.that(s.frames).is(2);
                expect.that(Math.abs(<f64>s.data[0]) < 1e-4).is(true);
                expect.that(Math.abs(<f64>s.data[1] - 0.25) < 1e-3).is(true);
                expect.that(decodeWav(new Uint8Array(20)).error.length > 0).is(true);
            });
            test("the bank packs samples end to end and reports bad ones", (expect) => {
                let r = buildBank([wavText(sine(100, 0.01, 48000), 48000), "not base64!", wavText(steps(10), 8000)]);
                expect.that(r.errors[0]).is("");
                expect.that(r.errors[1].length > 0).is(true);
                expect.that(r.errors[2]).is("");
                let bank = new Float32Array(<i32>(r.bank!.byteLength / 4));
                r.bank!.readInto(0, bank);
                expect.that(<i32>bank[0]).is(3);
                expect.that(<i32>bank[1 + 2 * BANK_RECORD]).is(480); // the third starts after the first (and the empty second)
                expect.that(<i32>bank[1 + 2 * BANK_RECORD + 1]).is(40);
                expect.that(bank.length).is(BANK_HEADER + 520);
            });
        });

        group("sampler", () => {
            test("a sample plays at its root and follows the notes", (expect) => {
                // A 440 Hz tone recorded at 44.1 kHz, rooted at A4, played an octave up.
                let r = render("sample(file: tone, root: A4)\n", "inst(name: s); note(p: A5, len: 8)\n", ["tone"], [wavText(sine(440, 1, 44100), 44100)], 0.6);
                expect.that(errorsOf(r.score)).is("");
                let hz = frequency(r.out, 4800, 24000);
                expect.that(Math.abs(hz - 880) < 6).is(true);
            });
            test("slices keep their pitch, one per note from the root", (expect) => {
                let text = wavText(steps(4800), 48000);
                let a = render("sample(file: st, root: C3, slices: 4)\n", "inst(name: s); note(p: D3, len: 8)\n", ["st"], [text], 0.08);
                let b = render("sample(file: st, root: C3, slices: 4)\n", "inst(name: s); note(p: C#3, len: 8)\n", ["st"], [text], 0.08);
                // D3 is the third slice (0.3), C#3 the second (0.2).
                let ratio = mean(a.out, 960, 3800) / mean(b.out, 960, 3800);
                expect.that(Math.abs(ratio - 1.5) < 0.02).is(true);
                // Notes past the slices play nothing.
                let none = render("sample(file: st, root: C3, slices: 4)\n", "inst(name: s); note(p: C4, len: 8)\n", ["st"], [text], 0.08);
                expect.that(peak(none.out, 0, 3840)).is(0);
            });
            test("one-shots play to their end; others stop with the note", (expect) => {
                let text = wavText(sine(200, 0.5, 48000), 48000);
                // A row lasts 0.125 s: the note is released long before the sample ends.
                let held = render("sample(file: t)\n", "inst(name: s); note(p: C4, len: 1)\n", ["t"], [text], 0.45);
                let shot = render("sample(file: t, oneshot: true)\n", "inst(name: s); note(p: C4, len: 1)\n", ["t"], [text], 0.45);
                expect.that(peak(held.out, 19200, 20000) < 1e-4).is(true);
                expect.that(peak(shot.out, 19200, 20000) > 0.05).is(true);
            });
            test("reverse plays from the end", (expect) => {
                let text = wavText(steps(2400), 48000);
                let r = render("sample(file: st, reverse: true)\n", "inst(name: s); note(p: C4, len: 16)\n", ["st"], [text], 0.2);
                // The last step (0.4) comes first, the first (0.1) last.
                expect.that(mean(r.out, 200, 2200) > 2.5 * mean(r.out, 7400, 9300)).is(true);
            });
            test("a loop keeps the sample going while the note is held", (expect) => {
                let text = wavText(sine(300, 0.2, 48000), 48000);
                let r = render("sample(file: t, loop: true, loop_start: 50ms, loop_end: 150ms)\n", "inst(name: s); note(p: C4, len: 8)\n", ["t"], [text], 0.9);
                expect.that(peak(r.out, 38000, 43000) > 0.05).is(true); // 0.8 s, four times the sample's length
            });
            test("zones split the keyboard; a choke group cuts its other notes", (expect) => {
                let low = wavText(sine(100, 1, 48000), 48000);
                let high = wavText(sine(1000, 1, 48000), 48000);
                let inst = "sample(file: lo, root: C4, hi: B4, choke: 1)\nsample(file: hi, root: C5, lo: C5, choke: 1)\n";
                // C4 plays the low file; C5 the high one, which cuts the low one.
                let r = render(inst, "inst(name: s); note(p: C4, len: 16)\n\n\n\nnote(p: C5, len: 16)\n", ["hi", "lo"], [high, low], 1.0);
                expect.that(Math.abs(frequency(r.out, 2400, 21000) - 100) < 4).is(true);
                expect.that(Math.abs(frequency(r.out, 28000, 46000) - 1000) < 8).is(true);
            });
            test("an unknown sample is reported where it is named", (expect) => {
                let r = render("sample(file: nope)\n", "inst(name: s); note(p: C4)\n", [], [], 0.01);
                expect.that(errorsOf(r.score).includes("no sample 'nope'")).is(true);
            });
            test("real-time and offline renders of samples match", (expect) => {
                let text = wavText(sine(330, 0.3, 32000), 32000);
                let a = render("sample(file: t, tune: 7st)\nfilter(type: lowpass, cutoff: 3k)\n", "inst(name: s); note(p: [C4, E4], len: 2)\n\n\n\nnote(p: G3, len: 4)\n", ["t"], [text], 0.8);
                let b = render("sample(file: t, tune: 7st)\nfilter(type: lowpass, cutoff: 3k)\n", "inst(name: s); note(p: [C4, E4], len: 2)\n\n\n\nnote(p: G3, len: 4)\n", ["t"], [text], 0.8);
                let same = a.out.length == b.out.length;
                for (let i = 0; same && i < a.out.length; i++) same = a.out[i] == b.out[i];
                expect.that(same).is(true);
                expect.that(peak(a.out, 0, a.out.length / 2) > 0.05).is(true);
            });
        });
    }
}
