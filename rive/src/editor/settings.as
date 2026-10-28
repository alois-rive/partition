// The settings tab (docs/spec.md §10.10): a form over song.yaml. Title and
// author, tempo, signature, rows per beat, swing, master volume, and the track
// list (name, width, mute and solo at the start, order, add and remove).
// Every change is checked like song.yaml itself, then written back as a whole
// file (`takeYaml`); what else must change (a track file to add or delete,
// the live mix) is reported as actions.

import { Renderer } from "rive/renderer";
import { ChannelConfig, parseSongConfig, SongConfig, songConfigText } from "../lang/config";
import { EditorView, KEY_BACKSPACE, KEY_ENTER, KEY_ESCAPE, KEY_TAB, trackColor } from "./view";
import { CONTROL_H, Form, Hit } from "./form";

export const SETTINGS_PAD: f64 = 32;
export const SETTINGS_WIDTH: f64 = 720; // the form's widest
const LABEL_W: f64 = 200;
const ROW_H: f64 = 52;
const TRACK_ROW_H: f64 = 34;
const BUTTON_W: f64 = 26;
const SLIDER_W: f64 = 240;
export const DENOMINATORS: StaticArray<i32> = [2, 4, 8, 16];

// `v` with at most `places` decimals, without trailing zeros.
export function decimals(v: f64, places: i32): string {
    let scale = Math.pow(10, <f64>places);
    let r = Math.round(v * scale) / scale;
    if (r == Math.floor(r)) return (<i64>r).toString();
    return r.toString();
}

export function gainDb(gain: f64): string {
    if (gain <= 0.0001) return "-inf dB";
    let db = 20 * Math.log(gain) / Math.LN10;
    let text = decimals(db, 1);
    return `${db > 0.05 ? "+" : ""}${text} dB`;
}

export class SettingsPanel extends Form {
    config: SongConfig = new SongConfig();
    // The song.yaml text the form shows; a change that it did not make reloads the form.
    shownYaml: string = "";
    yaml: string = ""; // a new song.yaml to write, "" for none
    actions: Array<string> = [];
    editing: string = ""; // the field being typed in
    buffer: string = "";
    error: string = "";
    errorField: string = "";
    dragging: string = ""; // the slider being dragged
    sliderX: f64 = 0;
    confirming: i32 = -1; // the track whose removal waits for a second click
    confirmUntil: f64 = 0;
    scrollY: f64 = 0;
    contentH: f64 = 0;
    viewH: f64 = 600;

    // The form follows song.yaml as the song has it, unless it is mid-edit.
    load(text: string): void {
        if (text == this.shownYaml) return;
        this.shownYaml = text;
        this.config = parseSongConfig(text).config;
        if (this.confirming >= this.config.channels.length) this.confirming = -1;
    }

    takeYaml(): string {
        let out = this.yaml;
        this.yaml = "";
        return out;
    }

    takeActions(): Array<string> {
        let out = this.actions;
        this.actions = [];
        return out;
    }

    advance(seconds: f64): void {
        this.clock += seconds;
        if (this.confirming >= 0 && this.clock > this.confirmUntil) this.confirming = -1;
    }

    // Writes the form's config back as song.yaml.
    write(): void {
        let text = songConfigText(this.config);
        this.shownYaml = text;
        this.yaml = text;
        this.config = parseSongConfig(text).config;
    }

    // --- Values ------------------------------------------------------------------------

    valueOf(id: string): string {
        let c = this.config;
        if (id == "title") return c.title;
        if (id == "author") return c.author;
        if (id == "bpm") return decimals(c.bpm, 2);
        if (id == "sigNum") return `${c.sigNum}`;
        if (id == "rpb") return `${c.rowsPerBeat}`;
        if (id == "seed") return `${c.seed}`;
        if (id.startsWith("trk:")) {
            let parts = id.split(":");
            let i = <i32>parseInt(parts[1]);
            if (i < 0 || i >= c.channels.length) return "";
            let ch = c.channels[i];
            if (parts[2] == "name") return ch.name;
            if (parts[2] == "width") return ch.widthSet ? `${ch.width}` : "auto";
        }
        return "";
    }

