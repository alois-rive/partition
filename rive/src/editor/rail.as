// The tab rail (docs/spec.md §10.9): a narrow column of icons on the left
// edge, one per tab (tracks, patterns, instruments, and settings at the
// bottom). Hovering an icon for a moment shows its name and shortcut.

import { Renderer } from "rive/renderer";
import { EditorView } from "./view";

export const RAIL_WIDTH: f64 = 44;
export const HINT_DELAY: f64 = 0.6; // seconds of hovering before the hint shows

const ITEM: f64 = 32;
const TOP: f64 = 8;
const GAP: f64 = 8;
export const SETTINGS_TAB: i32 = 3;

export class Rail {
    tab: i32 = 0;
    hover: i32 = -1;
    hoverSince: f64 = 0;
    clock: f64 = 0;
    names: Array<string> = ["Tracks", "Patterns", "Instruments", "Song settings"];
    keys: Array<string> = ["Cmd+1", "Cmd+2", "Cmd+3", "Cmd+,"];
    height: f64 = 600; // the rail's height, for the item pinned to the bottom

    itemY(i: i32): f64 {
        if (i == SETTINGS_TAB) return Math.max(this.height - TOP - ITEM, TOP + <f64>i * (ITEM + GAP));
        return TOP + <f64>i * (ITEM + GAP);
    }

    // The tab under a point, or -1.
    hit(x: f64, y: f64): i32 {
        if (x < 0 || x >= RAIL_WIDTH) return -1;
        for (let i = 0; i < this.names.length; i++) {
            let iy = this.itemY(i);
            if (y >= iy && y < iy + ITEM) return i;
        }
        return -1;
    }

    advance(seconds: f64): void {
        this.clock += seconds;
    }

    pointerMove(x: f64, y: f64): void {
        let i = this.hit(x, y);
        if (i != this.hover) {
            this.hover = i;
            this.hoverSince = this.clock;
        }
    }

    pointerExit(): void {
        this.hover = -1;
    }

    get hintShown(): bool {
        return this.hover >= 0 && this.clock - this.hoverSince >= HINT_DELAY;
    }

    draw(renderer: Renderer, ui: EditorView, height: f64): void {
        this.height = height;
        let k = ui.colors;
        ui.rect(renderer, 0, 0, RAIL_WIDTH, height, k.header);
        ui.rect(renderer, RAIL_WIDTH - 1, 0, 1, height, k.divider);
        for (let i = 0; i < this.names.length; i++) {
            let y = this.itemY(i);
            let x = (RAIL_WIDTH - ITEM) * 0.5;
            let selected = i == this.tab;
            if (selected) {
                ui.rect(renderer, x, y, ITEM, ITEM, 0xFF222222);
                ui.rect(renderer, 0, y + 4, 2, ITEM - 8, k.white);
            } else if (i == this.hover) {
                ui.rect(renderer, x, y, ITEM, ITEM, k.control);
            }
            let ink = selected ? k.white : i == this.hover ? k.secondary : k.subdued;
            this.icon(renderer, ui, i, x + ITEM * 0.5, y + ITEM * 0.5, ink);
        }
    }

    // The hint for the hovered icon, drawn last so it sits over the content.
    drawHint(renderer: Renderer, ui: EditorView): void {
        if (!this.hintShown) return;
        let k = ui.colors;
        let label = `${this.names[this.hover]}   ${this.keys[this.hover]}`;
        let t = ui.labelIn(label, ui.nameStyle, "n0:");
        if (t == null) return;
        let b = t.bounds();
        let w = <f64>(b.v1.x - b.v0.x) + 16;
        let x = RAIL_WIDTH + 4;
        let y = this.itemY(this.hover) + (ITEM - 24) * 0.5;
        ui.rect(renderer, x, y, w, 24, k.edge);
        ui.rect(renderer, x + 1, y + 1, w - 2, 22, 0xFF222222);
        ui.drawText(renderer, t, x + 8, y + 4);
    }

    // 16 px icons drawn with the view's primitives.
    icon(renderer: Renderer, ui: EditorView, i: i32, cx: f64, cy: f64, ink: u32): void {
        if (i == 0) {
            // Tracks: three lanes with note marks.
            for (let k = -1; k <= 1; k++) {
                let x = cx + <f64>k * 5;
                ui.line(renderer, x, cy - 7, x, cy + 7, 1.4, ink);
                ui.dot(renderer, x, cy - 3 + <f64>k * 3, 1.8, ink, false);
            }
        } else if (i == 1) {
            // Patterns: a repeated block, a bracket over two cells.
            ui.rect(renderer, cx - 7, cy - 7, 6, 6, ink);
            ui.rect(renderer, cx + 1, cy - 7, 6, 6, ink);
            ui.rect(renderer, cx - 7, cy + 1, 6, 6, ink);
            ui.rect(renderer, cx + 1, cy + 1, 6, 6, ink);
            ui.rect(renderer, cx - 6, cy - 6, 4, 4, 0xFF0A0A0A);
            ui.rect(renderer, cx + 2, cy + 2, 4, 4, 0xFF0A0A0A);
        } else if (i == 2) {
            // Instruments: one cycle of a wave inside a box.
            ui.line(renderer, cx - 8, cy, cx - 4, cy - 5, 1.4, ink);
            ui.line(renderer, cx - 4, cy - 5, cx, cy, 1.4, ink);
            ui.line(renderer, cx, cy, cx + 4, cy + 5, 1.4, ink);
            ui.line(renderer, cx + 4, cy + 5, cx + 8, cy, 1.4, ink);
            ui.line(renderer, cx - 8, cy + 8, cx + 8, cy + 8, 1.2, ink);
        } else {
            // Settings: a cog, a ring with eight teeth.
            for (let t = 0; t < 8; t++) {
                let a = <f64>t * Math.PI / 4;
                let c = Math.cos(a);
                let s = Math.sin(a);
                ui.line(renderer, cx + c * 5.5, cy + s * 5.5, cx + c * 8, cy + s * 8, 2.2, ink);
            }
            ui.dot(renderer, cx, cy, 5.5, ink, true);
            ui.dot(renderer, cx, cy, 2, ink, false);
        }
    }
}
