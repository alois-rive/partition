// The samples tab (docs/spec.md §10.11): the selected sample's waveform, with
// a selection the edits apply to, how to play it from an instrument and which
// instruments do; and the form that adds samples, by importing files (through
// the shell) or by recording a note of an instrument. It reports what the user
// asks for as actions; the app changes the song.

import { Renderer } from "rive/renderer";
import { SampleData } from "../synth/samples";
import { CONTROL_H, Form, Hit } from "./form";
import { EditorView, KEY_BACKSPACE, KEY_DELETE, KEY_ENTER, KEY_ESCAPE, KEY_TAB } from "./view";

export const PANEL_PAD: f64 = 28;
const PANEL_WIDTH: f64 = 920;
const WAVE_H: f64 = 200;
const EDIT_W: f64 = 84;
const NAMES: StaticArray<string> = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

export function noteName(midi: i32): string {
    return `${NAMES[((midi % 12) + 12) % 12]}${midi / 12 - 1}`;
}

// The edits the buttons offer, in order: [action, label].
const EDITS: StaticArray<string> = [
    "trim", "Trim", "cut", "Cut", "normalize", "Normalize", "reverse", "Reverse",
    "fadein", "Fade in", "fadeout", "Fade out", "gain-", "-3 dB", "gain+", "+3 dB",
];

// An instrument that plays the sample, and the line that does.
export class Usage {
    constructor(public instrument: string, public line: string) {}
}

function seconds(v: f64): string {
    let r = Math.round(v * 1000) / 1000;
    return `${r} s`;
}

export class SamplePanel extends Form {
    name: string = ""; // the sample shown; "" shows the form that adds one
    adding: bool = false; // the form, while a sample is selected
    data: SampleData? = null;
    usages: Array<Usage> = [];
    hosted: bool = false; // a shell can import files
    canUndo: bool = false;
    playing: bool = false;
    playhead: f64 = -1; // in frames, while the sample plays
    status: string = "";
    actions: Array<string> = [];
    scrollY: f64 = 0;
    contentH: f64 = 0;
    viewH: f64 = 600;

    // Selection, in frames: [selA, selB), or none when selB <= selA.
    selA: f64 = 0;
    selB: f64 = 0;
    dragging: bool = false;
    dragFrom: f64 = 0;
    waveX: f64 = 0;
    waveY: f64 = 0;
    waveW: f64 = 1;

    // The waveform, one min and max per column.
    peaksFor: SampleData? = null;
    peaksMin: Float32Array = new Float32Array(0);
    peaksMax: Float32Array = new Float32Array(0);

    // Recording an instrument.
    instruments: Array<string> = []; // the song's instruments, then the presets
    recInst: i32 = 0;
    recNote: i32 = 60;
    recLength: f64 = 1;
    recVel: f64 = 0.8;
    recName: string = "";
    nameEdited: bool = false;
    editing: bool = false;
    buffer: string = "";

    takeActions(): Array<string> {
        let out = this.actions;
        this.actions = [];
        return out;
    }

    get hasSelection(): bool {
        return this.selB > this.selA;
    }

    get frames(): f64 {
        let d = this.data;
        return d != null ? <f64>d.frames : 0;
    }

    // Shows sample `name` (with its decoded data); "" shows the add form.
    show(name: string, data: SampleData?): void {
        if (name != this.name) {
            this.selA = 0;
            this.selB = 0;
            this.scrollY = 0;
            this.adding = false;
        }
        this.name = name;
        this.data = data;
        if (this.selB > this.frames) this.selB = this.frames;
        if (this.selA > this.selB) this.selA = this.selB;
    }

    startAdding(): void {
        this.adding = true;
        this.scrollY = 0;
        this.status = "";
    }

    get showingForm(): bool {
        return this.name.length == 0 || this.adding;
    }

    advance(seconds: f64): void {
        this.clock += seconds;
    }

    // The name a recording gets unless the user typed one: <instrument>_<note>.
    suggestedName(): string {
        let inst = this.recInst < this.instruments.length ? this.instruments[this.recInst] : "sound";
        return `${inst}_${noteName(this.recNote).replace("#", "s").toLowerCase()}`;
    }

    get recordName(): string {
        return this.nameEdited ? this.recName : this.suggestedName();
    }

    // --- Input (relative to the panel's top left) -------------------------------

