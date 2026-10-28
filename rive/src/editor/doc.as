// One editable file: its lines, a cursor and selection, and undo history
// (docs/spec.md §10.4).

import { splitLines } from "../lang/source";

export class Pos {
    constructor(public line: i32, public ch: i32) {}

    clone(): Pos {
        return new Pos(this.line, this.ch);
    }

    equals(o: Pos): bool {
        return this.line == o.line && this.ch == o.ch;
    }

    before(o: Pos): bool {
        return this.line < o.line || (this.line == o.line && this.ch < o.ch);
    }
}

class Snapshot {
    constructor(public text: string, public cursor: Pos, public anchor: Pos) {}
}

export const UNDO_LIMIT: i32 = 200;
// Typing merges into one undo step until a pause this long (seconds).
export const UNDO_MERGE: f64 = 1.0;

export class Doc {
    lines: Array<string> = [""];
    cursor: Pos = new Pos(0, 0);
    anchor: Pos = new Pos(0, 0); // the other end of the selection; equal to cursor when none
    revision: i32 = 0;
    undoStack: Array<Snapshot> = [];
    redoStack: Array<Snapshot> = [];
    lastEditKind: string = "";
    lastEditTime: f64 = -1000;
    clock: f64 = 0; // seconds, advanced by the view
    // The column the cursor wants when moving vertically through shorter lines.
    goalCh: i32 = -1;
    // Keep empty lines at the end: a pattern's trailing rests set its length.
    keepTrailing: bool = false;

    constructor(public path: string, text: string) {
        this.setText(text);
    }

    setText(text: string): void {
        let lines = splitLines(text);
        if (lines.length == 0) lines.push("");
        this.lines = lines;
        this.clamp();
        this.revision++;
    }

    // The file's text with a final newline. Unless `keepTrailing` is set,
    // empty lines after the last one with text are dropped: in a channel they
    // play nothing (rows padded by clicking below the end come and go with them).
    text(): string {
        if (this.keepTrailing) {
            if (this.lines.length == 1 && this.lines[0].length == 0) return "";
            return this.lines.join("\n") + "\n";
        }
        let n = this.lines.length;
        while (n > 0 && this.lines[n - 1].length == 0) n--;
        if (n == 0) return "";
        return this.lines.slice(0, n).join("\n") + "\n";
    }

    get hasSelection(): bool {
        return !this.cursor.equals(this.anchor);
    }

    selStart(): Pos {
        return this.cursor.before(this.anchor) ? this.cursor : this.anchor;
    }

    selEnd(): Pos {
        return this.cursor.before(this.anchor) ? this.anchor : this.cursor;
    }

    clamp(): void {
        this.cursor = this.clampPos(this.cursor);
        this.anchor = this.clampPos(this.anchor);
    }

    clampPos(p: Pos): Pos {
        let line = min<i32>(max<i32>(p.line, 0), this.lines.length - 1);
        let ch = min<i32>(max<i32>(p.ch, 0), this.lines[line].length);
        return new Pos(line, ch);
    }

    selectedText(): string {
        if (!this.hasSelection) return "";
        let a = this.selStart();
        let b = this.selEnd();
        if (a.line == b.line) return this.lines[a.line].substring(a.ch, b.ch);
        let out = this.lines[a.line].substring(a.ch);
        for (let i = a.line + 1; i < b.line; i++) out += "\n" + this.lines[i];
        return out + "\n" + this.lines[b.line].substring(0, b.ch);
    }

    // --- Undo ---------------------------------------------------------------

    // Records the state before an edit of `kind`; consecutive edits of the same
    // kind close together merge into one step.
    checkpoint(kind: string): void {
        let merge = kind == this.lastEditKind && kind != "" && this.clock - this.lastEditTime < UNDO_MERGE;
        if (!merge) {
            this.undoStack.push(new Snapshot(this.lines.join("\n"), this.cursor.clone(), this.anchor.clone()));
            if (this.undoStack.length > UNDO_LIMIT) this.undoStack.shift();
        }
        this.redoStack = [];
        this.lastEditKind = kind;
        this.lastEditTime = this.clock;
    }

    // Breaks the current merge, so the next edit starts a new undo step.
    breakUndo(): void {
        this.lastEditKind = "";
    }

    undo(): bool {
        if (this.undoStack.length == 0) return false;
        this.redoStack.push(new Snapshot(this.lines.join("\n"), this.cursor.clone(), this.anchor.clone()));
        this.restore(this.undoStack.pop());
        return true;
    }