    // Reads `key: text` the way song.yaml would; the message of the first error, or "".
    check(key: string, text: string): string {
        let result = parseSongConfig(`${key}: ${text}\n`);
        let all = result.diagnostics.items;
        for (let i = 0; i < all.length; i++) if (all[i].isError) return all[i].message;
        return "";
    }

    // Applies a typed value; false (with `error` set) when it is refused.
    commit(id: string, text: string): bool {
        let c = this.config;
        let value = text.trim();
        let problem = "";
        if (id == "title") {
            c.title = value.length > 0 ? value : "Untitled";
        } else if (id == "author") {
            c.author = value;
        } else if (id == "bpm") {
            problem = this.check("bpm", value);
            if (problem.length == 0) c.bpm = parseSongConfig(`bpm: ${value}\n`).config.bpm;
        } else if (id == "sigNum") {
            problem = this.check("signature", `${value}/${c.sigDen}`);
            if (problem.length == 0) c.sigNum = parseSongConfig(`signature: ${value}/${c.sigDen}\n`).config.sigNum;
        } else if (id == "seed") {
            problem = this.check("seed", value);
            if (problem.length == 0) c.seed = parseSongConfig(`seed: ${value}\n`).config.seed;
        } else if (id == "rpb") {
            problem = this.check("rows_per_beat", value);
            if (problem.length == 0) c.rowsPerBeat = parseSongConfig(`rows_per_beat: ${value}\n`).config.rowsPerBeat;
        } else if (id.startsWith("trk:")) {
            let parts = id.split(":");
            let i = <i32>parseInt(parts[1]);
            if (i < 0 || i >= c.channels.length) return true;
            let ch = c.channels[i];
            if (parts[2] == "name") {
                if (value.length == 0) problem = "a track needs a name";
                for (let k = 0; k < c.channels.length; k++) {
                    if (k != i && c.channels[k].name == value) problem = `there is already a track named '${value}'`;
                }
                if (problem.length == 0) ch.name = value;
            } else if (parts[2] == "width") {
                if (value.length == 0 || value == "auto") {
                    ch.widthSet = false;
                } else {
                    let n = parseInt(value);
                    if (isNaN(n) || n != Math.floor(n) || n < 8 || n > 200 || `${<i32>n}` != value) problem = "a width is a whole number of characters from 8 to 200, or auto";
                    else {
                        ch.width = <i32>n;
                        ch.widthSet = true;
                    }
                }
            }
        }
        if (problem.length > 0) {
            this.error = problem;
            this.errorField = id;
            return false;
        }
        this.error = "";
        this.errorField = "";
        this.write();
        return true;
    }

    // A −/+ press on a stepper.
    step(id: string, delta: i32): void {
        let c = this.config;
        if (id == "bpm") c.bpm = Math.min(Math.max(Math.round(c.bpm) + <f64>delta, 20), 999);
        else if (id == "sigNum") c.sigNum = min<i32>(max<i32>(c.sigNum + delta, 1), 32);
        else if (id == "rpb") c.rowsPerBeat = min<i32>(max<i32>(c.rowsPerBeat + delta, 1), 16);
        else if (id == "seed") c.seed = min<i32>(max<i32>(c.seed + delta, 0), 999999999);
        else return;
        this.cancelEdit();
        this.write();
    }

    sliderValue(id: string): f64 {
        return id == "swing" ? this.config.swing : this.config.masterVolume;
    }

    sliderMax(id: string): f64 {
        return id == "swing" ? 0.75 : 2;
    }

    setSlider(id: string, fraction: f64): void {
        let f = Math.min(Math.max(fraction, 0), 1);
        if (id == "swing") this.config.swing = Math.round(f * 0.75 * 100) / 100;
        else this.config.masterVolume = Math.round(f * 2 * 100) / 100;
        this.write();
    }

    // --- Tracks --------------------------------------------------------------------------

    addTrack(): void {
        let c = this.config;
        let n = c.channels.length + 1;
        while (this.hasTrack(`track_${n}`)) n++;
        let ch = new ChannelConfig();
        ch.name = `track_${n}`;
        ch.file = `channels/track_${n}.ch`;
        c.channels.push(ch);
        this.actions.push(`trackAdd:${ch.file}`);
        this.write();
    }