    frameAt(x: f64): f64 {
        let f = (x - this.waveX) / this.waveW * this.frames;
        return Math.min(Math.max(Math.round(f), 0), this.frames);
    }

    pointerDown(x: f64, y: f64): void {
        let id = this.hitAt(x, y);
        if (this.editing && id != "recName") this.finishName();
        if (id == "wave") {
            this.dragging = true;
            this.dragFrom = this.frameAt(x);
            this.selA = this.dragFrom;
            this.selB = this.dragFrom;
            return;
        }
        if (id.length == 0) return;
        if (id == "recName") {
            this.editing = true;
            this.buffer = this.recordName;
            return;
        }
        if (id == "inst-" || id == "inst+") {
            let n = this.instruments.length;
            if (n > 0) this.recInst = (this.recInst + (id == "inst+" ? 1 : n - 1)) % n;
        } else if (id == "note-" || id == "note+") {
            this.recNote = min<i32>(max<i32>(this.recNote + (id == "note+" ? 1 : -1), 12), 120);
        } else if (id == "oct-" || id == "oct+") {
            this.recNote = min<i32>(max<i32>(this.recNote + (id == "oct+" ? 12 : -12), 12), 120);
        } else if (id == "len-" || id == "len+") {
            this.recLength = Math.min(Math.max(this.recLength + (id == "len+" ? 0.25 : -0.25), 0.25), 30);
        } else if (id == "vel-" || id == "vel+") {
            this.recVel = Math.round(Math.min(Math.max(this.recVel + (id == "vel+" ? 0.1 : -0.1), 0.1), 1) * 10) / 10;
        } else if (id == "cancel") {
            this.adding = false;
        } else {
            this.actions.push(id);
        }
    }

    pointerMove(x: f64, y: f64): void {
        if (this.dragging) {
            let f = this.frameAt(x);
            this.selA = Math.min(this.dragFrom, f);
            this.selB = Math.max(this.dragFrom, f);
            return;
        }
        this.hover = this.hitAt(x, y);
    }

    pointerUp(): void {
        this.dragging = false;
    }

    scroll(dy: f64): void {
        let y = Math.max(this.scrollY + dy, 0);
        if (this.contentH > 0) y = Math.min(y, Math.max(this.contentH - this.viewH, 0));
        this.scrollY = y;
    }

    finishName(): void {
        this.editing = false;
        if (this.buffer.length > 0) {
            this.recName = this.buffer;
            this.nameEdited = this.buffer != this.suggestedName();
        }
    }

    // Keys (true when taken): typing the recording's name, or Delete and
    // Escape on the selection. Undo comes through the app (Cmd+Z).
    key(key: i32): bool {
        if (this.editing) {
            if (key == KEY_ENTER || key == KEY_TAB) this.finishName();
            else if (key == KEY_ESCAPE) this.editing = false;
            else if (key == KEY_BACKSPACE) this.buffer = this.buffer.substring(0, max<i32>(this.buffer.length - 1, 0));
            return true;
        }
        if (this.showingForm) return false;
        if ((key == KEY_BACKSPACE || key == KEY_DELETE) && this.hasSelection) {
            this.actions.push("edit:cut");
            return true;
        }
        if (key == KEY_ESCAPE && this.hasSelection) {
            this.selA = 0;
            this.selB = 0;
            return true;
        }
        return false;
    }

    // Names keep to lowercase letters, digits and '_'.
    typeText(text: string): bool {
        if (!this.editing) return false;
        for (let i = 0; i < text.length; i++) {
            let c = text.charCodeAt(i);
            if (c >= 65 && c <= 90) c += 32;
            if (c == 45 || c == 32) c = 95;
            if ((c >= 97 && c <= 122) || c == 95 || (this.buffer.length > 0 && c >= 48 && c <= 57)) this.buffer += String.fromCharCode(c);
        }
        return true;
    }

    // --- Drawing ----------------------------------------------------------------------

    draw(renderer: Renderer, ui: EditorView, width: f64, height: f64): void {
        this.renderer = renderer;
        this.run(ui, width, height);
        this.renderer = null;
    }

    layout(ui: EditorView, width: f64, height: f64): void {
        this.renderer = null;
        this.run(ui, width, height);
    }

