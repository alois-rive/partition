import { Tests } from "rive/test";
import { Doc, Pos } from "../editor/doc";
import { Bands, ColumnMap } from "../editor/bands";
import { highlight, Hue } from "../editor/highlight";
import { Column, commandAt, EditorView, KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_TAB } from "../editor/view";

@editTime
function view(texts: Array<string>): EditorView {
    let v = new EditorView();
    v.width = 1200;
    v.height = 600;
    let cols = new Array<Column>();
    for (let i = 0; i < texts.length; i++) cols.push(new Column(new Doc(`c${i}.ch`, texts[i]), `c${i}`, 30, i == 0, false, false));
    v.setColumns(cols);
    return v;
}

export class EditorTests extends Tests {
    override run(): void {
        group("doc", () => {
            test("typing, newlines and backspace across lines", (expect) => {
                let d = new Doc("a.ch", "note(p: C4)\n");
                d.moveTo(new Pos(0, 11), false);
                d.insert("; cut()");
                expect.that(d.lines[0]).is("note(p: C4); cut()");
                d.insert("\nvol(v: 1)", "paste");
                expect.that(d.lines.length).is(2);
                expect.that(d.cursor.line).is(1);
                d.moveTo(new Pos(1, 0), false);
                d.backspace();
                expect.that(d.lines.length).is(1);
                expect.that(d.lines[0]).is("note(p: C4); cut()vol(v: 1)");
            });
            test("selection is replaced by typing", (expect) => {
                let d = new Doc("a.ch", "note(p: C4)\n");
                d.selectWord(new Pos(0, 9));
                expect.that(d.selectedText()).is("C4");
                d.insert("E5");
                expect.that(d.lines[0]).is("note(p: E5)");
            });
            test("multi-line selection delete", (expect) => {
                let d = new Doc("a.ch", "aaa\nbbb\nccc\n");
                d.moveTo(new Pos(0, 1), false);
                d.moveTo(new Pos(2, 2), true);
                expect.that(d.selectedText()).is("aa\nbbb\ncc");
                d.backspace();
                expect.that(d.lines.join("|")).is("ac");
            });
            test("undo merges typing, redo restores", (expect) => {
                let d = new Doc("a.ch", "");
                d.clock = 0;
                d.insert("n");
                d.insert("o");
                d.clock = 5;
                d.insert("x");
                expect.that(d.lines[0]).is("nox");
                d.undo();
                expect.that(d.lines[0]).is("no");
                d.undo();
                expect.that(d.lines[0]).is("");
                d.redo();
                expect.that(d.lines[0]).is("no");
            });
            test("duplicate and move a row with its continuation lines", (expect) => {
                let d = new Doc("a.ch", "a\n\tb\nc\n");
                d.moveTo(new Pos(1, 1), false);
                d.duplicateRow();
                expect.that(d.lines.join("|")).is("a|\tb|a|\tb|c");
                d.moveTo(new Pos(4, 0), false);
                d.moveRow(-1);
                expect.that(d.lines.join("|")).is("a|\tb|c|a|\tb");
                expect.that(d.cursor.line).is(2);
            });
            test("text keeps lines, drops trailing empties", (expect) => {
                let d = new Doc("a.ch", "a\n\nb\n\n\n");
                expect.that(d.text()).is("a\n\nb\n");
                expect.that(new Doc("e.ch", "").text()).is("");
            });
        });

        group("bands", () => {
            test("rows line up across columns with continuation lines", (expect) => {
                let a = ColumnMap.build(["r0", "\tr0b", "r1", "r2"]);
                let b = ColumnMap.build(["x0", "x1", "\tx1b", "\tx1c"]);
                let bands = Bands.build([a, b], 2);
                expect.that(bands.heights.slice(0, 3).join(",")).is("2,3,1");
                expect.that(bands.tops.slice(0, 4).join(",")).is("0,2,5,6");
                expect.that(bands.count).is(5);
                expect.that(bands.bandAt(4)).is(1);
                expect.that(bands.bandAt(5)).is(2);
                expect.that(a.band.join(",")).is("0,0,1,2");
                expect.that(b.sub.join(",")).is("0,0,1,2");
            });
        });

        group("highlight", () => {
            test("commands, args, pitches, numbers, errors", (expect) => {
                let spans = highlight("\tnote(p: C4, len: 1/8); vol(v: @)");
                let kinds = new Array<string>();
                for (let i = 0; i < spans.length; i++) kinds.push(`${<i32>spans[i].hue}`);
                expect.that(spans[0].start).is(0);
                expect.that(spans[spans.length - 1].end).is(33);
                let first = spans[1];
                expect.that(first.start).is(1);
                expect.that(first.hue == Hue.Command).is(true);
                let hasError = false;
                for (let i = 0; i < spans.length; i++) if (spans[i].hue == Hue.Error) hasError = true;
                expect.that(hasError).is(true);
            });
            test("command under the cursor", (expect) => {
                let line = "note(p: C4); vol(v: 1)";
                expect.that(commandAt(line, 3)).is("note");
                expect.that(commandAt(line, 18)).is("vol");
                expect.that(commandAt("", 0)).is("");
            });
        });

        group("view", () => {
            test("keys edit the focused column and report changes", (expect) => {
                let v = view(["mark(name: a)\n", "note(p: C4)\n"]);
                v.focus = 1;
                v.columns[1].doc.moveTo(new Pos(0, 11), false);
                v.key(KEY_ENTER, false, false, false, false);
                v.typeText("cut()");
                v.key(KEY_ENTER, true, false, false, false);
                v.typeText("vol(v: 1)\u0001");
                expect.that(v.columns[1].doc.lines.join("|")).is("note(p: C4)|cut()|\tvol(v: 1)");
                expect.that(v.takeChanged().join(",")).is("1");
                expect.that(v.cursorRow()).is(1);
                v.key(KEY_TAB, false, false, false, false);
                v.key(KEY_BACKSPACE, false, false, false, false);
                expect.that(v.columns[1].doc.lines[2]).is("\tvol(v: 1)");
            });
            test("transport and app shortcuts become actions", (expect) => {
                let v = view(["", "note(p: C4)\n"]);
                v.focus = 1;
                v.key(KEY_ENTER, false, false, false, true);
                v.key(KEY_ENTER, true, true, false, false);
                v.key(KEY_ENTER, false, false, true, false);
                v.key(46, false, false, false, true);
                v.key(77, false, false, false, true);
                v.key(83, false, false, false, true);
                expect.that(v.takeActions().join(",")).is("play,playFromCursor,audition,stop,mute:1,save");
            });
            test("undo through the keyboard", (expect) => {
                let v = view(["", "a\n"]);
                v.focus = 1;
                v.columns[1].doc.moveTo(new Pos(0, 1), false);
                v.typeText("b");
                v.key(90, false, false, false, true);
                expect.that(v.columns[1].doc.lines[0]).is("a");
            });
            test("positions map back through bands and indentation", (expect) => {
                let v = view(["a\n\tb\nc\n", "x\ny\n"]);
                let top = v.gridTop();
                let x1 = v.textLeft(1);
                // Column 1, grid line 2 is band 1 (row y) because band 0 is two lines tall.
                let p = v.posAt(1, x1 + v.charW * 1, top + v.lineH * 2 + 2);
                expect.that(p.line).is(1);
                expect.that(p.ch).is(1);
                // Column 0, line 1 starts with a tab shown two characters wide.
                let x0 = v.textLeft(0);
                let q = v.posAt(0, x0 + v.charW * 3, top + v.lineH * 1 + 2);
                expect.that(q.line).is(1);
                expect.that(q.ch).is(2);
                // Below the end of column 1: grid line 6 is band 5, which would be line 5.
                let r = v.posAt(1, x1, top + v.lineH * 6 + 2);
                expect.that(r.line).is(5);
            });
            test("switching columns keeps the row", (expect) => {
                let v = view(["a\n\tb\nc\n", "x\ny\n"]);
                v.focus = 0;
                v.columns[0].doc.moveTo(new Pos(2, 0), false);
                v.key(93, false, false, false, true);
                expect.that(v.focus).is(1);
                expect.that(v.columns[1].doc.cursor.line).is(1);
                v.key(KEY_DOWN, false, false, false, false);
                expect.that(v.cursorRow()).is(1);
            });
        });
    }
}
