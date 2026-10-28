// The file list of the patterns and instruments tabs (docs/spec.md §10.9):
// one row per file, with add, rename (inline) and delete. It reports what the
// user did as actions; the app changes the song.

import { Renderer } from "rive/renderer";
import { EditorView, KEY_BACKSPACE, KEY_DOWN, KEY_ENTER, KEY_ESCAPE, KEY_UP } from "./view";

export const LIST_WIDTH: f64 = 200;
export const LIST_HEADER: f64 = 28;
export const LIST_ROW: f64 = 26;
export const CONFIRM_TIME: f64 = 3; // seconds a delete waits for its second click

export class FileList {
    names: Array<string> = [];
    details: Array<string> = []; // a few words per file ("16 rows", "base pad")
    selected: string = "";
    hover: i32 = -1;
    renaming: i32 = -1;
    buffer: string = "";
    confirming: i32 = -1; // the row whose delete waits for a second click
    confirmUntil: f64 = 0;
    clock: f64 = 0;
    lastClick: f64 = -1;
    lastClickRow: i32 = -1;
    actions: Array<string> = [];

    constructor(public title: string, public noun: string) {}

    takeActions(): Array<string> {
        let out = this.actions;
        this.actions = [];
        return out;
    }

    get selectedIndex(): i32 {
        return this.names.indexOf(this.selected);
    }

    rowY(i: i32): f64 {
        return LIST_HEADER + 4 + <f64>i * LIST_ROW;
    }

    rowAt(y: f64): i32 {
        if (y < LIST_HEADER + 4) return -1;
        let i = <i32>Math.floor((y - LIST_HEADER - 4) / LIST_ROW);
        return i >= 0 && i < this.names.length ? i : -1;
    }

    advance(seconds: f64): void {
        this.clock += seconds;
        if (this.confirming >= 0 && this.clock > this.confirmUntil) this.confirming = -1;
    }

    // Starts renaming row `i` in place.
    startRename(i: i32): void {
        if (i < 0 || i >= this.names.length) return;
        this.renaming = i;
        this.buffer = this.names[i];
        this.confirming = -1;
    }

    commitRename(): void {
        let i = this.renaming;
        this.renaming = -1;
        if (i < 0 || i >= this.names.length) return;
        if (this.buffer.length > 0 && this.buffer != this.names[i]) this.actions.push(`rename:${this.names[i]}:${this.buffer}`);
    }

    // --- Input (coordinates relative to the list's left edge) ----------------------

    pointerMove(x: f64, y: f64): void {
        this.hover = x >= 0 && x < LIST_WIDTH ? this.rowAt(y) : -1;
    }

    pointerDown(x: f64, y: f64): void {
        if (y < LIST_HEADER) {
            if (x > LIST_WIDTH - 30) this.actions.push("add");
            return;
        }
        let i = this.rowAt(y);
        if (this.renaming >= 0 && i != this.renaming) this.commitRename();
        if (i < 0) return;
        if (x > LIST_WIDTH - 26) {
            // Delete: a second click within a few seconds confirms.
            if (this.confirming == i) {
                this.confirming = -1;
                this.actions.push(`delete:${this.names[i]}`);
            } else {
                this.confirming = i;
                this.confirmUntil = this.clock + CONFIRM_TIME;
            }
            return;
        }
        if (x > LIST_WIDTH - 48) {
            this.startRename(i);
            return;
        }
        // A double-click renames too.
        if (this.lastClickRow == i && this.clock - this.lastClick < 0.35) {
            this.startRename(i);
            return;
        }
        this.lastClick = this.clock;
        this.lastClickRow = i;
        this.confirming = -1;
        if (this.renaming != i) this.actions.push(`select:${this.names[i]}`);
    }

    // Keys while renaming (true when taken). F2 renames the selected file.
    key(key: i32): bool {
        if (this.renaming < 0) {
            if (key == 291) { // F2
                this.startRename(this.selectedIndex);
                return true;
            }
            return false;
        }
        if (key == KEY_ENTER) this.commitRename();
        else if (key == KEY_ESCAPE) this.renaming = -1;
        else if (key == KEY_BACKSPACE) this.buffer = this.buffer.substring(0, max<i32>(this.buffer.length - 1, 0));
        else if (key == KEY_UP || key == KEY_DOWN) return true;
        return true;
    }

    // Typed text while renaming: names keep to lowercase letters, digits and '_'.
    typeText(text: string): bool {
        if (this.renaming < 0) return false;
        for (let i = 0; i < text.length; i++) {
            let c = text.charCodeAt(i);
            if (c >= 65 && c <= 90) c += 32;
            if (c == 45 || c == 32) c = 95;
            let ok = (c >= 97 && c <= 122) || c == 95 || (this.buffer.length > 0 && c >= 48 && c <= 57);
            if (ok) this.buffer += String.fromCharCode(c);
        }
        return true;
    }

