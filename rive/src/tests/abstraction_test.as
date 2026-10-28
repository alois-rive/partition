import { Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { EventKind } from "../score/events";
import { degreeSemitones, parseNumeral } from "../lang/scales";

// 120 bpm, 4 rows per beat: a row is 0.125 s and a bar 2 s.
@editTime
function compile(channel: string, conductor: string = "", patterns: Array<string> = []): Score {
    let files = [
        new SongFile("song.yaml", "bpm: 120\nrows_per_beat: 4\nchannels:\n  - file: a.ch\n"),
        new SongFile("conductor.ch", conductor),
        new SongFile("a.ch", channel),
    ];
    for (let i = 0; i < patterns.length; i++) {
        let eq = patterns[i].indexOf("=");
        files.push(new SongFile(`patterns/${patterns[i].substring(0, eq)}.pat`, patterns[i].substring(eq + 1)));
    }
    return compileSong(Song.fromFiles(files), new CompileOptions());
}

// "time:pitch" of every note, in order.
@editTime
function notes(score: Score): string {
    let out = new Array<string>();
    for (let i = 0; i < score.events.length; i++) {
        let e = score.events[i];
        if (e.kind == EventKind.NoteOn) out.push(`${Math.round(e.time * 1000) / 1000}:${e.pitch}`);
    }
    return out.join(" ");
}

@editTime
function problems(score: Score): string {
    let out = new Array<string>();
    for (let i = 0; i < score.diagnostics.length; i++) if (score.diagnostics[i].isError) out.push(score.diagnostics[i].message);
    return out.join("; ");
}

export class AbstractionTests extends Tests {
    override run(): void {
        group("keys and degrees", () => {
            test("degrees follow the song's key, and a track's own", (expect) => {
                let song = compile("note(d: [1, 3, 5])\n", "key(root: D, mode: dorian)\n");
                expect.that(problems(song)).is("");
                expect.that(notes(song)).is("0.0:62.0 0.0:65.0 0.0:69.0");
                let own = compile("key(root: A, mode: minor); note(d: [1, 8, 0])\n", "key(root: D)\n");
                expect.that(notes(own)).is("0.0:69.0 0.0:81.0 0.0:67.0");
                expect.that(degreeSemitones(0, -6)).is(-12);
            });
            test("a key change in the conductor moves later degrees", (expect) => {
                let s = compile("note(d: 1)\n\n\n\nnote(d: 1)\n", "key(root: C)\n\n\n\nkey(root: E, mode: minor)\n");
                expect.that(notes(s)).is("0.0:60.0 0.5:64.0");
            });
            test("chords on degrees: the key's own, or a type", (expect) => {
                expect.that(notes(compile("chord(d: 2)\n"))).is("0.0:62.0 0.0:65.0 0.0:69.0");
                expect.that(notes(compile("chord(d: 5, size: 4)\n"))).is("0.0:67.0 0.0:71.0 0.0:74.0 0.0:77.0");
                expect.that(notes(compile("chord(d: 2, type: dom7)\n"))).is("0.0:62.0 0.0:66.0 0.0:69.0 0.0:72.0");
                expect.that(problems(compile("chord(type: maj)\n")).includes("needs 'root' (a pitch) or 'd'")).is(true);
            });
        });

        group("progressions", () => {
            test("numerals: case, accidentals and endings", (expect) => {
                let n = parseNumeral("bVII", 0);
                expect.that(n.root).is(10);
                expect.that(n.type).is("maj");
                expect.that(parseNumeral("ii7", 0).type).is("min7");
                expect.that(parseNumeral("V9", 0).type).is("dom9");
                expect.that(parseNumeral("viidim", 0).root).is(11);
                expect.that(parseNumeral("III", 1).root).is(3); // the minor key's own third
                expect.that(parseNumeral("X", 0).error.length > 0).is(true);
                expect.that(parseNumeral("Vzz", 0).error.length > 0).is(true);
            });
            test("one chord per step; - holds, . rests", (expect) => {
                let s = compile("oct(v: 3); prog(chords: \"ii V7 . I -\", every: 1bar)\n");
                expect.that(problems(s)).is("");
                let all = notes(s);
                expect.that(all.startsWith("0.0:50.0 0.0:53.0 0.0:57.0 2.0:55.0 2.0:59.0 2.0:62.0 2.0:65.0 6.0:48.0")).is(true);
                // The last chord holds for two bars.
                let held = 0.0;
                for (let i = 0; i < s.events.length; i++) {
                    let e = s.events[i];
                    if (e.kind == EventKind.NoteOn && Math.abs(e.time - 6) < 1e-9) held = e.seconds;
                }
                expect.that(Math.abs(held - 4) < 1e-9).is(true);
                expect.that(problems(compile("prog(chords: \"ii Q\")\n")).includes("'Q' is not a chord numeral")).is(true);
            });
        });

        group("pattern variables", () => {
            test("calls give values; args gives defaults", (expect) => {
                let riff = "riff=args(root: C4, busy: false)\nnote(p: $root)\nnote(p: E4, if: $busy)\n";
                expect.that(notes(compile("pattern(name: riff, root: F3)\n", "", [riff]))).is("0.125:53.0");
                expect.that(notes(compile("pattern(name: riff, busy: true)\n", "", [riff]))).is("0.125:60.0 0.25:64.0");
            });
            test("degrees and nested calls pass values through", (expect) => {
                let inner = "inner=note(d: $deg)\n";
                let outer = "outer=pattern(name: inner, deg: $step)\n";
                expect.that(notes(compile("pattern(name: outer, step: 5)\n", "key(root: A, mode: minor)\n", [inner, outer]))).is("0.0:76.0");
            });
            test("missing values and variables outside patterns are reported", (expect) => {
                let s = compile("pattern(name: p)\n", "", ["p=note(p: $nope)\n"]);
                expect.that(problems(s).includes("has no value for $nope")).is(true);
                let outside = compile("note(p: $x)\n");
                expect.that(problems(outside).includes("only have values inside patterns")).is(true);
                let bad = compile("pattern(name: p, v: hello)\n", "", ["p=note(p: $v)\n"]);
                expect.that(problems(bad).includes("(from $v)")).is(true);
            });
        });

        group("passes", () => {
            test("a fill on every 4th pass of a pattern", (expect) => {
                let beat = "beat=note(p: C1)\nnote(p: D1, on: 4/4)\nnote(p: E1, except: 4/4)\n";
                let s = compile("pattern(name: beat, times: 8)\n", "", [beat]);
                let d = 0;
                let e = 0;
                for (let i = 0; i < s.events.length; i++) {
                    let ev = s.events[i];
                    if (ev.kind != EventKind.NoteOn) continue;
                    if (ev.pitch == 26) d++;
                    if (ev.pitch == 28) e++;
                }
                expect.that(d).is(2);
                expect.that(e).is(6);
            });
            test("a track row's pass counts its plays through jumps", (expect) => {
                let s = compile("note(p: C4, on: 2)\n\n", "mark(name: a)\n\njump(to: a, times: 2)\n");
                expect.that(notes(s)).is("0.375:60.0");
            });
        });
    }
}