    hasTrack(name: string): bool {
        let c = this.config;
        for (let i = 0; i < c.channels.length; i++) {
            if (c.channels[i].name == name || c.channels[i].file == `channels/${name}.ch`) return true;
        }
        return false;
    }

    moveTrack(i: i32, delta: i32): void {
        let list = this.config.channels;
        let j = i + delta;
        if (i < 0 || j < 0 || i >= list.length || j >= list.length) return;
        let a = list[i];
        list[i] = list[j];
        list[j] = a;
        this.write();
    }

    removeTrack(i: i32): void {
        let list = this.config.channels;
        if (i < 0 || i >= list.length) return;
        let file = list[i].file;
        list.splice(i, 1);
        this.actions.push(`trackDelete:${file}`);
        this.write();
    }

    toggleTrack(i: i32, solo: bool): void {
        let list = this.config.channels;
        if (i < 0 || i >= list.length) return;
        let ch = list[i];
        if (solo) ch.solo = !ch.solo;
        else ch.mute = !ch.mute;
        this.actions.push(`trackMix:${ch.file}:${ch.mute ? 1 : 0}:${ch.solo ? 1 : 0}`);
        this.write();
    }

    // --- Input (coordinates relative to the panel's top left) -----------------------

    isTextField(id: string): bool {
        return id == "title" || id == "author" || id == "bpm" || id == "sigNum" || id == "rpb" || id == "seed" ||
            (id.startsWith("trk:") && (id.endsWith(":name") || id.endsWith(":width")));
    }

    startEdit(id: string): void {
        this.editing = id;
        this.buffer = this.valueOf(id);
        if (this.buffer == "auto") this.buffer = "";
        if (this.errorField != id) {
            this.error = "";
            this.errorField = "";
        }
    }

    // Ends typing: keeps a valid value; a refused one stays open with its message.
    finishEdit(): bool {
        if (this.editing.length == 0) return true;
        let id = this.editing;
        if (this.buffer == this.valueOf(id)) {
            this.editing = "";
            return true;
        }
        if (this.commit(id, this.buffer)) {
            this.editing = "";
            return true;
        }
        return false;
    }

    cancelEdit(): void {
        this.editing = "";
        this.error = "";
        this.errorField = "";
    }

    pointerDown(x: f64, y: f64): void {
        let id = this.hitAt(x, y);
        if (this.editing.length > 0 && id != this.editing) {
            if (!this.finishEdit()) return;
        }
        if (id.length == 0) return;
        if (this.isTextField(id)) {
            if (this.editing != id) this.startEdit(id);
            return;
        }
        if (id.endsWith("-") || id.endsWith("+")) {
            this.step(id.substring(0, id.length - 1), id.endsWith("+") ? 1 : -1);
            return;
        }
        if (id.startsWith("den:")) {
            this.config.sigDen = <i32>parseInt(id.substring(4));
            this.write();
            return;
        }
        if (id == "swing" || id == "master") {
            let h = this.hitOf(id);
            if (h == null) return;
            this.dragging = id;
            this.sliderX = h.x;
            this.setSlider(id, (x - h.x) / SLIDER_W);
            return;
        }
        if (id == "shuffle") {
            // A new seed: every random choice in the song is drawn again.
            let h = <u32>this.config.seed * 2654435761 + 1013904223;
            this.config.seed = <i32>((h ^ (h >> 13)) % 999999999);
            this.cancelEdit();
            this.write();
            return;
        }
        if (id == "addTrack") {
            this.addTrack();
            return;
        }
        if (id.startsWith("trk:")) {
            let parts = id.split(":");
            let i = <i32>parseInt(parts[1]);
            let what = parts[2];
            if (what == "up") this.moveTrack(i, -1);
            else if (what == "down") this.moveTrack(i, 1);
            else if (what == "mute") this.toggleTrack(i, false);
            else if (what == "solo") this.toggleTrack(i, true);
            else if (what == "del") {
                if (this.confirming == i) {
                    this.confirming = -1;
                    this.removeTrack(i);
                } else {
                    this.confirming = i;
                    this.confirmUntil = this.clock + 3;
                }
                return;
            }
            this.confirming = -1;
        }
    }

