import { Expect, Tests } from "rive/test";
import { CheckContext, checkSource, CheckedFile, FileKind } from "../lang/check";
import { DurUnit, parsePitch } from "../lang/types";
import { registry } from "../lang/commands";
import { ParamId } from "../lang/params";

@editTime
function codes(text: string, kind: FileKind): string {
    return checkSource("t.ch", text, kind).diagnostics.codes();
}

@editTime
function one(text: string): CheckedFile {
    return checkSource("t.ch", text, FileKind.Channel);
}

@editTime
function near(expect: Expect, got: f64, want: f64): void {
    expect.that(Math.abs(got - want) < 1e-9).is(true);
}

export class CheckTests extends Tests {
    override run(): void {
        group("pitches", () => {
            test("names and octaves", (expect) => {
                expect.that(parsePitch("C4")!.num).is(60);
                expect.that(parsePitch("A4")!.num).is(69);
                expect.that(parsePitch("F#3")!.num).is(54);
                expect.that(parsePitch("Bb2")!.num).is(46);
                expect.that(parsePitch("c-1")!.num).is(0);
                expect.that(parsePitch("Eb")!.hasOctave).is(false);
                expect.that(parsePitch("Eb")!.num).is(3);
                expect.that(parsePitch("H4") == null).is(true);
                expect.that(parsePitch("C10") == null).is(true);
            });
        });

        group("typing", () => {
            test("note with pitch, list and midi", (expect) => {
                let f = one("note(p: C4, len: 1/8, vel: 80%)\nnote(p: [C4, E4, G4])\nnote(p: 60)");
                expect.that(f.diagnostics.length).is(0);
                let n = f.rows[0][0];
                expect.that(n.get("p").items[0].num).is(60);
                expect.that(n.get("len").unit == DurUnit.Note).is(true);
                expect.that(n.get("len").num).is(0.125);
                near(expect, n.get("vel").num, 0.8);
                expect.that(f.rows[1][0].get("p").items.length).is(3);
                expect.that(f.rows[2][0].get("p").items[0].num).is(60);
            });
            test("gains and durations", (expect) => {
                let f = one("vol(v: -6dB); len(v: 250ms)\nlen(v: 2bar); len(v: 3b); len(v: 2)");
                expect.that(f.diagnostics.length).is(0);
                near(expect, f.rows[0][0].get("v").num, 0.5011872336272722);
                expect.that(f.rows[0][1].get("v").unit == DurUnit.Seconds).is(true);
                near(expect, f.rows[0][1].get("v").num, 0.25);
                expect.that(f.rows[1][0].get("v").unit == DurUnit.Bars).is(true);
                expect.that(f.rows[1][1].get("v").unit == DurUnit.Beats).is(true);
                expect.that(f.rows[1][2].get("v").unit == DurUnit.Rows).is(true);
            });
            test("set parameters with units", (expect) => {
                let f = one("set(cutoff: 1.2k, res: 0.3, reverb: 20%, osc2.detune: 25c)");
                expect.that(f.diagnostics.length).is(0);
                let p = f.rows[0][0].params;
                expect.that(p.length).is(4);
                expect.that(p[0].info!.id).is(ParamId.Cutoff);
                expect.that(p[0].value.num).is(1200);
                near(expect, p[2].value.num, 0.2);
                near(expect, p[3].value.num, 0.25);
            });
            test("ramp keeps over and curve apart from params", (expect) => {
                let f = one("ramp(cutoff: 4k, vol: 0, over: 2bar, curve: exp)");
                expect.that(f.diagnostics.length).is(0);
                let c = f.rows[0][0];
                expect.that(c.params.length).is(2);
                expect.that(c.str("curve", "")).is("exp");
                expect.that(c.get("over").num).is(2);
            });
            test("lfo rate as frequency or duration", (expect) => {
                let f = one("lfo(param: cutoff, rate: 2Hz, depth: 0.3)\nlfo(param: pan, rate: 1bar, depth: 1, shape: tri, id: wob)");
                expect.that(f.diagnostics.length).is(0);
                expect.that(f.rows[0][0].get("rate").unit == DurUnit.Hz).is(true);
                expect.that(f.rows[1][0].get("rate").unit == DurUnit.Bars).is(true);
                expect.that(f.rows[0][0].params[0].info!.id).is(ParamId.Cutoff);
            });
            test("chord", (expect) => {
                let f = one("chord(root: A3, type: min9, inv: 1, strum: 20ms)");
                expect.that(f.diagnostics.length).is(0);
            });
        });

        group("diagnostics", () => {
            test("unknown command with suggestion", (expect) => {
                let f = one("nte(p: C4)");
                expect.that(f.diagnostics.codes()).is("unknown-command");
                expect.that(f.diagnostics.items[0].message.includes("'note'")).is(true);
                expect.that(f.rows[0].length).is(0);
            });
            test("unknown arg with suggestion", (expect) => {
                let f = one("note(pitch: C4)");
                expect.that(f.diagnostics.codes()).is("unknown-arg,missing-arg");
                expect.that(f.diagnostics.items[0].message.includes("did you mean 'p'")).is(true);
            });
            test("unknown arg near miss", (expect) => {
                let f = one("note(p: C4, lne: 2)");
                expect.that(f.diagnostics.codes()).is("unknown-arg");
                expect.that(f.diagnostics.items[0].message.includes("did you mean 'len'")).is(true);
            });
            test("missing arg", (expect) => {
                expect.that(codes("inst()", FileKind.Channel)).is("missing-arg");
                expect.that(codes("set()", FileKind.Channel)).is("missing-arg");
                expect.that(codes("ramp(over: 2)", FileKind.Channel)).is("missing-arg");
            });
            test("type", (expect) => {
                expect.that(codes("vol(v: C4)", FileKind.Channel)).is("type");
                expect.that(codes("note(p: 1/4)", FileKind.Channel)).is("type");
                expect.that(codes("len(v: 3dB)", FileKind.Channel)).is("type");
                expect.that(codes("vol(v: [1, 2])", FileKind.Channel)).is("type");
                expect.that(codes("len(v: -2)", FileKind.Channel)).is("type");
            });
            test("range", (expect) => {
                expect.that(codes("pan(v: 3)", FileKind.Channel)).is("range");
                expect.that(codes("oct(v: 2.5)", FileKind.Channel)).is("range");
                expect.that(codes("chord(root: C4, type: min13)", FileKind.Channel)).is("range");
                expect.that(codes("set(res: 2)", FileKind.Channel)).is("range");
                expect.that(codes("sig(v: 4/3)", FileKind.Conductor)).is("range");
            });
            test("scope", (expect) => {
                expect.that(codes("bpm(v: 120)", FileKind.Channel)).is("scope");
                expect.that(codes("note(p: C4)", FileKind.Conductor)).is("scope");
                expect.that(codes("osc(wave: saw)", FileKind.Pattern)).is("scope");
                expect.that(codes("ramp(cutoff: 1k, over: 2)", FileKind.Conductor)).is("scope");
                expect.that(codes("ramp(bpm: 130, over: 2)", FileKind.Channel)).is("scope");
                expect.that(codes("ramp(bpm: 130, over: 8bar); ramp(master: -3dB, over: 2)", FileKind.Conductor)).is("");
            });
            test("errors drop only their command", (expect) => {
                let f = one("vol(v: 9); note(p: C4)");
                expect.that(f.diagnostics.codes()).is("range");
                expect.that(f.rows[0].length).is(1);
                expect.that(f.rows[0][0].name).is("note");
            });
            test("macros from instruments", (expect) => {
                let ctx = new CheckContext();
                ctx.macros.push("brightness");
                let f = checkSource("t.ch", "set(brightness: 0.5); lfo(param: brightness, rate: 1bar, depth: 0.2)", FileKind.Channel, ctx);
                expect.that(f.diagnostics.length).is(0);
                expect.that(f.rows[0][0].params[0].info == null).is(true);
                expect.that(codes("set(brightness: 0.5)", FileKind.Channel)).is("unknown-arg");
            });
            test("instrument file", (expect) => {
                let f = checkSource("p.inst", "base(preset: pad)\nosc(wave: saw, level: 0.5, detune: -8c, unison: 3, spread: 12c)\nenv(a: 400ms, d: 1s, s: 0.7, r: 2s)\nfilter(type: lowpass, cutoff: 1.4k, res: 0.2)\nvoice(poly: 8, mono: false)\ndefaults(vol: 0.6, reverb: 0.4)", FileKind.Instrument);
                expect.that(f.diagnostics.codes()).is("");
                expect.that(f.commands().length).is(6);
                expect.that(codes("osc(wave: sawtooth)", FileKind.Instrument)).is("range");
            });
            test("every spec has a signature", (expect) => {
                let reg = registry();
                expect.that(reg.get("note")!.signature()).is("note(p?, d?, len?, vel?, inst?, glide?, at?)");
                expect.that(reg.get("set")!.signature()).is("set(<param>: value, …)");
            });
        });
    }
}