    run(ui: EditorView, width: f64, height: f64): void {
        let k = ui.colors;
        this.viewH = height;
        this.hits = [];
        this.rect(ui, 0, 0, width, height, k.background);
        this.save();
        this.clip(ui, 0, 0, width, height);
        let x = PANEL_PAD;
        let w = Math.max(Math.min(width - PANEL_PAD * 2, PANEL_WIDTH), 200);
        let y = 22 - this.scrollY;
        if (this.showingForm) y = this.drawForm(ui, x, y, w);
        else y = this.drawSample(ui, x, y, w);
        this.contentH = y + this.scrollY + 32;
        this.restore();
        this.scroll(0);
    }

    drawSample(ui: EditorView, x: f64, y0: f64, w: f64): f64 {
        let k = ui.colors;
        let y = y0;
        let d = this.data;
        this.text(ui, ui.labelIn(this.name, ui.titleStyle, "st:"), x, y);
        let info = d == null ? "" : d.error.length > 0 ? d.error : `${seconds(<f64>d.frames / d.rate)}  ·  ${Math.round(d.rate / 100) / 10} kHz  ·  samples/${this.name}.wav`;
        this.text(ui, ui.labelIn(info, d != null && d.error.length > 0 ? ui.errorStyle : ui.hintStyle, d != null && d.error.length > 0 ? "se:" : "sh:"), x, y + 28);
        this.button(ui, "play", this.playing ? "Stop" : this.hasSelection ? "Play selection" : "Play", x + w - 120, y + 2, 120, this.playing);
        y += 56;

        // The waveform, the selection and the playhead.
        this.waveX = x;
        this.waveY = y;
        this.waveW = w;
        this.rect(ui, x, y, w, WAVE_H, 0xFF0A0A0A);
        this.rect(ui, x, y + WAVE_H * 0.5, w, 1, k.control);
        if (d != null && d.frames > 0) {
            let frames = <f64>d.frames;
            if (this.hasSelection) {
                let sx = x + this.selA / frames * w;
                let sw = Math.max((this.selB - this.selA) / frames * w, 1);
                this.rect(ui, sx, y, sw, WAVE_H, 0xFF222222);
                this.rect(ui, sx, y, 1, WAVE_H, k.edge);
                this.rect(ui, sx + sw - 1, y, 1, WAVE_H, k.edge);
            }
            this.peaks(d, <i32>w);
            let mid = y + WAVE_H * 0.5;
            let half = WAVE_H * 0.46;
            for (let c = 0; c < this.peaksMin.length; c++) {
                let lo = <f64>this.peaksMin[c];
                let hi = <f64>this.peaksMax[c];
                let cx = x + <f64>c;
                let f = (<f64>c + 0.5) / w * frames;
                let inside = this.hasSelection && f >= this.selA && f < this.selB;
                this.rect(ui, cx, mid - hi * half, 1, Math.max((hi - lo) * half, 1), inside || !this.hasSelection ? 0xFFC8C8C8 : 0xFF6A6A6A);
            }
            if (this.playhead >= 0 && this.playhead <= frames) this.rect(ui, x + this.playhead / frames * w, y, 1, WAVE_H, k.white);
            // Time ruler: start, middle, end.
            let total = frames / d.rate;
            this.text(ui, ui.labelIn("0 s", ui.labelStyle, "l:"), x, y + WAVE_H + 4);
            let midT = ui.labelIn(seconds(total / 2), ui.labelStyle, "l:");
            this.text(ui, midT, x + w * 0.5 - this.textWidth(midT) * 0.5, y + WAVE_H + 4);
            let endT = ui.labelIn(seconds(total), ui.labelStyle, "l:");
            this.text(ui, endT, x + w - this.textWidth(endT), y + WAVE_H + 4);
        }
        this.hits.push(new Hit(x, y, w, WAVE_H, "wave"));
        y += WAVE_H + 24;
        let sel = "Drag across the waveform to select part of it; the edits and Play then apply to that part.";
        if (d != null && this.hasSelection) {
            sel = `Selected ${seconds(this.selA / d.rate)} to ${seconds(this.selB / d.rate)} (${seconds((this.selB - this.selA) / d.rate)}).  Delete cuts it, Escape clears it.`;
        }
        this.text(ui, ui.labelIn(sel, ui.hintStyle, "sh:"), x, y);
        y += 26;

        // Edits.
        let bx = x;
        for (let i = 0; i < EDITS.length; i += 2) {
            let id = EDITS[i];
            let needsSelection = id == "trim" || id == "cut";
            if (needsSelection && !this.hasSelection) this.disabled(ui, EDITS[i + 1], bx, y, EDIT_W);
            else this.button(ui, "edit:" + id, EDITS[i + 1], bx, y, EDIT_W, false);
            bx += EDIT_W + 4;
            if (bx + EDIT_W > x + w) {
                bx = x;
                y += CONTROL_H + 6;
            }
        }
        if (this.canUndo) this.button(ui, "undo", "Undo", bx, y, EDIT_W, false);
        else this.disabled(ui, "Undo", bx, y, EDIT_W);
        y += CONTROL_H + 18;

        // How to play it, and what plays it.
        y = this.section(ui, "Use it", x, y, w);
        let code = `sample(file: ${this.name})`;
        this.rect(ui, x, y - 4, w, CONTROL_H + 8, 0xFF0A0A0A);
        this.text(ui, ui.textFor(code), x + 10, y + 3);
        this.button(ui, "newInstrument", "New instrument", x + w - 130, y - 1, 130, false);
        this.button(ui, "copy", "Copy", x + w - 130 - 72, y - 1, 66, false);
        y += CONTROL_H + 14;
        this.text(ui, ui.labelIn("In an instrument: root: sets the note it plays at its own pitch, slices: cuts it per note, loop:, oneshot:, reverse: and choke: change how it plays (Docs, Samples).", ui.hintStyle, "sh:"), x, y);
        y += 32;
        y = this.section(ui, "Used by", x, y, w);
        if (this.usages.length == 0) {
            this.text(ui, ui.labelIn("No instrument plays it yet.", ui.hintStyle, "sh:"), x, y);
            y += 24;
        }
        for (let i = 0; i < this.usages.length; i++) {
            let u = this.usages[i];
            let id = "open:" + u.instrument;
            if (this.hover == id) this.rect(ui, x - 6, y - 4, w + 12, 26, k.control);
            this.text(ui, ui.labelIn(u.instrument, ui.boldStyle, "n1:"), x, y);
            this.text(ui, ui.textFor(u.line), x + 140, y);
            this.hits.push(new Hit(x - 6, y - 4, w + 12, 26, id));
            y += 28;
        }
        return y;
    }

