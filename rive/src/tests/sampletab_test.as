import { Tests } from "rive/test";
import { editFrames } from "../synth/sampleedit";
import { SampleData } from "../synth/samples";
import { noteName, SamplePanel } from "../editor/samplepanel";
import { EditorView, KEY_BACKSPACE, KEY_ENTER, KEY_ESCAPE } from "../editor/view";

@editTime
function ramp(n: i32): Float32Array {
    let out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = <f32>(<f64>(i + 1) / <f64>n * 0.5);
    return out;
}

@editTime
function list(a: Float32Array): string {
    let out = new Array<string>();
    for (let i = 0; i < a.length; i++) out.push(`${Math.round(<f64>a[i] * 1000) / 1000}`);
    return out.join(",");
}

@editTime
function panelWith(frames: i32): SamplePanel {
    let p = new SamplePanel();
    let d = new SampleData();
    d.rate = 1000;
    d.frames = frames;
    d.data = ramp(frames);
    p.show("tone", d);
    p.layout(new EditorView(), 1000, 1200);
    return p;
}

export class SampleTabTests extends Tests {
    override run(): void {
        group("sample edits", () => {
            test("trim and cut keep and drop the selection", (expect) => {
                let d = ramp(4); // 0.125 0.25 0.375 0.5
                expect.that(list(editFrames(d, "trim", 1, 3))).is("0.25,0.375");
                expect.that(list(editFrames(d, "cut", 1, 3))).is("0.125,0.5");
            });
            test("reverse, fades, gain and normalize change the selection or all of it", (expect) => {
                let d = ramp(4);
                expect.that(list(editFrames(d, "reverse", 0, 0))).is("0.5,0.375,0.25,0.125");
                expect.that(list(editFrames(d, "reverse", 2, 4))).is("0.125,0.25,0.5,0.375");
                expect.that(list(editFrames(d, "fadein", 0, 0))).is("0.0,0.083,0.25,0.5");
                expect.that(list(editFrames(d, "fadeout", 0, 0))).is("0.125,0.167,0.125,0.0");
                expect.that(list(editFrames(d, "normalize", 0, 0))).is("0.245,0.49,0.735,0.98");
                expect.that(list(editFrames(d, "gain-", 3, 4))).is("0.125,0.25,0.375,0.354");
            });
        });

        group("samples tab", () => {
            test("dragging across the waveform selects frames", (expect) => {
                let p = panelWith(1000);
                let x0 = p.waveX;
                p.pointerDown(x0 + p.waveW * 0.25, p.waveY + 10);
                p.pointerMove(x0 + p.waveW * 0.5, p.waveY + 10);
                p.pointerUp();
                expect.that(p.selA).is(250);
                expect.that(p.selB).is(500);
                expect.that(p.key(KEY_BACKSPACE)).is(true);
                expect.that(p.takeActions().join("|")).is("edit:cut");
                expect.that(p.key(KEY_ESCAPE)).is(true);
                expect.that(p.hasSelection).is(false);
            });
            test("buttons report what to do; trim needs a selection", (expect) => {
                let p = panelWith(100);
                let reverse = p.hitOf("edit:reverse")!;
                p.pointerDown(reverse.x + 2, reverse.y + 2);
                expect.that(p.hitOf("edit:trim") == null).is(true);
                let play = p.hitOf("play")!;
                p.pointerDown(play.x + 2, play.y + 2);
                let make = p.hitOf("newInstrument")!;
                p.pointerDown(make.x + 2, make.y + 2);
                expect.that(p.takeActions().join("|")).is("edit:reverse|play|newInstrument");
            });
            test("the add form records an instrument under a name it suggests", (expect) => {
                let p = new SamplePanel();
                p.instruments = ["pad", "kick"];
                p.show("", null);
                expect.that(p.showingForm).is(true);
                p.layout(new EditorView(), 1000, 1200);
                expect.that(p.hitOf("import") == null).is(true); // no shell, no import
                let next = p.hitOf("inst+")!;
                p.pointerDown(next.x + 2, next.y + 2);
                let up = p.hitOf("oct+")!;
                p.pointerDown(up.x + 2, up.y + 2);
                expect.that(p.recordName).is("kick_c5");
                let name = p.hitOf("recName")!;
                p.pointerDown(name.x + 2, name.y + 2);
                p.buffer = "";
                p.typeText("Big Hit");
                p.key(KEY_ENTER);
                expect.that(p.recordName).is("big_hit");
                let record = p.hitOf("record")!;
                p.pointerDown(record.x + 2, record.y + 2);
                expect.that(p.takeActions().join("|")).is("record");
                p.hosted = true;
                p.layout(new EditorView(), 1000, 1200);
                expect.that(p.hitOf("import") != null).is(true);
            });
            test("note names", (expect) => {
                expect.that(noteName(60)).is("C4");
                expect.that(noteName(46)).is("A#2");
            });
        });
    }
}