    redo(): bool {
        if (this.redoStack.length == 0) return false;
        this.undoStack.push(new Snapshot(this.lines.join("\n"), this.cursor.clone(), this.anchor.clone()));
        this.restore(this.redoStack.pop());
        return true;
    }

    restore(s: Snapshot): void {
        this.lines = s.text.split("\n");
        this.cursor = s.cursor;
        this.anchor = s.anchor;
        this.clamp();
        this.revision++;
        this.lastEditKind = "";
    }

    // Replaces the whole text as one undo step (an outside change, §11.6).
    replaceAll(text: string): void {
        this.checkpoint("");
        let cursor = this.cursor.clone();
        this.setText(text);
        this.cursor = this.clampPos(cursor);
        this.anchor = this.cursor.clone();
    }

    // --- Edits ----------------------------------------------------------------

    // Deletes the selection, if any; true when there was one.
    deleteSelection(): bool {
        if (!this.hasSelection) return false;
        let a = this.selStart();
        let b = this.selEnd();
        let head = this.lines[a.line].substring(0, a.ch);
        let tail = this.lines[b.line].substring(b.ch);
        this.lines = spliceLines(this.lines, a.line, b.line - a.line + 1, [head + tail]);
        this.cursor = a.clone();
        this.anchor = a.clone();
        this.revision++;
        return true;
    }

    // Inserts `text` (which may hold newlines) at the cursor, replacing the selection.
    insert(text: string, kind: string = "type"): void {
        this.checkpoint(kind);
        this.deleteSelection();
        let parts = text.split("\n");
        let p = this.cursor;
        let line = this.lines[p.line];
        let head = line.substring(0, p.ch);
        let tail = line.substring(p.ch);
        if (parts.length == 1) {
            this.lines[p.line] = head + text + tail;
            this.cursor = new Pos(p.line, p.ch + text.length);
        } else {
            let replacement = new Array<string>();
            replacement.push(head + parts[0]);
            for (let i = 1; i < parts.length - 1; i++) replacement.push(parts[i]);
            let last = parts[parts.length - 1];
            replacement.push(last + tail);
            this.lines = spliceLines(this.lines, p.line, 1, replacement);
            this.cursor = new Pos(p.line + parts.length - 1, last.length);
        }
        this.anchor = this.cursor.clone();
        this.goalCh = -1;
        this.revision++;
    }

    backspace(): void {
        this.checkpoint("delete");
        if (this.deleteSelection()) return;
        let p = this.cursor;
        if (p.ch > 0) {
            let line = this.lines[p.line];
            this.lines[p.line] = line.substring(0, p.ch - 1) + line.substring(p.ch);
            this.cursor = new Pos(p.line, p.ch - 1);
        } else if (p.line > 0) {
            let prev = this.lines[p.line - 1];
            this.lines[p.line - 1] = prev + this.lines[p.line];
            this.lines.splice(p.line, 1);
            this.cursor = new Pos(p.line - 1, prev.length);
        }
        this.anchor = this.cursor.clone();
        this.goalCh = -1;
        this.revision++;
    }

    deleteForward(): void {
        this.checkpoint("delete");
        if (this.deleteSelection()) return;
        let p = this.cursor;
        let line = this.lines[p.line];
        if (p.ch < line.length) {
            this.lines[p.line] = line.substring(0, p.ch) + line.substring(p.ch + 1);
        } else if (p.line < this.lines.length - 1) {
            this.lines[p.line] = line + this.lines[p.line + 1];
            this.lines.splice(p.line + 1, 1);
        }
        this.revision++;
    }

    // The block of a row: its line and the continuation lines under it.
    rowBlock(line: i32): Array<i32> {
        let start = line;
        while (start > 0 && this.isContinuation(start)) start--;
        let end = start + 1;
        while (end < this.lines.length && this.isContinuation(end)) end++;
        return [start, end];
    }

    isContinuation(line: i32): bool {
        let text = this.lines[line];
        return text.length > 0 && text.charCodeAt(0) == 9;
    }

    // Duplicates the cursor's row (with its continuation lines) below it.
    duplicateRow(): void {
        this.checkpoint("");
        let b = this.rowBlock(this.cursor.line);
        let copy = this.lines.slice(b[0], b[1]);
        this.lines = spliceLines(this.lines, b[1], 0, copy);
        this.cursor = new Pos(this.cursor.line + copy.length, this.cursor.ch);
        this.anchor = this.cursor.clone();
        this.revision++;
    }

