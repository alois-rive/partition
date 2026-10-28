import { Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { EventKind } from "../score/events";
import { packScore } from "../audio/pack";
import { Engine } from "../synth/engine";
import { Loudness } from "../synth/mixer";

const SR: f64 = 48000;

// A song: `tracks` are channel texts (c0.ch …), `buses` "name=text" bus files,
// `routes` the bus of each track ("" for the master).
@editTime
function song(tracks: Array<string>, routes: Array<string> = [], buses: Array<string> = [], conductor: string = "", extra: Array<SongFile> = []): Song {
    let yaml = "bpm: 120\nrows_per_beat: 4\nchannels:\n";
    let files = new Array<SongFile>();
    for (let i = 0; i < tracks.length; i++) {
        yaml += `  - name: t${i}\n    file: c${i}.ch\n`;
        if (i < routes.length && routes[i].length > 0) yaml += `    bus: ${routes[i]}\n`;
        files.push(new SongFile(`c${i}.ch`, tracks[i]));
    }
    if (buses.length > 0) yaml += "buses:\n";
    for (let i = 0; i < buses.length; i++) {
        let eq = buses[i].indexOf("=");
        let name = buses[i].substring(0, eq);
        yaml += `  - name: ${name}\n    file: buses/${name}.ch\n`;
        files.push(new SongFile(`buses/${name}.ch`, buses[i].substring(eq + 1)));
    }
    files.push(new SongFile("song.yaml", yaml));
    files.push(new SongFile("conductor.ch", conductor));
    for (let i = 0; i < extra.length; i++) files.push(extra[i]);
    return Song.fromFiles(files);
}

@editTime
function errorText(s: Song, score: Score? = null): string {
    let all = score != null ? score.diagnostics : s.diagnostics();
    let out = new Array<string>();
    for (let i = 0; i < all.length; i++) if (all[i].isError) out.push(all[i].message);
    return out.join("; ");
}

@editTime
function render(s: Song, seconds: f64): Float32Array {
    let score = compileSong(s, new CompileOptions());
    let packed = packScore(score);
    let engine = new Engine(SR, 2);
    engine.load(packed.events, packed.instruments, 0);
    engine.play();
    let frames = <i32>(seconds * SR);
    let out = new Float32Array(frames * 2);
    let done = 0;
    while (done < frames) {
        let n = min<i32>(500, frames - done);
        engine.renderStereo(out, done, n);
        done += n;
    }
    return out;
}

@editTime
function rms(buf: Float32Array, from: f64, to: f64): f64 {
    let a = <i32>(from * SR);
    let b = <i32>(to * SR);
    let sum = 0.0;
    for (let i = a; i < b; i++) sum += <f64>buf[i * 2] * <f64>buf[i * 2];
    return Math.sqrt(sum / <f64>max<i32>(b - a, 1));
}

// A held sine tone on a track.
const TONE_LOW: string = "inst(name: sine); note(p: B1, len: 64)\n"; // ~62 Hz
const TONE_HIGH: string = "inst(name: sine); note(p: C7, len: 64)\n"; // ~2.1 kHz

export class MixerTests extends Tests {
    override run(): void {
        group("mixer language", () => {
            test("fx takes its type's arguments, once per file", (expect) => {
                let ok = song(["fx(type: comp, threshold: -18dB, ratio: 6, sidechain: t1); fx(type: eq, low: -3dB)\n", "note(p: C1)\n"]);
                expect.that(errorText(ok)).is("");
                let bad = song(["fx(type: comp, cutoff: 1k)\n"]);
                expect.that(errorText(bad).includes("has no argument 'cutoff'")).is(true);
                let twice = song(["fx(type: eq)\n\nfx(type: eq)\n"]);
                expect.that(errorText(twice).includes("already has a eq")).is(true);
                let pattern = song(["pattern(name: p)\n"], [], [], "", [new SongFile("patterns/p.pat", "fx(type: eq)\n")]);
                expect.that(errorText(pattern).includes("effects belong to tracks")).is(true);
            });
            test("buses play no notes; tracks send to them by name", (expect) => {
                let s = song(["set(send.space: 0.4)\n", "set(send.nope: 1)\n"], ["drums"], ["drums=fx(type: comp)\nvol(v: 0.7)\n", "space=note(p: C4)\n"]);
                let e = errorText(s);
                expect.that(e.includes("unknown parameter 'send.nope'")).is(true);
                expect.that(e.includes("plays notes, which a bus does not")).is(true);
                let unknown = song(["note(p: C4)\n"], ["nowhere"]);
                expect.that(errorText(unknown).includes("plays into bus 'nowhere'")).is(true);
            });
            test("effects compile to chain, route and parameter events", (expect) => {
                let s = song(["fx(type: filter, mode: highpass); ramp(filter.cutoff: 2k, over: 1bar)\n", "note(p: C1)\n"], ["", "b"], ["b=fx(type: comp, sidechain: t0)\n"],
                    "fx(type: eq, high: 3dB)\nset(eq.low: -2dB)\n");
                let score = compileSong(s, new CompileOptions());
                expect.that(errorText(s, score)).is("");
                let fx = 0;
                let routes = 0;
                let keyed = false;
                let master = 0;
                for (let i = 0; i < score.events.length; i++) {
                    let e = score.events[i];
                    if (e.kind == EventKind.Fx) {
                        fx++;
                        if (e.inst == 2 && e.param == 0) keyed = true;
                        if (e.channel == -1) master++;
                    }
                    if (e.kind == EventKind.Route && e.channel == 1 && e.value == 0) routes++;
                }
                expect.that(fx).is(3);
                expect.that(routes).is(1);
                expect.that(keyed).is(true);
                expect.that(master).is(1);
            });
        });

        group("mixer sound", () => {
            test("an EQ cut and a high-pass filter take the lows out", (expect) => {
                let dry = rms(render(song([TONE_LOW]), 0.6), 0.3, 0.6);
                let eq = rms(render(song(["fx(type: eq, low: -24dB, low_freq: 200)\n" + TONE_LOW]), 0.6), 0.3, 0.6);
                let hp = rms(render(song(["fx(type: filter, mode: highpass, cutoff: 1k)\n" + TONE_LOW]), 0.6), 0.3, 0.6);
                let high = rms(render(song(["fx(type: eq, low: -24dB, low_freq: 200)\n" + TONE_HIGH]), 0.6), 0.3, 0.6);
                let highDry = rms(render(song([TONE_HIGH]), 0.6), 0.3, 0.6);
                expect.that(eq < dry * 0.15).is(true);
                expect.that(hp < dry * 0.05).is(true);
                expect.that(Math.abs(high / highDry - 1) < 0.1).is(true);
            });
            test("a compressor keyed by the kick ducks the pad after each hit", (expect) => {
                let kick = "inst(name: kick); note(p: C1)\n\n\n\n\n\n\n\nnote(p: C1)\n";
                let pad = "fx(type: comp, threshold: -30dB, ratio: 10, attack: 1ms, release: 150ms, sidechain: t0)\ninst(name: sine); note(p: C5, len: 64)\n";
                let ducked = render(song([kick, pad]), 1.2);
                let alone = render(song(["", pad]), 1.2);
                // Right after the second hit (1 s) against the same moment unkeyed: the pad's
                // part of the output drops; long after the first hit it recovers.
                let pumpDip = rms(ducked, 1.02, 1.06) - rms(render(song([kick, ""]), 1.2), 1.02, 1.06);
                expect.that(pumpDip < rms(alone, 1.02, 1.06) * 0.5).is(true);
                expect.that(Math.abs(rms(ducked, 0.85, 0.95) - rms(alone, 0.85, 0.95)) < rms(alone, 0.85, 0.95) * 0.2).is(true);
            });
            test("tracks play into buses, with the bus's volume and effects", (expect) => {
                let open = rms(render(song([TONE_HIGH], ["g"], ["g=vol(v: 1)\n"]), 0.5), 0.2, 0.5);
                let shut = rms(render(song([TONE_HIGH], ["g"], ["g=vol(v: 0)\n"]), 0.5), 0.2, 0.5);
                let filtered = rms(render(song([TONE_HIGH], ["g"], ["g=fx(type: filter, cutoff: 200)\n"]), 0.5), 0.2, 0.5);
                expect.that(open > 0.05).is(true);
                expect.that(shut).is(0);
                expect.that(filtered < open * 0.1).is(true);
            });
            test("a send feeds a bus as well as the master", (expect) => {
                // Quiet enough that the doubled level stays under the master limiter.
                let quiet = "inst(name: sine); note(p: C7, len: 64, vel: 0.2)\n";
                let dry = rms(render(song([quiet], [], ["s=vol(v: 1)\n"]), 0.5), 0.2, 0.5);
                let sent = rms(render(song(["set(send.s: 1)\n" + quiet], [], ["s=vol(v: 1)\n"]), 0.5), 0.2, 0.5);
                expect.that(Math.abs(sent / dry - 2) < 0.1).is(true);
            });
            test("the master chain filters the whole song, and its parameters ramp", (expect) => {
                let dry = rms(render(song([TONE_HIGH]), 1.2), 0.2, 0.4);
                let master = render(song([TONE_HIGH], [], [], "fx(type: filter, cutoff: 200)\nramp(filter.cutoff: 20k, over: 1bar)\n"), 2.4);
                expect.that(rms(master, 0.02, 0.06) < dry * 0.2).is(true);
                expect.that(rms(master, 2.1, 2.3) > dry * 0.8).is(true);
            });
            test("every effect at once on 16 tracks stays bounded and repeatable", (expect) => {
                let tracks = new Array<string>();
                for (let i = 0; i < 16; i++) {
                    tracks.push(`fx(type: eq, high: 2dB); fx(type: comp); fx(type: dist, drive: 0.3); fx(type: chorus); fx(type: phaser); fx(type: filter, cutoff: 6k)\nlfo(param: filter.cutoff, rate: 2Hz, depth: 1)\ninst(name: saw); note(p: [C3, G3], len: 16)\n`);
                }
                let a = render(song(tracks), 1);
                let b = render(song(tracks), 1);
                let same = true;
                let peak = 0.0;
                for (let i = 0; i < a.length; i++) {
                    if (a[i] != b[i]) same = false;
                    peak = Math.max(peak, Math.abs(<f64>a[i]));
                }
                expect.that(same).is(true);
                expect.that(peak > 0.05 && peak <= 1).is(true);
            });
        });

        group("loudness", () => {
            test("a 1 kHz tone at -20 dBFS on both sides reads about -20 LUFS", (expect) => {
                let meter = new Loudness(SR);
                let n = <i32>(4 * SR);
                for (let i = 0; i < n; i++) {
                    let x = 0.1 * Math.sin(2 * Math.PI * 1000 * <f64>i / SR);
                    meter.add(x, x);
                }
                expect.that(Math.abs(meter.shortTerm + 20) < 0.5).is(true);
                expect.that(Math.abs(meter.integrated + 20) < 0.5).is(true);
                // Silence under the absolute gate leaves the integrated value alone.
                for (let i = 0; i < n; i++) meter.add(0, 0);
                expect.that(Math.abs(meter.integrated + 20) < 0.5).is(true);
                expect.that(meter.shortTerm < -70).is(true);
            });
        });
    }
}