    drawForm(ui: EditorView, x: f64, y0: f64, w: f64): f64 {
        let k = ui.colors;
        let y = y0;
        this.text(ui, ui.labelIn("Add a sample", ui.titleStyle, "st:"), x, y);
        this.text(ui, ui.labelIn("Samples are WAV files in the song's samples/ folder. Instruments play them with sample(file: name).", ui.hintStyle, "sh:"), x, y + 28);
        if (this.name.length > 0) this.button(ui, "cancel", "Back", x + w - 80, y + 2, 80, false);
        y += 60;

        y = this.section(ui, "Import files", x, y, w);
        if (this.hosted) {
            this.text(ui, ui.labelIn("Choose WAV, AIFF, MP3 or M4A files: they are copied into samples/ as WAV.", ui.hintStyle, "sh:"), x, y);
            this.button(ui, "import", "Import files", x, y + 24, 140, false);
        } else {
            this.text(ui, ui.labelIn("Importing reads your disk, so it needs the partition app. In the previewer, record an instrument below.", ui.hintStyle, "sh:"), x, y);
            this.disabled(ui, "Import files", x, y + 24, 140);
        }
        this.text(ui, ui.labelIn("With the partition app, WAV files copied into the song's samples/ folder appear here too.", ui.hintStyle, "sh:"), x, y + 60);
        y += 96;

        y = this.section(ui, "Record an instrument", x, y, w);
        this.text(ui, ui.labelIn("Renders one note of an instrument into a new sample: resample a synth, freeze a sound with its effects, build a kit.", ui.hintStyle, "sh:"), x, y);
        y += 30;
        let lx = x + 120;
        let inst = this.recInst < this.instruments.length ? this.instruments[this.recInst] : "";
        y = this.choice(ui, "Instrument", "inst", inst, x, lx, y, 180);
        this.text(ui, ui.labelIn("Note", ui.boldStyle, "n1:"), x, y + 4);
        this.button(ui, "oct-", "<<", lx, y, CONTROL_H, false);
        this.button(ui, "note-", "<", lx + CONTROL_H + 2, y, CONTROL_H, false);
        this.box(ui, noteName(this.recNote), lx + (CONTROL_H + 2) * 2, y, 64);
        this.button(ui, "note+", ">", lx + (CONTROL_H + 2) * 2 + 66, y, CONTROL_H, false);
        this.button(ui, "oct+", ">>", lx + (CONTROL_H + 2) * 3 + 66, y, CONTROL_H, false);
        y += CONTROL_H + 10;
        y = this.choice(ui, "Length", "len", seconds(this.recLength), x, lx, y, 80);
        y = this.choice(ui, "Velocity", "vel", `${this.recVel}`, x, lx, y, 80);
        this.text(ui, ui.labelIn("Name", ui.boldStyle, "n1:"), x, y + 4);
        let name = this.editing ? this.buffer : this.recordName;
        this.rect(ui, lx, y, 220, CONTROL_H, this.editing ? k.white : this.hover == "recName" ? k.edge : k.divider);
        this.rect(ui, lx + 1, y + 1, 218, CONTROL_H - 2, 0xFF0A0A0A);
        let t = ui.labelIn(name, ui.valueStyle, "sv:");
        this.text(ui, t, lx + 8, y + 4);
        if (this.editing && (this.clock % 1.0) < 0.6) this.rect(ui, lx + 9 + this.textWidth(t), y + 5, 1.5, CONTROL_H - 10, k.white);
        this.hits.push(new Hit(lx, y, 220, CONTROL_H, "recName"));
        this.text(ui, ui.labelIn(`samples/${name}.wav`, ui.hintStyle, "sh:"), lx + 232, y + 5);
        y += CONTROL_H + 16;
        this.button(ui, "record", "Record", lx, y, 100, false);
        if (this.status.length > 0) this.text(ui, ui.labelIn(this.status, ui.hintStyle, "sh:"), lx + 116, y + 5);
        y += CONTROL_H + 10;
        return y;
    }

