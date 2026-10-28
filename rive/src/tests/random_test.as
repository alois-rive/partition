import { Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { parseSongConfig, songConfigText } from "../lang/config";
import { compileSong, CompileOptions, euclidHit, Score } from "../score/compiler";
import { EventKind } from "../score/events";
import { packScore } from "../audio/pack";
import { Engine } from "../synth/engine";

// 120 bpm, 4 rows per beat: a row is 0.125 s.
@editTime
function compile(channel: string, seed: i32 = 1, patterns: Array<string> = [], conductor: string = ""): Score {
    let files = [
        new SongFile("song.yaml", `bpm: 120\nrows_per_beat: 4\nseed: ${seed}\nchannels:\n  - file: a.ch\n`),
        new SongFile("conductor.ch", conductor),
        new SongFile("a.ch", channel),
    ];
    for (let i = 0; i < patterns.length; i++) {
        let eq = patterns[i].indexOf("=");
        files.push(new SongFile(`patterns/${patterns[i].substring(0, eq)}.pat`, patterns[i].substring(eq + 1)));
    }
    return compileSong(Song.fromFiles(files), new CompileOptions());
}

@editTime
function ons(score: Score): Array<f64> {
    let out = new Array<f64>();
    for (let i = 0; i < score.events.length; i++) if (score.events[i].kind == EventKind.NoteOn) out.push(score.events[i].time);
    return out;
}

@editTime
function describe(score: Score): string {
    let out = new Array<string>();
    for (let i = 0; i < score.events.length; i++) {
        let e = score.events[i];
        if (e.kind == EventKind.NoteOn) out.push(`${e.time}:${e.pitch}:${e.vel}`);
    }
    return out.join(" ");
}

@editTime
function problems(score: Score): string {
    let out = new Array<string>();
    for (let i = 0; i < score.diagnostics.length; i++) if (score.diagnostics[i].isError) out.push(score.diagnostics[i].message);
    return out.join("; ");
}

@editTime
function render(score: Score, seconds: f64): Float32Array {
    let packed = packScore(score);
    let engine = new Engine(48000, 2);
    engine.load(packed.events, packed.instruments, 0);
    engine.play();
    let out = new Float32Array(<i32>(seconds * 48000) * 2);
    engine.renderStereo(out, 0, out.length / 2);
    return out;
}

export class RandomTests extends Tests {
    override run(): void {
        group("euclid", () => {
            test("hits spread over steps, rotated", (expect) => {
                let row = "";
                for (let i = 0; i < 8; i++) row += euclidHit(i, 3, 8, 0) ? "x" : ".";
                expect.that(row).is("x..x..x.");
                let rotated = "";
                for (let i = 0; i < 8; i++) rotated += euclidHit(i, 3, 8, 1) ? "x" : ".";
                expect.that(rotated).is(".x..x..x");
                let five = 0;
                for (let i = 0; i < 16; i++) if (euclidHit(i, 5, 16, 3)) five++;
                expect.that(five).is(5);
            });
            test("euclid plays its hits, step by step, times over", (expect) => {
                let s = compile("euclid(hits: 3, steps: 8, p: C4, times: 2)\n");
                expect.that(problems(s)).is("");
                let t = ons(s);
                expect.that(t.length).is(6);
                expect.that(t[1]).is(0.375);
                expect.that(t[3]).is(1.0);
                let half = compile("euclid(hits: 4, steps: 4, d: 1, every: 1/8)\n");
                expect.that(ons(half)[1]).is(0.25);
                expect.that(problems(compile("euclid(hits: 3, steps: 8)\n")).includes("needs 'p'")).is(true);
            });
        });

        group("chance", () => {
            test("prob plays a share of the time", (expect) => {
                let p = "one=note(p: C4, prob: 0.5)\n";
                let n = ons(compile("pattern(name: one, times: 400)\n", 1, [p])).length;
                expect.that(n > 150 && n < 250).is(true);
                expect.that(ons(compile("pattern(name: one, times: 50)\n", 1, ["one=note(p: C4, prob: 0)\n"])).length).is(0);
                expect.that(ons(compile("pattern(name: one, times: 50)\n", 1, ["one=note(p: C4, prob: 100%)\n"])).length).is(50);
                let hits = ons(compile("euclid(hits: 16, steps: 16, p: C4, times: 25, prob: 0.25)\n")).length;
                expect.that(hits > 60 && hits < 140).is(true);
            });
            test("the same seed plays the same song; another seed another", (expect) => {
                let song = "humanize(time: 20ms, vel: 0.2)\nnote(p: [C4, E4, G4, B4], pick: 2, prob: 0.7)\n\nnote(p: C4, prob: 0.5)\n";
                let looped = "mark(name: a)\n\n\njump(to: a, times: 8)\n";
                let a = compile(song, 7, [], looped);
                let b = compile(song, 7, [], looped);
                let c = compile(song, 8, [], looped);
                expect.that(describe(a)).is(describe(b));
                expect.that(describe(a) != describe(c)).is(true);
                let ra = render(a, 1);
                let rb = render(b, 1);
                let same = true;
                for (let i = 0; i < ra.length; i++) if (ra[i] != rb[i]) same = false;
                expect.that(same).is(true);
            });
            test("every pass of a loop draws again", (expect) => {
                let s = compile("note(p: [C4, D4, E4, F4, G4, A4, B4, C5], pick: 1)\n", 3, [], "mark(name: a)\njump(to: a, times: 15)\n");
                let seen = new Map<f64, bool>();
                for (let i = 0; i < s.events.length; i++) if (s.events[i].kind == EventKind.NoteOn) seen.set(s.events[i].pitch, true);
                expect.that(seen.size >= 4).is(true);
            });
        });

        group("humanize and picks", () => {
            test("humanize moves notes within its range", (expect) => {
                let p = "one=note(p: C4, vel: 0.5)\n";
                let s = compile("humanize(time: 10ms, vel: 0.1)\npattern(name: one, times: 64)\n", 1, [p]);
                let moved = 0;
                for (let i = 0; i < s.events.length; i++) {
                    let e = s.events[i];
                    if (e.kind != EventKind.NoteOn) continue;
                    let grid = Math.round(e.time / 0.125) * 0.125;
                    expect.that(Math.abs(e.time - grid) <= 0.0100001).is(true);
                    expect.that(Math.abs(e.vel - 0.5) <= 0.1000001).is(true);
                    if (e.time != grid) moved++;
                }
                expect.that(moved > 50).is(true);
                let off = compile("humanize(time: 10ms)\nhumanize(time: 0)\npattern(name: one, times: 8)\n", 1, [p]);
                let t = ons(off);
                for (let i = 0; i < t.length; i++) expect.that(t[i] == Math.round(t[i] / 0.125) * 0.125).is(true);
            });
            test("pick plays different notes from the list", (expect) => {
                let s = compile("note(p: [C4, E4, G4, B4], pick: 3)\n");
                let pitches = new Array<f64>();
                for (let i = 0; i < s.events.length; i++) if (s.events[i].kind == EventKind.NoteOn) pitches.push(s.events[i].pitch);
                expect.that(pitches.length).is(3);
                expect.that(pitches[0] != pitches[1] && pitches[1] != pitches[2] && pitches[0] != pitches[2]).is(true);
                for (let i = 0; i < 3; i++) expect.that(pitches[i] == 60 || pitches[i] == 64 || pitches[i] == 67 || pitches[i] == 71).is(true);
            });
            test("pick(from: …) plays one of the patterns each pass", (expect) => {
                let a = "fa=note(p: C2)\n";
                let b = "fb=note(p: D2)\n";
                let s = compile("pick(from: [fa, fb])\n", 5, [a, b], "mark(name: x)\njump(to: x, times: 31)\n");
                let c = 0;
                let d = 0;
                for (let i = 0; i < s.events.length; i++) {
                    let e = s.events[i];
                    if (e.kind != EventKind.NoteOn) continue;
                    if (e.pitch == 36) c++;
                    if (e.pitch == 38) d++;
                }
                expect.that(c + d).is(32);
                expect.that(c > 4 && d > 4).is(true);
                expect.that(problems(compile("pick(from: [fa, nope])\n", 1, [a])).includes("no pattern named 'nope'")).is(true);
            });
            test("song.yaml keeps the seed", (expect) => {
                let c = parseSongConfig("title: T\nseed: 42\nchannels:\n").config;
                expect.that(c.seed).is(42);
                expect.that(songConfigText(c).includes("seed: 42")).is(true);
                expect.that(parseSongConfig("seed: -3\n").diagnostics.items.length > 0).is(true);
            });
        });
    }
}
