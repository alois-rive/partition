import { Tests } from "rive/test";
import { REF_INSTRUMENT, REF_PATTERN, REF_SAMPLE, renameReferences } from "../lang/rename";
import { FileList, LIST_HEADER, LIST_ROW, LIST_WIDTH } from "../editor/filelist";
import { Rail, RAIL_WIDTH, HINT_DELAY } from "../editor/rail";
import { KEY_ENTER, KEY_ESCAPE, KEY_BACKSPACE } from "../editor/view";
import { docBlocks } from "../editor/docs";

@editTime
function listOf(names: Array<string>): FileList {
    let list = new FileList("Patterns", "pattern");
    list.names = names;
    list.selected = names.length > 0 ? names[0] : "";
    return list;
}

@editTime
function rowCenter(i: i32): f64 {
    return LIST_HEADER + 4 + <f64>i * LIST_ROW + LIST_ROW * 0.5;
}

export class FilesTests extends Tests {
    override run(): void {
        group("rename references", () => {
            test("a pattern's calls change, nothing else does", (expect) => {
                let text = "pattern(name: four, times: 4); inst(name: four)\n\tpattern(name: fourth)\nnote(p: C4)\n";
                expect.that(renameReferences(text, "four", "kick", REF_PATTERN)).is("pattern(name: kick, times: 4); inst(name: four)\n\tpattern(name: fourth)\nnote(p: C4)\n");
            });
            test("an instrument's selections and overrides change", (expect) => {
                let text = "inst(name: pad); note(p: C4, inst: pad)\npattern(name: pad)\n";
                expect.that(renameReferences(text, "pad", "warm_pad", REF_INSTRUMENT)).is("inst(name: warm_pad); note(p: C4, inst: warm_pad)\npattern(name: pad)\n");
            });
            test("text without references is returned as is", (expect) => {
                let text = "note(p: C4)\n\n";
                expect.that(renameReferences(text, "x", "y", REF_PATTERN)).is(text);
            });
            test("a sample's references change in instruments", (expect) => {
                let text = "sample(file: kick, key: C2)\nbase(preset: kick)\nsample(file: kick_2)\n";
                expect.that(renameReferences(text, "kick", "bd", REF_SAMPLE)).is("sample(file: bd, key: C2)\nbase(preset: kick)\nsample(file: kick_2)\n");
            });
        });

        group("file list", () => {
            test("clicking a row selects it; the header button adds", (expect) => {
                let list = listOf(["a", "b"]);
                list.pointerDown(40, rowCenter(1));
                list.pointerDown(LIST_WIDTH - 10, LIST_HEADER * 0.5);
                let actions = list.takeActions();
                expect.that(actions.join("|")).is("select:b|add");
                expect.that(list.takeActions().length).is(0);
            });
            test("delete waits for a second click, and times out", (expect) => {
                let list = listOf(["a", "b"]);
                list.pointerDown(LIST_WIDTH - 10, rowCenter(0));
                expect.that(list.confirming).is(0);
                expect.that(list.takeActions().length).is(0);
                list.advance(5);
                expect.that(list.confirming).is(-1);
                list.pointerDown(LIST_WIDTH - 10, rowCenter(0));
                list.pointerDown(LIST_WIDTH - 10, rowCenter(0));
                expect.that(list.takeActions().join("|")).is("delete:a");
            });
            test("renaming edits a name in place", (expect) => {
                let list = listOf(["a", "b"]);
                expect.that(list.key(291)).is(true); // F2 renames the selected row
                expect.that(list.renaming).is(0);
                list.key(KEY_BACKSPACE);
                list.typeText("Big Kick-2!");
                expect.that(list.buffer).is("big_kick_2");
                list.key(KEY_ENTER);
                expect.that(list.renaming).is(-1);
                expect.that(list.takeActions().join("|")).is("rename:a:big_kick_2");
            });
            test("names start with a letter; escape cancels", (expect) => {
                let list = listOf(["a"]);
                list.startRename(0);
                list.buffer = "";
                list.typeText("9x");
                expect.that(list.buffer).is("x");
                list.key(KEY_ESCAPE);
                expect.that(list.takeActions().length).is(0);
                expect.that(list.key(KEY_ENTER)).is(false);
            });
            test("a double-click renames; the pencil does too", (expect) => {
                let list = listOf(["a", "b"]);
                list.pointerDown(40, rowCenter(1));
                list.advance(0.1);
                list.pointerDown(40, rowCenter(1));
                expect.that(list.renaming).is(1);
                list.pointerDown(40, rowCenter(0)); // a click elsewhere commits
                expect.that(list.renaming).is(-1);
                list.pointerDown(LIST_WIDTH - 38, rowCenter(0));
                expect.that(list.renaming).is(0);
            });
        });

        group("rail", () => {
            test("icons pick tabs; a long hover shows the hint", (expect) => {
                let rail = new Rail();
                let y = rail.itemY(2) + 4;
                expect.that(rail.hit(RAIL_WIDTH * 0.5, y)).is(2);
                expect.that(rail.hit(RAIL_WIDTH + 2, y)).is(-1);
                rail.pointerMove(RAIL_WIDTH * 0.5, y);
                expect.that(rail.hintShown).is(false);
                rail.advance(HINT_DELAY + 0.01);
                expect.that(rail.hintShown).is(true);
                rail.pointerExit();
                expect.that(rail.hintShown).is(false);
            });
        });

        group("file docs", () => {
            test("the docs have pattern and instrument sections to open at", (expect) => {
                let blocks = docBlocks();
                let anchors = new Array<string>();
                for (let i = 0; i < blocks.length; i++) anchors.push(blocks[i].anchor);
                expect.that(anchors.includes("patterns")).is(true);
                expect.that(anchors.includes("instruments")).is(true);
            });
        });
    }
}
