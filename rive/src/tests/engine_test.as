import { Tests } from "rive/test";
import { Snapshot } from "rive/shared";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { packScore, PackedScore } from "../audio/pack";
import { renderScore, renderWav, RenderProgress, RenderSettings, WavSettings } from "../audio/render";
import { emptyBank } from "../synth/samples";
import { encodeWav, FORMAT_FLOAT32, FORMAT_PCM16, WavChunks, wavHeader } from "../audio/wav";
import { Engine } from "../synth/engine";
import { sinTurn } from "../synth/dsp";

const SR: f64 = 48000;

@editTime
function scoreOf(channels: Array<string>, extra: Array<SongFile> = [], conductor: string = "", loops: i32 = 0): Score {
    let yaml = "bpm: 120\nrows_per_beat: 4\nchannels:\n";
    let files = new Array<SongFile>();
    for (let i = 0; i < channels.length; i++) {
        yaml += `  - file: c${i}.ch\n`;
        files.push(new SongFile(`c${i}.ch`, channels[i]));
    }
    files.push(new SongFile("song.yaml", yaml));
    files.push(new SongFile("conductor.ch", conductor));
    for (let i = 0; i < extra.length; i++) files.push(extra[i]);
    let o = new CompileOptions();
    o.loops = loops;
    return compileSong(Song.fromFiles(files), o);
}

@editTime
function renderEngine(packed: PackedScore, seconds: f64, chunk: i32): Float32Array {
    let engine = new Engine(SR, 2);
    engine.load(packed.events, packed.instruments, 0);
    engine.play();
    let frames = <i32>(seconds * SR);
    let out = new Float32Array(frames * 2);
    let done = 0;
    let k = 0;
    while (done < frames) {
        // Vary the call size the way a host does.
        let n = min<i32>(chunk > 0 ? chunk : 1 + ((k * 7919) % 777), frames - done);
        engine.renderStereo(out, done, n);
        done += n;
        k++;
    }
    return out;
}

@editTime
function peak(buf: Float32Array, from: i32, to: i32): f64 {
    let p = 0.0;
    for (let i = from; i < to; i++) p = Math.max(p, Math.abs(<f64>buf[i]));
    return p;
}

@editTime
function finite(buf: Float32Array): bool {
    for (let i = 0; i < buf.length; i++) if (!isFinite(<f64>buf[i])) return false;
    return true;
}

@editTime
function same(a: Float32Array, b: Float32Array): bool {
    if (a.length != b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] != b[i]) return false;
    return true;
}

// Rising zero crossings of the left channel per second.
@editTime
function frequency(buf: Float32Array, from: i32, to: i32): f64 {
    let count = 0;
    for (let i = from + 1; i < to; i++) {
        if (buf[(i - 1) * 2] < 0 && buf[i * 2] >= 0) count++;
    }
    return <f64>count / (<f64>(to - from) / SR);
}