    pointerMove(x: f64, y: f64): void {
        if (this.dragging.length > 0) {
            this.setSlider(this.dragging, (x - this.sliderX) / SLIDER_W);
            return;
        }
        this.hover = this.hitAt(x, y);
    }

    pointerUp(): void {
        this.dragging = "";
    }

    // Clamped to the content once a draw has measured it.
    scroll(dy: f64): void {
        let y = Math.max(this.scrollY + dy, 0);
        if (this.contentH > 0) y = Math.min(y, Math.max(this.contentH - this.viewH, 0));
        this.scrollY = y;
    }

    // Keys while typing in a field (true when taken).
    key(key: i32): bool {
        if (this.editing.length == 0) return false;
        if (key == KEY_ENTER || key == KEY_TAB) this.finishEdit();
        else if (key == KEY_ESCAPE) this.cancelEdit();
        else if (key == KEY_BACKSPACE) this.buffer = this.buffer.substring(0, max<i32>(this.buffer.length - 1, 0));
        return true;
    }

    typeText(text: string): bool {
        if (this.editing.length == 0) return false;
        for (let i = 0; i < text.length; i++) {
            let c = text.charCodeAt(i);
            if (c >= 32 && c != 127) this.buffer += String.fromCharCode(c);
        }
        return true;
    }

    // --- Drawing ---------------------------------------------------------------------------

    // Paints the form, and notes where its controls are.
    draw(renderer: Renderer, ui: EditorView, width: f64, height: f64): void {
        this.renderer = renderer;
        this.run(ui, width, height);
        this.renderer = null;
    }

    // Notes where the controls are without painting (input can come before a draw).
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
        let x = SETTINGS_PAD;
        let w = Math.min(width - SETTINGS_PAD * 2, SETTINGS_WIDTH);
        let y = 24 - this.scrollY;
        this.text(ui, ui.labelIn("Song settings", ui.titleStyle, "st:"), x, y);
        this.text(ui, ui.labelIn("song.yaml", ui.hintStyle, "sh:"), x, y + 28);
        y += 52;

        let c = this.config;
        y = this.section(ui, "Song", x, y, w);
        this.label(ui, "Title", "Shown in the title bar.", x, y);
        this.field(ui, "title", x + LABEL_W, y, Math.min(320, w - LABEL_W));
        y += ROW_H;
        this.label(ui, "Author", "", x, y);
        this.field(ui, "author", x + LABEL_W, y, Math.min(320, w - LABEL_W));
        y += ROW_H;
        this.label(ui, "Seed", "Every random choice (prob, humanize, pick) follows it: the same seed plays the same song.", x, y);
        let after = this.stepper(ui, "seed", x + LABEL_W, y, 96);
        this.button(ui, "shuffle", "Shuffle", after + 8, y, 80, false);
        y += ROW_H;

        y = this.section(ui, "Time", x, y, w);
        this.label(ui, "Tempo", "Beats per minute at the start. bpm() in the conductor changes it.", x, y);
        after = this.stepper(ui, "bpm", x + LABEL_W, y, 64);
        this.text(ui, ui.labelIn("BPM", ui.hintStyle, "sh:"), after + 8, y + 5);
        y += ROW_H;
        this.label(ui, "Signature", "Beats per bar, over the note value of a beat.", x, y);
        after = this.stepper(ui, "sigNum", x + LABEL_W, y, 40);
        this.text(ui, ui.labelIn("/", ui.paraStyle, "sp:"), after + 8, y + 4);
        let sx = after + 22;
        for (let i = 0; i < DENOMINATORS.length; i++) {
            let d = DENOMINATORS[i];
            this.button(ui, `den:${d}`, `${d}`, sx, y, 32, c.sigDen == d);
            sx += 32 + 2;
        }
        y += ROW_H;
        let rowNote = c.sigDen * c.rowsPerBeat;
        this.label(ui, "Rows per beat", `Each line is one row: here a 1/${rowNote} note.`, x, y);
        this.stepper(ui, "rpb", x + LABEL_W, y, 40);
        y += ROW_H;
        this.label(ui, "Swing", "Delays every other row, for a shuffled feel.", x, y);
        this.slider(ui, "swing", x + LABEL_W, y, decimals(c.swing, 2));
        y += ROW_H;

