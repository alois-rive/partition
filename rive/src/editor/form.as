// Forms drawn by script (the settings and samples tabs): painting that can
// also run without a renderer, so the controls' places are known before the
// first frame, and the controls those forms share.

import { Renderer } from "rive/renderer";
import { Text } from "rive/text";
import { EditorView } from "./view";

export const CONTROL_H: f64 = 26;
export const SECTION_H: f64 = 44;

// A clickable area drawn this frame.
export class Hit {
    constructor(public x: f64, public y: f64, public w: f64, public h: f64, public id: string) {}
}

export class Form {
    hits: Array<Hit> = [];
    hover: string = "";
    clock: f64 = 0;
    renderer: Renderer? = null; // set while painting

    hitAt(x: f64, y: f64): string {
        for (let i = this.hits.length - 1; i >= 0; i--) {
            let h = this.hits[i];
            if (x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h) return h.id;
        }
        return "";
    }

    hitOf(id: string): Hit? {
        for (let i = 0; i < this.hits.length; i++) if (this.hits[i].id == id) return this.hits[i];
        return null;
    }

    textWidth(t: Text?): f64 {
        if (t == null) return 0;
        let b = t.bounds();
        return <f64>(b.v1.x - b.v0.x);
    }

    rect(ui: EditorView, x: f64, y: f64, w: f64, h: f64, color: u32): void {
        let r = this.renderer;
        if (r != null) ui.rect(r, x, y, w, h, color);
    }

    text(ui: EditorView, t: Text?, x: f64, y: f64): void {
        let r = this.renderer;
        if (r != null) ui.drawText(r, t, x, y);
    }

    line(ui: EditorView, x1: f64, y1: f64, x2: f64, y2: f64, width: f64, color: u32): void {
        let r = this.renderer;
        if (r != null) ui.line(r, x1, y1, x2, y2, width, color);
    }

    dot(ui: EditorView, x: f64, y: f64, radius: f64, color: u32, hollow: bool): void {
        let r = this.renderer;
        if (r != null) ui.dot(r, x, y, radius, color, hollow);
    }

    clip(ui: EditorView, x: f64, y: f64, w: f64, h: f64): void {
        let r = this.renderer;
        if (r != null) ui.clipRect(r, x, y, w, h);
    }

    save(): void {
        let r = this.renderer;
        if (r != null) r.save();
    }

    restore(): void {
        let r = this.renderer;
        if (r != null) r.restore();
    }

    section(ui: EditorView, title: string, x: f64, y: f64, w: f64): f64 {
        this.text(ui, ui.labelIn(title, ui.headingStyle, "sx:"), x, y + 12);
        this.rect(ui, x, y + SECTION_H - 8, w, 1, ui.colors.divider);
        return y + SECTION_H;
    }

    label(ui: EditorView, name: string, hint: string, x: f64, y: f64): void {
        this.text(ui, ui.labelIn(name, ui.boldStyle, "n1:"), x, y + 4);
        if (hint.length > 0) this.text(ui, ui.labelIn(hint, ui.hintStyle, "sh:"), x, y + 26);
    }

    button(ui: EditorView, id: string, label: string, x: f64, y: f64, w: f64, on: bool): void {
        let k = ui.colors;
        let hover = this.hover == id;
        this.rect(ui, x, y, w, CONTROL_H, on ? k.edge : hover ? k.edge : k.divider);
        this.rect(ui, x + 1, y + 1, w - 2, CONTROL_H - 2, on ? 0xFF222222 : hover ? 0xFF1A1A1A : k.control);
        let t = ui.labelIn(label, on ? ui.boldStyle : ui.nameStyle, on ? "n1:" : "n0:");
        this.text(ui, t, x + (w - this.textWidth(t)) * 0.5, y + 4);
        this.hits.push(new Hit(x, y, w, CONTROL_H, id));
    }
}