export class EngineTests extends Tests {
    override run(): void {
        group("dsp", () => {
            test("sinTurn matches Math.sin", (expect) => {
                let worst = 0.0;
                for (let i = 0; i < 1000; i++) {
                    let x = <f64>i / 333.3 - 1.5;
                    worst = Math.max(worst, Math.abs(sinTurn(x) - Math.sin(x * 6.283185307179586)));
                }
                expect.that(worst < 1e-5).is(true);
            });
        });

        group("engine", () => {
            test("a sine note sounds at its pitch, after silence, and ends", (expect) => {
                let s = scoreOf(["\n\n\n\ninst(name: sine); note(p: A4, len: 1b)\n"]);
                let out = renderEngine(packScore(s), 2, 512);
                let start = <i32>(0.5 * SR);
                expect.that(peak(out, 0, start * 2 - 2)).is(0);
                expect.that(peak(out, (start + 2400) * 2, (start + 12000) * 2) > 0.1).is(true);
                let f = frequency(out, start + 2400, start + 12000);
                expect.that(Math.abs(f - 440) < 8).is(true);
                expect.that(peak(out, (<i32>(1.6 * SR)) * 2, out.length)).lessThan(1e-4);
            });
            test("transposed notes double in frequency per octave", (expect) => {
                let s = scoreOf(["inst(name: sine); note(p: A5, len: 1b)\n"]);
                let out = renderEngine(packScore(s), 0.4, 0);
                expect.that(Math.abs(frequency(out, 2400, 19200) - 880) < 12).is(true);
            });
            test("output does not depend on the host block size", (expect) => {
                let s = scoreOf([
                    "inst(name: stab); chord(root: A3, type: min9, len: 2b); set(delay: 0.3, reverb: 0.3)\n\nramp(cutoff: 3k, over: 1bar)\n",
                    "inst(name: kick); note(p: C1)\n\n\n\nnote(p: C1)\n\n\n\ninst(name: hat_open); note(p: C4)\n",
                ]);
                let packed = packScore(s);
                let a = renderEngine(packed, 2, 128);
                let b = renderEngine(packed, 2, 0);
                let c = renderEngine(packed, 2, 1);
                expect.that(same(a, b)).is(true);
                expect.that(same(a, c)).is(true);
                expect.that(finite(a)).is(true);
                expect.that(peak(a, 0, a.length) > 0.05).is(true);
                expect.that(peak(a, 0, a.length) <= 0.9661).is(true);
            });
            test("muted and soloed channels", (expect) => {
                let s = scoreOf(["inst(name: sine); note(p: C4, len: 4)\n", "inst(name: saw); note(p: C5, len: 4)\n"]);
                let packed = packScore(s);
                let engine = new Engine(SR, 2);
                engine.load(packed.events, packed.instruments, 0);
                engine.muteMask = 3;
                engine.play();
                let out = new Float32Array(9600 * 2);
                engine.renderStereo(out, 0, 9600);
                expect.that(peak(out, 0, out.length)).is(0);
                let solo = new Engine(SR, 2);
                solo.load(packed.events, packed.instruments, 0);
                solo.soloMask = 1;
                solo.play();
                solo.renderStereo(out, 0, 9600);
                expect.that(Math.abs(frequency(out, 2400, 9600) - 261.6) < 15).is(true);
            });
            test("seeking applies earlier state without its notes", (expect) => {
                let s = scoreOf(["inst(name: sine); vol(v: 0)\nnote(p: C4, len: 8)\n\n\n\n\n\n\nnote(p: C5)\n"]);
                let packed = packScore(s);
                let engine = new Engine(SR, 2);
                engine.load(packed.events, packed.instruments, 0.5);
                engine.play();
                let out = new Float32Array(48000 * 2);
                engine.renderStereo(out, 0, 48000);
                // vol 0 still applies after the seek, so the later note is silent too.
                expect.that(peak(out, 0, out.length)).is(0);
                // The song ends with its last note, at 1.125 s, and time stops there.
                expect.that(Math.abs(engine.time - 1.125) < 0.001).is(true);
                expect.that(engine.ended).is(true);
            });
            test("seeking into a held note starts it, a live swap does not", (expect) => {
                let s = scoreOf(["inst(name: organ); note(p: A4, len: 4bar)\n"]);
                let packed = packScore(s);
                let engine = new Engine(SR, 2);
                engine.load(packed.events, packed.instruments, 3.0);
                engine.play();
                let out = new Float32Array(9600 * 2);
                engine.renderStereo(out, 0, 9600);
                expect.that(peak(out, 2400 * 2, out.length) > 0.1).is(true);
                let quiet = new Engine(SR, 2);
                quiet.load(packed.events, packed.instruments, 3.0, false);
                quiet.play();
                quiet.renderStereo(out, 0, 9600);
                expect.that(peak(out, 0, out.length)).is(0);
            });
            test("loops jump back and keep playing", (expect) => {
                let s = scoreOf(["inst(name: sine); note(p: A4, len: 1)\n\n\n\n"], [], "mark(name: a)\n\n\n\njump(to: a)\n", 0);
                let packed = packScore(s);
                expect.that(packed.loopEnd > 0).is(true);
                let engine = new Engine(SR, 2);
                engine.load(packed.events, packed.instruments, 0);
                engine.loopStart = packed.loopStart;
                engine.loopEnd = packed.loopEnd;
                engine.play();
                let out = new Float32Array(<i32>(SR * 2) * 2);
                engine.renderStereo(out, 0, <i32>(SR * 2));
                // A note at the start of every 0.625 s pass, the third one included.
                let third = <i32>(1.25 * SR);
                expect.that(peak(out, (third + 480) * 2, (third + 4000) * 2) > 0.1).is(true);
                expect.that(engine.playing).is(true);
            });
            test("stopAt ends an audition", (expect) => {
                let s = scoreOf(["inst(name: organ); note(p: C4, len: 8)\n"]);
                let packed = packScore(s);
                let engine = new Engine(SR, 2);
                engine.load(packed.events, packed.instruments, 0);
                engine.stopAt = 0.125;
                engine.play();
                let out = new Float32Array(<i32>SR * 2);
                engine.renderStereo(out, 0, <i32>SR);
                expect.that(engine.playing).is(false);
                expect.that(peak(out, <i32>(0.5 * SR) * 2, out.length)).lessThan(1e-4);
            });
            test("every preset renders finite, bounded sound", (expect) => {
                let names = ["sine", "tri", "saw", "square", "pulse", "noise", "sub_bass", "deep_bass", "organ_bass", "acid_bass", "stab", "pluck", "epiano", "organ", "bell", "pad", "strings", "supersaw", "lead", "kick", "kick_deep", "snare", "clap", "rim", "hat_closed", "hat_open", "shaker", "tom"];
                let text = "";
                for (let i = 0; i < names.length; i++) text += `inst(name: ${names[i]}); note(p: C3, len: 2)\n\n\n\n`;
                let s = scoreOf([text]);
                expect.that(s.diagnostics.length).is(0);
                let out = renderEngine(packScore(s), s.duration + 2, 0);
                expect.that(finite(out)).is(true);
                let quiet = "";
                for (let i = 0; i < names.length; i++) {
                    let from = <i32>(<f64>i * 0.5 * SR);
                    let p = peak(out, from * 2, (from + <i32>(0.4 * SR)) * 2);
                    if (p < 0.02) quiet += `${names[i]}(${p}) `;
                }
                expect.that(quiet).is("");
            });
        });

        group("render", () => {
            test("the render job matches the engine sample for sample", (expect) => {
                let s = scoreOf(["inst(name: pluck); note(p: C4)\nnote(p: E4); set(delay: 0.4)\nnote(p: G4)\n"]);
                let packed = packScore(s);
                let settings = new RenderSettings();
                settings.duration = s.duration;
                settings.maxTail = 1;
                let progress = Snapshot.create<RenderProgress>();
                let blob = renderScore(packed.events, packed.instruments, emptyBank(), settings, progress);
                let frames = <i32>(blob.byteLength / 8);
                let rendered = new Float32Array(frames * 2);
                blob.readInto(0, rendered, 0, frames * 2);
                let direct = renderEngine(packed, <f64>frames / SR, 333);
                expect.that(same(rendered, direct)).is(true);
                let last = progress.latest();
                expect.that(last != null && last.value.done == 1).is(true);
                expect.that(<f64>frames / SR).greaterThan(s.duration);
            });
            test("wav header and chunks", (expect) => {
                let h = wavHeader(1000, 2, 48000, FORMAT_PCM16, "Song", "Me");
                let v = new DataView(h);
                expect.that(v.getUint32(0, false)).is(0x52494646);
                expect.that(v.getUint16(20, true)).is(1);
                expect.that(v.getUint32(24, true)).is(48000);
                expect.that(v.getUint32(4, true)).is(<u32>(h.byteLength - 8 + 4000));
                expect.that(v.getUint32(h.byteLength - 4, true)).is(4000);

                let s = scoreOf(["inst(name: saw); note(p: C4, len: 1bar)\n"]);
                let packed = packScore(s);
                let settings = new RenderSettings();
                settings.duration = s.duration;
                settings.maxTail = 0.5;
                let wav = new WavSettings();
                wav.title = "Song";
                let file = renderWav(packed.events, packed.instruments, emptyBank(), settings, wav, Snapshot.create<RenderProgress>());
                let samples = renderScore(packed.events, packed.instruments, emptyBank(), settings, Snapshot.create<RenderProgress>());
                let frames = <i32>(samples.byteLength / 8);
                let header = wavHeader(frames, 2, 48000, FORMAT_PCM16, "Song", "");
                expect.that(<i32>file.byteLength).is(header.byteLength + frames * 4);
                let chunks = new WavChunks(file, 65536);
                let total = 0;
                let count = 0;
                while (true) {
                    let c = chunks.nextChunk();
                    if (c == null) break;
                    expect.that(c.byteLength <= 65536).is(true);
                    total += c.byteLength;
                    count++;
                }
                expect.that(total).is(<i32>file.byteLength);
                expect.that(count).is(chunks.chunkCount);
                let f32 = new Float32Array(16);
                let encoded = encodeWav(f32, 8, 2, 48000, FORMAT_FLOAT32, "", "");
                expect.that(encoded.length).is(wavHeader(8, 2, 48000, FORMAT_FLOAT32, "", "").byteLength + 64);

            });
        });
    }
}