    // A label, then < value >.
    choice(ui: EditorView, label: string, id: string, value: string, x: f64, lx: f64, y: f64, w: f64): f64 {
        this.text(ui, ui.labelIn(label, ui.boldStyle, "n1:"), x, y + 4);
        this.button(ui, id + "-", "<", lx, y, CONTROL_H, false);
        this.box(ui, value, lx + CONTROL_H + 2, y, w);
        this.button(ui, id + "+", ">", lx + CONTROL_H + 4 + w, y, CONTROL_H, false);
        return y + CONTROL_H + 10;
    }

    // A read-only value in a field's frame.
    box(ui: EditorView, value: string, x: f64, y: f64, w: f64): void {
        let k = ui.colors;
        this.rect(ui, x, y, w, CONTROL_H, k.divider);
        this.rect(ui, x + 1, y + 1, w - 2, CONTROL_H - 2, 0xFF0A0A0A);
        let t = ui.labelIn(value, ui.valueStyle, "sv:");
        this.text(ui, t, x + (w - this.textWidth(t)) * 0.5, y + 4);
    }

    // A button that does nothing yet: drawn dim, with no hit.
    disabled(ui: EditorView, label: string, x: f64, y: f64, w: f64): void {
        let k = ui.colors;
        this.rect(ui, x, y, w, CONTROL_H, k.control);
        this.rect(ui, x + 1, y + 1, w - 2, CONTROL_H - 2, 0xFF0A0A0A);
        let t = ui.labelIn(label, ui.labelStyle, "l:");
        this.text(ui, t, x + (w - this.textWidth(t)) * 0.5, y + 7);
    }

    // Min and max per column of `d` for a waveform `columns` wide.
    peaks(d: SampleData, columns: i32): void {
        if (this.peaksFor == d && this.peaksMin.length == columns) return;
        this.peaksFor = d;
        let n = max<i32>(columns, 1);
        this.peaksMin = new Float32Array(n);
        this.peaksMax = new Float32Array(n);
        let frames = d.frames;
        for (let c = 0; c < n; c++) {
            let a = <i32>(<f64>c / <f64>n * <f64>frames);
            let b = max<i32>(<i32>(<f64>(c + 1) / <f64>n * <f64>frames), a + 1);
            let lo: f32 = 0;
            let hi: f32 = 0;
            for (let i = a; i < b && i < frames; i++) {
                let v = d.data[i];
                if (v < lo) lo = v;
                if (v > hi) hi = v;
            }
            this.peaksMin[c] = lo;
            this.peaksMax[c] = hi;
        }
    }
}