    // --- Drawing ---------------------------------------------------------------------

    draw(renderer: Renderer, ui: EditorView, x0: f64, height: f64): void {
        let k = ui.colors;
        ui.rect(renderer, x0, 0, LIST_WIDTH, height, 0xFF050505);
        ui.rect(renderer, x0 + LIST_WIDTH - 1, 0, 1, height, k.divider);
        // Header: the title and an add button.
        ui.rect(renderer, x0, 0, LIST_WIDTH, LIST_HEADER, k.header);
        ui.rect(renderer, x0, LIST_HEADER - 1, LIST_WIDTH, 1, k.divider);
        ui.drawText(renderer, ui.labelIn(this.title, ui.boldStyle, "n1:"), x0 + 12, (LIST_HEADER - 16) * 0.5);
        let ax = x0 + LIST_WIDTH - 18;
        let ay = LIST_HEADER * 0.5;
        ui.rect(renderer, ax - 9, ay - 9, 18, 18, k.divider);
        ui.rect(renderer, ax - 8, ay - 8, 16, 16, k.control);
        ui.line(renderer, ax - 4, ay, ax + 4, ay, 1.3, k.white);
        ui.line(renderer, ax, ay - 4, ax, ay + 4, 1.3, k.white);
        if (this.names.length == 0) {
            ui.drawText(renderer, ui.labelIn(`No ${this.noun}s yet`, ui.nameStyle, "n0:"), x0 + 12, LIST_HEADER + 12);
        }
        for (let i = 0; i < this.names.length; i++) {
            let y = this.rowY(i);
            if (y > height) break;
            let selected = this.names[i] == this.selected;
            if (selected) {
                ui.rect(renderer, x0 + 4, y, LIST_WIDTH - 9, LIST_ROW - 2, 0xFF222222);
                ui.rect(renderer, x0 + 4, y + 4, 2, LIST_ROW - 10, k.white);
            } else if (i == this.hover) {
                ui.rect(renderer, x0 + 4, y, LIST_WIDTH - 9, LIST_ROW - 2, k.control);
            }
            let ty = y + (LIST_ROW - 2 - 16) * 0.5;
            if (i == this.renaming) {
                // An inline field with a caret.
                ui.rect(renderer, x0 + 10, y + 2, LIST_WIDTH - 20, LIST_ROW - 6, k.edge);
                ui.rect(renderer, x0 + 11, y + 3, LIST_WIDTH - 22, LIST_ROW - 8, 0xFF000000);
                let t = ui.labelIn(this.buffer, ui.boldStyle, "n1:");
                ui.drawText(renderer, t, x0 + 16, ty);
                if (t != null && ((this.clock % 1.0) < 0.6)) {
                    let b = t.bounds();
                    let cx = x0 + 16 + (this.buffer.length > 0 ? <f64>(b.v1.x - b.v0.x) : 0) + 1;
                    ui.rect(renderer, cx, y + 6, 1.5, LIST_ROW - 14, k.white);
                }
                continue;
            }
            if (i == this.confirming) {
                ui.drawText(renderer, ui.labelIn(`Delete ${this.names[i]}?`, ui.boldStyle, "n1:"), x0 + 14, ty);
            } else {
                ui.drawText(renderer, ui.labelIn(this.names[i], selected ? ui.boldStyle : ui.nameStyle, selected ? "n1:" : "n0:"), x0 + 14, ty);
                if (i < this.details.length && i != this.hover) {
                    let d = ui.labelIn(this.details[i], ui.labelStyle, "r:");
                    if (d != null) {
                        let b = d.bounds();
                        ui.drawText(renderer, d, x0 + LIST_WIDTH - 14 - <f64>(b.v1.x - b.v0.x), ty + 3);
                    }
                }
            }
            if (i == this.hover || i == this.confirming) {
                // Rename (a pencil) and delete (a cross).
                let rx = x0 + LIST_WIDTH - 38;
                let cy = y + (LIST_ROW - 2) * 0.5;
                ui.line(renderer, rx - 4, cy + 4, rx + 4, cy - 4, 1.4, k.secondary);
                ui.line(renderer, rx - 5, cy + 5, rx - 3, cy + 5, 1.4, k.secondary);
                let dx = x0 + LIST_WIDTH - 16;
                let ink = i == this.confirming ? k.error : k.secondary;
                ui.line(renderer, dx - 4, cy - 4, dx + 4, cy + 4, 1.4, ink);
                ui.line(renderer, dx - 4, cy + 4, dx + 4, cy - 4, 1.4, ink);
            }
        }
    }
}
