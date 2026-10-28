import { Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong } from "../score/compiler";
import { buildOverview, Lane, Mark, normalise, Overview } from "../editor/overview";
import { Column, COLLAPSED_WIDTH, EditorView, STRIP, summaryAt } from "../editor/view";
import { docBlocks, DocKind } from "../editor/docs";
import { Doc } from "../editor/doc";

@editTime
function overviewOf(channel: string, extra: Array<SongFile> = []): Overview {
    let files = [new SongFile("song.yaml", "bpm: 120\nrows_per_beat: 4\nchannels:\n  - file: a.ch\n"), new SongFile("a.ch", channel)];
    for (let i = 0; i < extra.length; i++) files.push(extra[i]);
    let song = Song.fromFiles(files);
    let score = compileSong(song);
    let bpm = new Array<f64>();
    for (let r = 0; r < score.grid.rows.length; r++) bpm.push(120);
    return buildOverview(song.checked("a.ch")!, song, score.grid, bpm);
}

@editTime
function kinds(ov: Overview): string {
    let out = new Array<string>();
    for (let i = 0; i < ov.marks.length; i++) out.push(`${<i32>ov.marks[i].kind}`);
    return out.join(",");
}

export class OverviewTests extends Tests {
    override run(): void {
        group("overview", () => {
            test("notes carry pitch, length, velocity and instrument", (expect) => {
                let ov = overviewOf("inst(name: saw); vel(v: 0.5)\nnote(p: C4, len: 1/4)\nnote(p: G4)\n");
                expect.that(kinds(ov)).is(`${<i32>Mark.Inst},${<i32>Mark.Note},${<i32>Mark.Note}`);
                let n = ov.marks[1];
                expect.that(n.row).is(1);
                expect.that(n.length).is(4);
                expect.that(n.pitch).is(60);
                expect.that(n.weight).is(0.5);
                expect.that(n.lane == Lane.Notes).is(true);
                expect.that(ov.pitchPos(60)).is(0);
                expect.that(ov.pitchPos(67)).is(1);
            });
            test("chords, at and strum", (expect) => {
                let ov = overviewOf("chord(root: C4, type: maj, strum: 1, at: 0.5)\n");
                expect.that(ov.marks.length).is(3);
                expect.that(ov.marks[0].kind == Mark.Chord).is(true);
                expect.that(ov.marks[0].row).is(0.5);
                expect.that(ov.marks[2].row).is(2.5);
                expect.that(ov.marks[2].pitch).is(67);
            });
            test("patterns are a bracket plus their notes, repeated", (expect) => {
                let hats = new SongFile("patterns/hats.pat", "note(p: C1)\n\nnote(p: D1)\n\n");
                let ov = overviewOf("pattern(name: hats, times: 3)\n", [hats]);
                expect.that(ov.marks[0].kind == Mark.Pattern).is(true);
                expect.that(ov.marks[0].length).is(12);
                expect.that(ov.marks[0].weight).is(3);
                expect.that(ov.marks.length).is(7);
                expect.that(ov.marks[6].row).is(10);
                expect.that(ov.marks[6].fromPattern).is(true);
            });
            test("ramps know where they start and end; lfo runs until lfo_off", (expect) => {
                let ov = overviewOf("set(cutoff: 200)\nramp(cutoff: 8k, over: 2)\nlfo(param: pan, rate: 1b, depth: 0.5)\n\n\nlfo_off(param: pan)\n");
                let ramp = ov.marks[1];
                expect.that(ramp.kind == Mark.Ramp).is(true);
                expect.that(ramp.length).is(2);
                expect.that(ramp.from).is(normalise("cutoff", 200));
                expect.that(ramp.to > ramp.from).is(true);
                let lfo = ov.marks[2];
                expect.that(lfo.kind == Mark.Lfo).is(true);
                expect.that(lfo.length).is(3);
            });
            test("sends give notes an echo tail; glides go from the last pitch", (expect) => {
                let ov = overviewOf("set(delay: 0.5)\nnote(p: C4)\nglide(to: G4, over: 2)\n");
                expect.that(ov.marks[1].tail).is(3);
                let g = ov.marks[2];
                expect.that(g.kind == Mark.Glide).is(true);
                expect.that(g.pitch).is(60);
                expect.that(g.pitchTo).is(67);
            });
        });

        group("layout", () => {
            test("narrow windows fold the other tracks; the selected one takes the rest", (expect) => {
                let v = new EditorView();
                v.width = 600;
                v.height = 500;
                v.setColumns([new Column(new Doc("a.ch", "x\n"), "a", 40, false, false, false), new Column(new Doc("b.ch", "y\n"), "b", 40, false, false, false), new Column(new Doc("c.ch", "z\n"), "c", 40, false, false, false)]);
                v.focus = 1;
                v.fit();
                expect.that(v.columns[0].folded).is(true);
                expect.that(v.columns[1].folded).is(false);
                expect.that(v.columns[2].folded).is(true);
                expect.that(v.contentWidth()).is(v.width - v.gutterW);
                v.width = 3000;
                v.fit();
                expect.that(v.columns[0].folded).is(false);
                expect.that(v.contentWidth()).is(v.width - v.gutterW);
                expect.that(v.columns[1].extraW > 0).is(true);
            });
            test("the documentation panel takes its share on wide windows", (expect) => {
                let v = new EditorView();
                v.width = 1400;
                v.height = 600;
                v.setColumns([new Column(new Doc("a.ch", "x\n"), "a", 30, false, false, false)]);
                v.toggleDocs();
                v.fit();
                expect.that(v.docsOpen).is(true);
                expect.that(v.contentWidth()).is(v.layoutWidth() - v.gutterW);
                expect.that(v.layoutWidth() < v.width).is(true);
                v.width = 500;
                expect.that(v.layoutWidth()).is(500);
            });
            test("the documentation covers every command", (expect) => {
                let blocks = docBlocks();
                let names = new Array<string>();
                for (let i = 0; i < blocks.length; i++) if (blocks[i].kind == DocKind.Signature) names.push(blocks[i].anchor);
                expect.that(names.includes("note")).is(true);
                expect.that(names.includes("jump")).is(true);
                expect.that(names.includes("param")).is(true);
                expect.that(names.includes("sample")).is(true);
                expect.that(names.includes("fx")).is(true);
                expect.that(names.includes("prog")).is(true);
                expect.that(names.includes("euclid")).is(true);
                expect.that(names.includes("mod") && names.includes("tuning")).is(true);
                expect.that(names.length).is(47);
            });
            test("breadcrumb summaries", (expect) => {
                expect.that(summaryAt("chord(root: F3, type: maj7, inv: 0)", 3)).is("F3 maj7");
                expect.that(summaryAt("note(p: C4, len: 1/8); vol(v: 0.5)", 2)).is("C4 · 1/8");
                expect.that(summaryAt("note(p: C4); vol(v: 0.5)", 15)).is("vol v: 0.5");
                expect.that(summaryAt("\tpattern(name: hats, times: 8)", 4)).is("pattern hats ×8");
                expect.that(summaryAt("", 0)).is("");
            });
        });

        group("collapsing", () => {
            test("collapsed columns are a strip; expanded ones add text after it", (expect) => {
                let v = new EditorView();
                v.width = 1000;
                v.height = 600;
                v.setColumns([new Column(new Doc("a.ch", "x\n"), "a", 20, false, false, false), new Column(new Doc("b.ch", "y\n"), "b", 20, false, false, false)]);
                let open = v.columnWidth(v.columns[0]);
                expect.that(open > STRIP).is(true);
                expect.that(v.textLeft(0)).is(v.columnX(0) + STRIP + v.padX);
                v.toggleCollapsed(0);
                expect.that(v.columnWidth(v.columns[0])).is(COLLAPSED_WIDTH);
                expect.that(v.columnX(1)).is(v.gutterW + COLLAPSED_WIDTH);
                expect.that(v.allCollapsed).is(false);
                v.toggleAll();
                expect.that(v.allCollapsed).is(true);
                // Compact rows once nothing shows text.
                expect.that(v.lineH < v.textLineH).is(true);
                v.focus = 1;
                v.typeText("z");
                expect.that(v.columns[1].collapsed).is(false);
                expect.that(v.lineH).is(v.textLineH);
                v.toggleAll();
                v.toggleAll();
                expect.that(v.allCollapsed).is(false);
            });
        });
    }
}
