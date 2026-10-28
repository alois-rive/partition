import { Expect, Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { ParamId } from "../lang/params";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { EventKind, FIELDS, packEvents, ScoreEvent, unpackEvent } from "../score/events";

// 120 bpm, 4 rows per beat: a row is 0.125 s.
const YAML = "bpm: 120\nrows_per_beat: 4\nchannels:\n  - file: a.ch\n";

@editTime
function build(channel: string, extra: Array<SongFile> = [], conductor: string = "", startRow: i32 = 0): Score {
    let files = [new SongFile("song.yaml", YAML), new SongFile("conductor.ch", conductor), new SongFile("a.ch", channel)];
    for (let i = 0; i < extra.length; i++) files.push(extra[i]);
    let o = new CompileOptions();
    o.startRow = startRow;
    return compileSong(Song.fromFiles(files), o);
}

@editTime
function of(score: Score, kind: EventKind): Array<ScoreEvent> {
    let out = new Array<ScoreEvent>();
    for (let i = 0; i < score.events.length; i++) if (score.events[i].kind == kind) out.push(score.events[i]);
    return out;
}

@editTime
function params(score: Score, param: i32): Array<ScoreEvent> {
    let out = new Array<ScoreEvent>();
    let all = of(score, EventKind.Param);
    for (let i = 0; i < all.length; i++) if (all[i].param == param && all[i].channel >= 0) out.push(all[i]);
    return out;
}

@editTime
function pitches(score: Score): string {
    let on = of(score, EventKind.NoteOn);
    let out = new Array<string>();
    for (let i = 0; i < on.length; i++) out.push(`${<i32>on[i].pitch}`);
    return out.join(",");
}

@editTime
function times(score: Score): string {
    let on = of(score, EventKind.NoteOn);
    let out = new Array<string>();
    for (let i = 0; i < on.length; i++) out.push(`${Math.round(on[i].time * 1000) / 1000}`);
    return out.join(",");
}

@editTime
function codes(score: Score): string {
    let out = new Array<string>();
    for (let i = 0; i < score.diagnostics.length; i++) out.push(score.diagnostics[i].code);
    return out.join(",");
}

@editTime
function near(expect: Expect, got: f64, want: f64): void {
    let ok = Math.abs(got - want) < 1e-6;
    if (!ok) expect.that(got).is(want);
    expect.that(ok).is(true);
}

export class CompilerTests extends Tests {
    override run(): void {
        group("notes", () => {
            test("pitches, octave and transpose", (expect) => {
                let s = build("note(p: C4)\noct(v: 2); note(p: A)\ntranspose(v: 12st); note(p: [C4, E4])\nnote(p: 60)\n");
                expect.that(codes(s)).is("");
                expect.that(pitches(s)).is("60,45,72,76,72");
                expect.that(times(s)).is("0.0,0.125,0.25,0.25,0.375");
            });
            test("lengths in every unit", (expect) => {
                let s = build("note(p: C4)\nnote(p: C4, len: 1/4)\nnote(p: C4, len: 2b)\nnote(p: C4, len: 1bar)\nnote(p: C4, len: 300ms)\nlen(v: 3); note(p: C4)\n");
                let on = of(s, EventKind.NoteOn);
                near(expect, on[0].seconds, 0.125);
                near(expect, on[1].seconds, 0.5);
                near(expect, on[2].seconds, 1.0);
                near(expect, on[3].seconds, 2.0);
                near(expect, on[4].seconds, 0.3);
                near(expect, on[5].seconds, 0.375);
                let off = of(s, EventKind.NoteOff);
                expect.that(off.length).is(6);
            });
            test("velocity: modifier, override and order within a row", (expect) => {
                let s = build("note(p: C4); vel(v: 0.5); note(p: D4)\nnote(p: E4, vel: 1)\nnote(p: F4)\n");
                let on = of(s, EventKind.NoteOn);
                near(expect, on[0].vel, 0.8);
                near(expect, on[1].vel, 0.5);
                near(expect, on[2].vel, 1);
                near(expect, on[3].vel, 0.5);
            });
            test("continuation lines run after their row", (expect) => {
                let s = build("note(p: C4)\n\toct(v: 5)\n\tnote(p: C)\nnote(p: D)\n");
                expect.that(pitches(s)).is("60,72,74");
                expect.that(times(s)).is("0.0,0.0,0.125");
            });
            test("chords: inversions, spread and strum", (expect) => {
                let s = build("chord(root: A3, type: min7)\nchord(root: C4, type: maj, inv: 1)\nchord(root: C4, type: maj, spread: 1, strum: 10ms)\n");
                expect.that(pitches(s)).is("57,60,64,67,64,67,72,60,76,67");
                let on = of(s, EventKind.NoteOn);
                near(expect, on[8].time, 0.25 + 0.01);
            });
            test("chords take at: like notes", (expect) => {
                let s = build("chord(root: C4, type: maj, at: 0.5)\n");
                expect.that(codes(s)).is("");
                expect.that(times(s)).is("0.063,0.063,0.063");
            });
            test("micro-timing with at, and its limit", (expect) => {
                let s = build("note(p: C4, at: 0.5)\nnote(p: C4, at: 1/4)\n");
                let on = of(s, EventKind.NoteOn);
                near(expect, on[0].time, 0.0625);
                near(expect, on[1].time, 0.125 + 0.125 * 0.999);
                expect.that(codes(s)).is("range");
            });
            test("instruments, overrides and unknown names", (expect) => {
                let s = build("inst(name: saw); note(p: C4)\nnote(p: C4, inst: kick)\ninst(name: nope); note(p: C4)\n");
                let on = of(s, EventKind.NoteOn);
                let lib = s.instruments;
                expect.that(lib[on[0].inst].name).is("saw");
                expect.that(lib[on[1].inst].name).is("kick");
                expect.that(lib[on[2].inst].name).is("saw");
                expect.that(codes(s)).is("unknown-instrument");
            });
            test("cut and glide", (expect) => {
                let s = build("note(p: C4, len: 4); glide(to: G4, over: 2)\n\ncut(fade: 1/16)\n");
                let glide = of(s, EventKind.Glide);
                expect.that(glide[0].pitch).is(67);
                near(expect, glide[0].seconds, 0.25);
                let cut = of(s, EventKind.Cut);
                near(expect, cut[0].time, 0.25);
                near(expect, cut[0].seconds, 0.125);
            });
            test("per-note glide starts from the previous pitch", (expect) => {
                let s = build("note(p: C4)\nnote(p: E4, glide: 1)\n");
                let on = of(s, EventKind.NoteOn);
                expect.that(on[1].from).is(60);
                near(expect, on[1].value, 0.125);
            });
        });

        group("automation", () => {
            test("vol, set and ramp emit parameter changes", (expect) => {
                let s = build("vol(v: 0.5); set(cutoff: 800)\nramp(cutoff: 3.2k, over: 2, curve: exp)\n");
                let vol = params(s, ParamId.Vol);
                expect.that(vol.length).is(1);
                expect.that(vol[0].inst).is(-1);
                let cut = params(s, ParamId.Cutoff);
                expect.that(cut.length).is(2);
                expect.that(cut[0].value).is(800);
                expect.that(cut[0].seconds).is(0);
                expect.that(cut[1].value).is(3200);
                expect.that(cut[1].from).is(800);
                near(expect, cut[1].seconds, 0.25);
                expect.that(cut[1].curve).is(1);
                expect.that(cut[1].inst >= 0).is(true);
            });
            test("a ramp starts from where a running ramp has got to", (expect) => {
                let s = build("vol(v: 0)\nramp(vol: 1, over: 4)\n\nramp(vol: 0, over: 1)\n");
                let vol = params(s, ParamId.Vol);
                near(expect, vol[2].from, 0.5);
            });
            test("first ramp of an instrument parameter starts from the instrument's value", (expect) => {
                let s = build("inst(name: lowpad)\nramp(cutoff: 2k, over: 1)\n", [new SongFile("instruments/lowpad.inst", "osc(wave: saw)\nfilter(type: lowpass, cutoff: 500)\n")]);
                let cut = params(s, ParamId.Cutoff);
                expect.that(cut[0].from).is(500);
            });
            test("instrument defaults apply on first selection only", (expect) => {
                let s = build("inst(name: wet)\ninst(name: saw)\ninst(name: wet)\n", [new SongFile("instruments/wet.inst", "osc(wave: saw)\ndefaults(vol: 0.6, reverb: 0.4)\n")]);
                expect.that(params(s, ParamId.Vol).length).is(1);
                near(expect, params(s, ParamId.Reverb)[0].value, 0.4);
            });
            test("macro parameters map onto their target", (expect) => {
                let s = build("inst(name: m)\nset(brightness: 0.5)\ninst(name: saw)\nset(brightness: 1)\n", [new SongFile("instruments/m.inst", "osc(wave: saw)\nparam(name: brightness, target: cutoff, min: 200, max: 1200)\n")]);
                let cut = params(s, ParamId.Cutoff);
                expect.that(cut.length).is(1);
                expect.that(cut[0].value).is(700);
                expect.that(codes(s)).is("unknown-arg");
            });
            test("lfo rates from frequency and from duration", (expect) => {
                let s = build("lfo(param: cutoff, rate: 2Hz, depth: 0.3)\nlfo(param: pan, rate: 1bar, depth: 1, shape: tri, id: wob)\nlfo_off(param: pan, id: wob)\n");
                let lfo = of(s, EventKind.Lfo);
                expect.that(lfo.length).is(2);
                near(expect, lfo[0].rate, 2);
                near(expect, lfo[1].rate, 0.5);
                expect.that(lfo[1].curve).is(1);
                expect.that(lfo[1].inst).is(-1);
                expect.that(of(s, EventKind.LfoOff)[0].note).is(lfo[1].note);
            });
            test("conductor master volume and its ramp", (expect) => {
                let s = build("cut()\n\n\n\n", [], "master(vol: 0.5)\nramp(master: 1, over: 2)\n");
                let m = new Array<ScoreEvent>();
                let all = of(s, EventKind.Param);
                for (let i = 0; i < all.length; i++) if (all[i].param == ParamId.Master) m.push(all[i]);
                expect.that(m.length).is(3);
                expect.that(m[1].value).is(0.5);
                near(expect, m[2].time, 0.125);
                near(expect, m[2].seconds, 0.25);
            });
        });

        group("patterns", () => {
            let HATS = new SongFile("patterns/hats.pat", "note(p: C1)\n\nnote(p: D1)\n\n");
            test("patterns overlay the channel's own rows", (expect) => {
                let s = build("pattern(name: hats, times: 2); note(p: C4)\nnote(p: E4)\n", [HATS]);
                expect.that(codes(s)).is("");
                expect.that(pitches(s)).is("60,24,64,26,24,26");
                expect.that(times(s)).is("0.0,0.0,0.125,0.25,0.5,0.75");
            });
            test("a pattern starts from the channel's state and keeps its changes", (expect) => {
                let p = new SongFile("patterns/p.pat", "note(p: C)\noct(v: 6); vel(v: 0.2); note(p: C)\n");
                let s = build("oct(v: 3); pattern(name: p, times: 2)\n\n\n\nnote(p: C)\n", [p]);
                expect.that(pitches(s)).is("48,84,48,84,48");
                let on = of(s, EventKind.NoteOn);
                near(expect, on[4].vel, 0.8);
            });
            test("each repetition plays as a new owner forked from the call", (expect) => {
                let s = build("pattern(name: hats, times: 2)\n", [HATS]);
                let forks = of(s, EventKind.Fork);
                expect.that(forks.length).is(3);
                expect.that(forks[0].parent).is(0);
                expect.that(forks[1].parent).is(forks[0].owner);
                expect.that(forks[2].parent).is(forks[0].owner);
                let on = of(s, EventKind.NoteOn);
                expect.that(on[0].owner).is(forks[1].owner);
                expect.that(on[2].owner).is(forks[2].owner);
            });
            test("pattern parameter changes address the pattern's owner", (expect) => {
                let p = new SongFile("patterns/p.pat", "vol(v: 0.1); note(p: C4)\n");
                let s = build("pattern(name: p)\nnote(p: C4)\n", [p]);
                let vol = params(s, ParamId.Vol);
                expect.that(vol.length).is(1);
                expect.that(vol[0].owner).greaterThan(0);
                expect.that(of(s, EventKind.NoteOn)[1].owner).is(0);
            });
            test("patterns play past the end of the song", (expect) => {
                let s = build("pattern(name: hats, times: 3)\n", [HATS]);
                expect.that(of(s, EventKind.NoteOn).length).is(6);
                near(expect, s.duration, 12 * 0.125);
            });
            test("end() stops patterns too", (expect) => {
                let s = build("pattern(name: hats, times: 4)\n\n", [HATS], "\nend()\n");
                expect.that(of(s, EventKind.NoteOn).length).is(1);
            });
            test("macros may target oscillator parameters", (expect) => {
                let s = build("inst(name: m)\nset(sparkle: 1)\n", [new SongFile("instruments/m.inst", "osc(wave: sine)\nosc(wave: sine, fm: 0.5)\nparam(name: sparkle, target: osc2.fm, min: 0, max: 4)\n")]);
                expect.that(codes(s)).is("");
                expect.that(params(s, 32 + 5 + 3)[0].value).is(4);
            });
            test("stop ends running patterns", (expect) => {
                let s = build("pattern(name: hats, times: 4, id: h)\n\n\n\n\nstop(id: h)\n", [HATS]);
                expect.that(of(s, EventKind.NoteOn).length).is(3);
            });
            test("nested patterns", (expect) => {
                let outer = new SongFile("patterns/outer.pat", "pattern(name: hats)\n\n\n\nnote(p: G4)\n");
                let s = build("pattern(name: outer)\n", [HATS, outer]);
                expect.that(pitches(s)).is("24,26,67");
            });
            test("patterns follow conductor jumps", (expect) => {
                let one = new SongFile("patterns/one.pat", "note(p: C4)\n");
                let s = build("\npattern(name: one)\n\n", [one], "mark(name: a)\n\njump(to: a, times: 1)\n");
                expect.that(times(s)).is("0.125,0.5");
            });
            test("cycles, unknown patterns and empty patterns are reported", (expect) => {
                let a = new SongFile("patterns/a.pat", "pattern(name: b)\nnote(p: C4)\n");
                let b = new SongFile("patterns/b.pat", "pattern(name: a)\n");
                let e = new SongFile("patterns/e.pat", "");
                let s = build("pattern(name: a)\npattern(name: zz)\npattern(name: e)\n", [a, b, e]);
                expect.that(codes(s)).is("pattern-cycle,pattern-cycle,unknown-pattern,range");
                expect.that(pitches(s)).is("60");
            });
            test("problems in repeated rows are reported once", (expect) => {
                let p = new SongFile("patterns/p.pat", "inst(name: nope)\n");
                let s = build("pattern(name: p, times: 8)\n", [p]);
                expect.that(codes(s)).is("unknown-instrument");
            });
        });

        group("score", () => {
            test("row marks, end and duration", (expect) => {
                let s = build("note(p: C4)\n\nnote(p: C4, len: 1bar)\n");
                expect.that(s.count(EventKind.RowMark)).is(3);
                expect.that(s.count(EventKind.End)).is(1);
                // The last note outlasts the rows: the song ends with it.
                near(expect, s.duration, 0.25 + 2.0);
                let last = s.events[s.events.length - 1];
                expect.that(last.kind == EventKind.End).is(true);
            });
            test("events are sorted by time", (expect) => {
                let s = build("note(p: C4, len: 4)\nnote(p: D4)\n");
                for (let i = 1; i < s.events.length; i++) {
                    expect.that(s.events[i].time >= s.events[i - 1].time).is(true);
                }
            });
            test("playing from a row folds earlier state into time zero", (expect) => {
                let s = build("vol(v: 0.2); note(p: C4, len: 8)\nramp(vol: 1, over: 4)\n\nnote(p: D4)\nnote(p: E4)\n", [], "", 3);
                expect.that(pitches(s)).is("62,64");
                near(expect, of(s, EventKind.NoteOn)[0].time, 0);
                expect.that(s.count(EventKind.NoteOff)).is(2);
                let vol = params(s, ParamId.Vol);
                expect.that(vol.length).is(2);
                near(expect, vol[0].time, 0);
                expect.that(vol[0].seconds).is(0);
                near(expect, vol[1].from, 0.6);
                near(expect, vol[1].seconds, 0.25);
                expect.that(s.rowAt(0)).is(3);
            });
            test("pack and unpack", (expect) => {
                let s = build("note(p: C4); set(cutoff: 1k)\n");
                let data = packEvents(s.events);
                expect.that(data.length).is(s.events.length * FIELDS);
                for (let i = 0; i < s.events.length; i++) {
                    let a = s.events[i];
                    let b = unpackEvent(data, i);
                    expect.that(b.describe()).is(a.describe());
                }
            });
        });
    }
}
