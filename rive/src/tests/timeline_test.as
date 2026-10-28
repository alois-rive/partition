import { Expect, Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";

@editTime
function songWith(yaml: string, conductor: string, channel: string): Song {
    return Song.fromFiles([
        new SongFile("song.yaml", yaml + "channels:\n  - file: a.ch\n"),
        new SongFile("conductor.ch", conductor),
        new SongFile("a.ch", channel),
    ]);
}

@editTime
function compile(yaml: string, conductor: string, channel: string, loops: i32 = 1, startRow: i32 = 0): Score {
    let o = new CompileOptions();
    o.loops = loops;
    o.startRow = startRow;
    return compileSong(songWith(yaml, conductor, channel), o);
}

@editTime
function near(expect: Expect, got: f64, want: f64): void {
    let ok = Math.abs(got - want) < 1e-6;
    if (!ok) expect.that(got).is(want);
    expect.that(ok).is(true);
}

@editTime
function order(score: Score): string {
    return score.playback.source.join(",");
}

@editTime
function rows(n: i32): string {
    let out = "";
    for (let i = 0; i < n; i++) out += "cut()\n";
    return out;
}

export class TimelineTests extends Tests {
    override run(): void {
        group("rows", () => {
            test("row length from bpm and rows per beat", (expect) => {
                let s = compile("bpm: 122\nrows_per_beat: 4\n", "", rows(32));
                expect.that(s.playback.count).is(32);
                near(expect, s.playback.dur[0], 60.0 / (122 * 4));
                near(expect, s.playback.start[16], 16 * 60.0 / (122 * 4));
                near(expect, s.duration, 32 * 60.0 / (122 * 4));
            });
            test("trailing empty rows do not play", (expect) => {
                let s = compile("", "", "cut()\n\n\n");
                expect.that(s.playback.count).is(1);
            });
            test("grid bars, beats and labels", (expect) => {
                let s = compile("signature: 4/4\nrows_per_beat: 4\n", "", rows(40));
                let g = s.grid;
                expect.that(g.rows[0].label()).is("1.1");
                expect.that(g.rows[1].label()).is("2");
                expect.that(g.rows[4].label()).is("1.2");
                expect.that(g.rows[16].label()).is("2.1");
                expect.that(g.rows[39].bar).is(2);
            });
            test("a signature change restarts the bar", (expect) => {
                let s = compile("rows_per_beat: 2\n", "\n\n\nsig(v: 3/4)\n", rows(20));
                let g = s.grid;
                expect.that(g.rows[2].bar).is(0);
                expect.that(g.rows[3].bar).is(1);
                expect.that(g.rows[3].beat).is(0);
                expect.that(g.rows[9].bar).is(2);
                expect.that(g.rows[9].sigNum).is(3);
            });
            test("bpm and rpb changes", (expect) => {
                let s = compile("bpm: 120\nrows_per_beat: 4\n", "\n\nbpm(v: 60)\nrpb(v: 2)\n", rows(5));
                let pb = s.playback;
                near(expect, pb.dur[0], 0.125);
                near(expect, pb.dur[2], 0.25);
                near(expect, pb.dur[3], 0.5);
                near(expect, pb.start[4], 0.125 * 2 + 0.25 + 0.5);
            });
            test("a linear tempo ramp is integrated exactly", (expect) => {
                // 120 → 240 bpm over 4 rows at 4 rows per beat: ∫ 15 / (120 + 30x) dx = ln(2) / 2.
                let s = compile("bpm: 120\nrows_per_beat: 4\n", "ramp(bpm: 240, over: 4)\n", rows(6));
                let pb = s.playback;
                near(expect, pb.start[4], Math.log(2) / 2);
                near(expect, pb.dur[4], 60.0 / (240 * 4));
                near(expect, pb.bpm[2], 180);
            });
            test("other ramp curves end on the target", (expect) => {
                let s = compile("bpm: 100\n", "ramp(bpm: 150, over: 1bar, curve: exp)\n", rows(20));
                let pb = s.playback;
                expect.that(pb.dur[1] < pb.dur[0]).is(true);
                near(expect, pb.dur[17], 60.0 / (150 * 4));
            });
            test("swing delays odd rows", (expect) => {
                let s = compile("bpm: 120\nswing: 0.5\n", "", rows(4));
                let pb = s.playback;
                near(expect, pb.rowTime(0), 0);
                near(expect, pb.rowTime(1), 0.125 + 0.25 * 0.125);
                near(expect, pb.rowTime(2), 0.25);
            });
        });

        group("arrangement", () => {
            test("jump with times repeats a section", (expect) => {
                let s = compile("", "\nmark(name: a)\n\njump(to: a, times: 2)\n", rows(5));
                expect.that(order(s)).is("0,1,2,3,1,2,3,1,2,3,4");
            });
            test("endless jump plays the loop count, records the loop and falls through", (expect) => {
                let s = compile("bpm: 120\n", "mark(name: a)\n\njump(to: a)\n", rows(4), 1);
                expect.that(order(s)).is("0,1,2,0,1,2,3");
                expect.that(s.playback.loopStart).is(3);
                expect.that(s.playback.loopEnd).is(6);
                near(expect, s.loopStart, 0.375);
                near(expect, s.loopEnd, 0.75);
                let none = compile("bpm: 120\n", "mark(name: a)\n\njump(to: a)\n", rows(4), 0);
                expect.that(order(none)).is("0,1,2,3");
                expect.that(none.playback.loopStart).is(0);
            });
            test("nested repeats", (expect) => {
                let s = compile("", "mark(name: outer)\nmark(name: inner)\njump(to: inner, times: 1)\njump(to: outer, times: 1)\n", rows(4));
                // outer pass: 0 1 2 (inner) 1 2 3 ; again: 0 1 2 1 2 3
                expect.that(order(s)).is("0,1,2,1,2,3,0,1,2,1,2,3");
            });
            test("end stops the song", (expect) => {
                let s = compile("", "\nend()\n", rows(10));
                expect.that(order(s)).is("0,1");
                expect.that(s.playback.ended).is(true);
            });
            test("unknown and duplicate marks", (expect) => {
                let s = compile("", "mark(name: a)\nmark(name: a)\njump(to: b)\n", rows(3));
                let codes = "";
                for (let i = 0; i < s.diagnostics.length; i++) codes += s.diagnostics[i].code + ";";
                expect.that(codes).is("duplicate-mark;unknown-mark;");
                expect.that(order(s)).is("0,1,2");
            });
            test("playing from a row puts it at time zero", (expect) => {
                let s = compile("bpm: 120\n", "mark(name: a)\n\n\njump(to: a, times: 1)\n", rows(6), 1, 2);
                expect.that(order(s)).is("0,1,2,3,0,1,2,3,4,5");
                expect.that(s.playback.firstAudible).is(2);
                near(expect, s.playback.start[2], 0);
                near(expect, s.playback.start[0], -0.25);
            });
            test("the playhead maps time back to source rows", (expect) => {
                let s = compile("bpm: 120\n", "mark(name: a)\njump(to: a, times: 1)\n", rows(3));
                expect.that(order(s)).is("0,1,0,1,2");
                expect.that(s.rowAt(0.3)).is(0);
                expect.that(s.rowAt(0.4)).is(1);
                expect.that(s.rowAt(0.55)).is(2);
            });
        });
    }
}