    // Moves the cursor's row (with its continuation lines) up or down one row.
    moveRow(direction: i32): void {
        let b = this.rowBlock(this.cursor.line);
        if (direction < 0) {
            if (b[0] == 0) return;
            let prev = this.rowBlock(b[0] - 1);
            this.checkpoint("");
            let block = this.lines.slice(b[0], b[1]);
            this.lines = spliceLines(this.lines, b[0], b[1] - b[0], []);
            this.lines = spliceLines(this.lines, prev[0], 0, block);
            let shift = b[0] - prev[0];
            this.cursor = new Pos(this.cursor.line - shift, this.cursor.ch);
        } else {
            if (b[1] >= this.lines.length) return;
            let next = this.rowBlock(b[1]);
            this.checkpoint("");
            let after = this.lines.slice(next[0], next[1]);
            this.lines = spliceLines(this.lines, next[0], next[1] - next[0], []);
            this.lines = spliceLines(this.lines, b[0], 0, after);
            this.cursor = new Pos(this.cursor.line + after.length, this.cursor.ch);
        }
        this.anchor = this.cursor.clone();
        this.revision++;
    }

    // Makes sure line `line` exists, padding with empty lines (typing below the end).
    ensureLine(line: i32): void {
        while (this.lines.length <= line) this.lines.push("");
    }

    // --- Movement -------------------------------------------------------------

    moveTo(p: Pos, extend: bool): void {
        this.cursor = this.clampPos(p);
        if (!extend) this.anchor = this.cursor.clone();
        this.breakUndo();
    }

    left(extend: bool): void {
        if (!extend && this.hasSelection) {
            this.moveTo(this.selStart(), false);
            return;
        }
        let p = this.cursor;
        if (p.ch > 0) this.moveTo(new Pos(p.line, p.ch - 1), extend);
        else if (p.line > 0) this.moveTo(new Pos(p.line - 1, this.lines[p.line - 1].length), extend);
        this.goalCh = -1;
    }

    right(extend: bool): void {
        if (!extend && this.hasSelection) {
            this.moveTo(this.selEnd(), false);
            return;
        }
        let p = this.cursor;
        if (p.ch < this.lines[p.line].length) this.moveTo(new Pos(p.line, p.ch + 1), extend);
        else if (p.line < this.lines.length - 1) this.moveTo(new Pos(p.line + 1, 0), extend);
        this.goalCh = -1;
    }

    vertical(delta: i32, extend: bool): void {
        if (this.goalCh < 0) this.goalCh = this.cursor.ch;
        let goal = this.goalCh;
        let line = min<i32>(max<i32>(this.cursor.line + delta, 0), this.lines.length - 1);
        this.moveTo(new Pos(line, goal), extend);
        this.goalCh = goal;
    }

    home(extend: bool): void {
        // Toggle between the first non-blank character and column 0.
        let text = this.lines[this.cursor.line];
        let first = 0;
        while (first < text.length && (text.charCodeAt(first) == 32 || text.charCodeAt(first) == 9)) first++;
        this.moveTo(new Pos(this.cursor.line, this.cursor.ch == first ? 0 : first), extend);
        this.goalCh = -1;
    }

    end(extend: bool): void {
        this.moveTo(new Pos(this.cursor.line, this.lines[this.cursor.line].length), extend);
        this.goalCh = -1;
    }

    selectAll(): void {
        this.anchor = new Pos(0, 0);
        let last = this.lines.length - 1;
        this.cursor = new Pos(last, this.lines[last].length);
    }

    // Selects the word around `p` (double-click).
    selectWord(p: Pos): void {
        let text = this.lines[p.line];
        let a = min<i32>(p.ch, text.length);
        let b = a;
        while (a > 0 && isWordChar(text.charCodeAt(a - 1))) a--;
        while (b < text.length && isWordChar(text.charCodeAt(b))) b++;
        this.anchor = new Pos(p.line, a);
        this.cursor = new Pos(p.line, b);
    }
}

// `lines` with `count` lines from `start` replaced by `items`.
export function spliceLines(lines: Array<string>, start: i32, count: i32, items: Array<string>): Array<string> {
    let out = new Array<string>();
    for (let i = 0; i < start; i++) out.push(lines[i]);
    for (let i = 0; i < items.length; i++) out.push(items[i]);
    for (let i = start + count; i < lines.length; i++) out.push(lines[i]);
    return out;
}

export function isWordChar(c: i32): bool {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 35 || c == 46;
}