        y = this.section(ui, "Mix", x, y, w);
        this.label(ui, "Master volume", "The level of the whole song.", x, y);
        this.slider(ui, "master", x + LABEL_W, y, `${decimals(c.masterVolume, 2)}   ${gainDb(c.masterVolume)}`);
        y += ROW_H;

        // Tracks: one row each, then a button that adds one.
        let top = y;
        y = this.section(ui, "Tracks", x, y, w);
        this.button(ui, "addTrack", "+  Add track", x + w - 104, top + 8, 104, false);
        this.text(ui, ui.labelIn("The conductor is always first. Mute and solo here are how the song starts; the M and S in the track headers change them while playing.", ui.hintStyle, "sh:"), x, y - 6);
        y += 20;
        let colName = x + 22;
        let colFile = x + 200;
        let colWidth = x + Math.max(w - 250, 360);
        let colMix = colWidth + 84;
        let colMove = colMix + 64;
        this.text(ui, ui.labelIn("NAME", ui.labelStyle, "l:"), colName, y);
        this.text(ui, ui.labelIn("FILE", ui.labelStyle, "l:"), colFile, y);
        this.text(ui, ui.labelIn("WIDTH", ui.labelStyle, "l:"), colWidth, y);
        y += 18;
        this.rect(ui, x, y, w, 1, k.divider);
        for (let i = 0; i < c.channels.length; i++) {
            let ch = c.channels[i];
            let ry = y + 4;
            this.dot(ui, x + 8, ry + CONTROL_H * 0.5, 4, trackColor(i + 1), false);
            if (this.confirming == i) {
                this.text(ui, ui.labelIn(`Remove ${ch.name} and its file? Click again to confirm.`, ui.boldStyle, "n1:"), colName, ry + 4);
            } else {
                this.field(ui, `trk:${i}:name`, colName, ry, 160);
                this.text(ui, ui.labelIn(ch.file, ui.hintStyle, "sh:"), colFile, ry + 5);
                this.field(ui, `trk:${i}:width`, colWidth, ry, 64);
                this.toggle(ui, `trk:${i}:mute`, "M", colMix, ry, ch.mute);
                this.toggle(ui, `trk:${i}:solo`, "S", colMix + 26, ry, ch.solo);
                this.icon(ui, `trk:${i}:up`, colMove, ry, 0, i > 0);
                this.icon(ui, `trk:${i}:down`, colMove + BUTTON_W + 2, ry, 1, i + 1 < c.channels.length);
            }
            this.icon(ui, `trk:${i}:del`, colMove + (BUTTON_W + 2) * 2 + 6, ry, 2, true);
            if (this.errorField.startsWith(`trk:${i}:`)) {
                y += TRACK_ROW_H;
                this.text(ui, ui.labelIn(this.error, ui.errorStyle, "se:"), colName, y);
                y += 6;
            }
            y += TRACK_ROW_H;
            this.rect(ui, x, y, w, 1, k.control);
        }
        if (c.channels.length == 0) {
            this.text(ui, ui.labelIn("No tracks yet: add one.", ui.hintStyle, "sh:"), colName, y + 10);
            y += TRACK_ROW_H;
        }
        y += 32;
        this.contentH = y + this.scrollY;
        this.restore();
        this.scroll(0);
    }

    // A text field; while typed in, a caret and (if refused) the reason.
    field(ui: EditorView, id: string, x: f64, y: f64, w: f64): void {
        let k = ui.colors;
        let editing = this.editing == id;
        let bad = this.errorField == id;
        let edge = bad ? k.error : editing ? k.white : this.hover == id ? k.edge : k.divider;
        this.rect(ui, x, y, w, CONTROL_H, edge);
        this.rect(ui, x + 1, y + 1, w - 2, CONTROL_H - 2, 0xFF0A0A0A);
        let text = editing ? this.buffer : this.valueOf(id);
        let style = !editing && text == "auto" ? ui.hintStyle : ui.valueStyle;
        let t = ui.labelIn(text, style, style == ui.hintStyle ? "sh:" : "sv:");
        this.save();
        this.clip(ui, x + 1, y + 1, w - 2, CONTROL_H - 2);
        let tw = text.length > 0 ? this.textWidth(t) : 0;
        let shift = editing ? Math.max(tw - (w - 18), 0) : 0;
        this.text(ui, t, x + 8 - shift, y + 4);
        if (editing && (this.clock % 1.0) < 0.6) this.rect(ui, x + 9 + tw - shift, y + 5, 1.5, CONTROL_H - 10, k.white);
        this.restore();
        if (bad && !id.startsWith("trk:")) this.text(ui, ui.labelIn(this.error, ui.errorStyle, "se:"), x + w + 12, y + 5);
        this.hits.push(new Hit(x, y, w, CONTROL_H, id));
    }

    // − value +; returns the right edge.
    stepper(ui: EditorView, id: string, x: f64, y: f64, w: f64): f64 {
        this.button(ui, id + "-", "-", x, y, BUTTON_W, false);
        this.field(ui, id, x + BUTTON_W + 2, y, w);
        this.button(ui, id + "+", "+", x + BUTTON_W + 4 + w, y, BUTTON_W, false);
        return x + BUTTON_W * 2 + 4 + w;
    }

    toggle(ui: EditorView, id: string, label: string, x: f64, y: f64, on: bool): void {
        let k = ui.colors;
        let s = 22.0;
        let top = y + (CONTROL_H - s) * 0.5;
        this.rect(ui, x, top, s, s, on ? k.white : this.hover == id ? k.edge : k.divider);
        this.rect(ui, x + 1, top + 1, s - 2, s - 2, on ? k.white : k.control);
        let t = ui.labelIn(label, on ? ui.pressedStyle : ui.buttonStyle, on ? "bp:" : "bb:");
        this.text(ui, t, x + (s - this.textWidth(t)) * 0.5, top + 4);
        this.hits.push(new Hit(x, y, s, CONTROL_H, id));
    }

    // Up (0), down (1) and remove (2) buttons, drawn as strokes.
    icon(ui: EditorView, id: string, x: f64, y: f64, kind: i32, enabled: bool): void {
        let k = ui.colors;
        let hover = this.hover == id && enabled;
        if (hover) this.rect(ui, x, y, BUTTON_W, CONTROL_H, k.control);
        let ink = !enabled ? k.divider : kind == 2 && this.confirming >= 0 && id == `trk:${this.confirming}:del` ? k.error : hover ? k.white : k.secondary;
        let cx = x + BUTTON_W * 0.5;
        let cy = y + CONTROL_H * 0.5;
        if (kind == 0) {
            this.line(ui, cx - 5, cy + 3, cx, cy - 3, 1.4, ink);
            this.line(ui, cx, cy - 3, cx + 5, cy + 3, 1.4, ink);
        } else if (kind == 1) {
            this.line(ui, cx - 5, cy - 3, cx, cy + 3, 1.4, ink);
            this.line(ui, cx, cy + 3, cx + 5, cy - 3, 1.4, ink);
        } else {
            this.line(ui, cx - 4, cy - 4, cx + 4, cy + 4, 1.4, ink);
            this.line(ui, cx - 4, cy + 4, cx + 4, cy - 4, 1.4, ink);
        }
        if (enabled) this.hits.push(new Hit(x, y, BUTTON_W, CONTROL_H, id));
    }

    slider(ui: EditorView, id: string, x: f64, y: f64, readout: string): void {
        let k = ui.colors;
        let f = this.sliderValue(id) / this.sliderMax(id);
        let cy = y + CONTROL_H * 0.5;
        this.rect(ui, x, cy - 1, SLIDER_W, 2, k.divider);
        this.rect(ui, x, cy - 1, SLIDER_W * f, 2, k.white);
        let active = this.dragging == id || this.hover == id;
        this.rect(ui, x + SLIDER_W * f - 5, cy - 7, 10, 14, active ? k.white : 0xFFD0D0D0);
        this.text(ui, ui.labelIn(readout, ui.valueStyle, "sv:"), x + SLIDER_W + 16, y + 4);
        this.hits.push(new Hit(x - 6, y, SLIDER_W + 12, CONTROL_H, id));
    }
}
