// The channel grid (docs/spec.md §10): the gutter, one column per channel with
// the conductor first, time-aligned bands, one shared vertical scroll, the
// playhead, and text editing. It draws through a Renderer and takes input
// events; the app owns the song and the transport and talks to it through
// `columns`, `actions` and `changed`.

import { Font, Text, TextRunStyle, TextWrap } from "rive/text";
import { Renderer } from "rive/renderer";
import { Paint, PaintStyle } from "rive/paint";
import { Path } from "rive/path";
import { Mat2D } from "rive/mat2d";
import { Vector } from "rive/vector";
import { Color } from "rive/color";
import { KeyboardEvent, PointerEvent, ScrollEvent, TextInput } from "rive/events";
import { Diagnostic } from "../lang/diagnostics";
import { registry } from "../lang/commands";
import { lexLine, Tok } from "../lang/lexer";
import { Grid } from "../score/timeline";
import { Bands, ColumnMap } from "./bands";
import { Doc, Pos } from "./doc";
import { highlight, Hue } from "./highlight";

// GLFW key codes, as Rive reports them (docs/m0-findings.md).
export const KEY_ESCAPE: i32 = 256;
export const KEY_ENTER: i32 = 257;
export const KEY_TAB: i32 = 258;
export const KEY_BACKSPACE: i32 = 259;
export const KEY_DELETE: i32 = 261;
export const KEY_RIGHT: i32 = 262;
export const KEY_LEFT: i32 = 263;
export const KEY_DOWN: i32 = 264;
export const KEY_UP: i32 = 265;
export const KEY_PAGE_UP: i32 = 266;
export const KEY_PAGE_DOWN: i32 = 267;
export const KEY_HOME: i32 = 268;
export const KEY_END: i32 = 269;

export const INDENT: i32 = 2; // how wide a leading tab shows, in characters
export const EXTRA_BANDS: i32 = 48; // empty rows after the end, room to type
const CACHE_LIMIT: i32 = 3000;

export class Column {
    map: ColumnMap = new ColumnMap();
    diagnostics: Array<Diagnostic> = [];
    meter: f64 = 0;

    constructor(
        public doc: Doc,
        public name: string,
        public widthChars: i32,
        public isConductor: bool,
        public mute: bool,
        public solo: bool,
    ) {
        this.map = ColumnMap.build(doc.lines);
    }
}

class Palette {
    background: Color = 0xFF14161A;
    gutter: Color = 0xFF101215;
    header: Color = 0xFF1B1E24;
    conductor: Color = 0xFF171A20;
    beat: Color = 0xFF1E2229;
    bar: Color = 0xFF2C323C;
    divider: Color = 0xFF262B33;
    playhead: Color = 0x553D6FB8;
    cursorRow: Color = 0x14FFFFFF;
    selection: Color = 0xFF34405A;
    caret: Color = 0xFFE5E9F0;
    label: Color = 0xFF5D6675;
    labelStrong: Color = 0xFF97A1B3;
    mark: Color = 0xFFEBCB8B;
    error: Color = 0xFFBF616A;
    warning: Color = 0xFFD08770;
    mute: Color = 0xFFBF616A;
    solo: Color = 0xFFEBCB8B;
    off: Color = 0xFF3B4252;
    meter: Color = 0xFFA3BE8C;
    focus: Color = 0xFF5E81AC;
}

export class EditorView {
    columns: Array<Column> = [];
    focus: i32 = 0;
    bands: Bands = new Bands();
    grid: Grid? = null;
    width: f64 = 800;
    height: f64 = 600;
    scrollY: f64 = 0;
    scrollX: f64 = 0;
    follow: bool = true;
    playRow: i32 = -1;
    playing: bool = false;
    actions: Array<string> = [];
    changed: Array<i32> = [];
    clipboard: string = "";
    clock: f64 = 0;
    blinkStart: f64 = 0;

    // Metrics
    fontSize: f32 = 13;
    lineH: f64 = 20;
    charW: f64 = 7.8;
    ascent: f64 = 10;
    headerH: f64 = 32;
    gutterW: f64 = 64;
    padX: f64 = 10;

    font: Font? = null;
    bold: Font? = null;
    styles: Array<TextRunStyle> = [];
    boldStyle: TextRunStyle? = null;
    labelStyle: TextRunStyle? = null;
    cache: Map<string, Text> = new Map<string, Text>();
    labels: Map<string, Text> = new Map<string, Text>();
    colors: Palette = new Palette();
    fill: Paint = new Paint();
    stroke: Paint = new Paint();
    path: Path = new Path();

    // Pointer state
    dragging: bool = false;
    dragColumn: i32 = -1;
    lastClickTime: f64 = -1;
    lastClickPos: Pos = new Pos(-1, -1);

    setFonts(regular: Font?, bold: Font?): void {
        this.font = regular;
        this.bold = bold;
        this.styles = [];
        if (regular == null) return;
        let hues: Array<Color> = [
            0xFFD8DEE9, // Text
            0xFF81A1C1, // Command
            0xFF7B8698, // Arg
            0xFFEBCB8B, // Pitch
            0xFFA3BE8C, // Number
            0xFFD08770, // String
            0xFF5D6675, // Punct
            0xFFBF616A, // Error
            0xFFB48EAD, // Name
        ];
        for (let i = 0; i < hues.length; i++) this.styles.push(this.style(regular, hues[i], this.fontSize));
        this.boldStyle = this.style(bold != null ? bold : regular, 0xFFE5E9F0, this.fontSize);
        this.labelStyle = this.style(regular, this.colors.label, 11);
        this.lineH = Math.round(<f64>regular.lineHeight(this.fontSize) * 1.35);
        this.ascent = <f64>regular.ascent * <f64>this.fontSize;
        // Measure the advance of the monospace face.
        let probe = new Text();
        probe.wrap = TextWrap.noWrap;
        probe.append("0000000000", this.styles[0]);
        if (probe.lineCount > 0) this.charW = <f64>probe.line(0).width / 10;
        this.cache.clear();
        this.labels.clear();
    }

    style(font: Font, color: Color, size: f32): TextRunStyle {
        let s = new TextRunStyle(font);
        s.size = size;
        let p = new Paint();
        p.color = color;
        s.paint = p;
        s.foregroundColor = color;
        return s;
    }

    // --- Model -------------------------------------------------------------

    setColumns(columns: Array<Column>): void {
        this.columns = columns;
        this.focus = min<i32>(this.focus, max<i32>(columns.length - 1, 0));
        this.relayout();
    }

    relayout(): void {
        let maps = new Array<ColumnMap>();
        for (let i = 0; i < this.columns.length; i++) {
            let c = this.columns[i];
            c.map = ColumnMap.build(c.doc.lines);
            maps.push(c.map);
        }
        this.bands = Bands.build(maps, EXTRA_BANDS);
        this.clampScroll();
    }

    get focused(): Column? {
        if (this.focus < 0 || this.focus >= this.columns.length) return null;
        return this.columns[this.focus];
    }

    // After an edit to the focused column.
    edited(): void {
        if (!this.changed.includes(this.focus)) this.changed.push(this.focus);
        this.relayout();
        this.blinkStart = this.clock;
        this.reveal();
    }

    takeChanged(): Array<i32> {
        let out = this.changed;
        this.changed = [];
        return out;
    }

    takeActions(): Array<string> {
        let out = this.actions;
        this.actions = [];
        return out;
    }

    // --- Geometry ------------------------------------------------------------

    columnWidth(c: Column): f64 {
        return <f64>c.widthChars * this.charW + this.padX * 2;
    }

    // Left edge of column `i` on screen (channels scroll horizontally, the
    // conductor does not).
    columnX(i: i32): f64 {
        let x = this.gutterW;
        for (let k = 0; k < i; k++) x += this.columnWidth(this.columns[k]);
        if (i > 0 && this.columns.length > 0 && this.columns[0].isConductor) x -= this.scrollX;
        return x;
    }

    pinnedRight(): f64 {
        if (this.columns.length > 0 && this.columns[0].isConductor) return this.gutterW + this.columnWidth(this.columns[0]);
        return this.gutterW;
    }

    contentWidth(): f64 {
        let w = 0.0;
        for (let k = 0; k < this.columns.length; k++) w += this.columnWidth(this.columns[k]);
        return w;
    }

    gridTop(): f64 {
        return this.headerH;
    }

    // Screen y of grid line `gridLine`.
    lineY(gridLine: i32): f64 {
        return this.gridTop() + <f64>gridLine * this.lineH - this.scrollY;
    }

    // The grid line a document line of column `c` sits on.
    gridLineOf(c: Column, line: i32): i32 {
        if (line < c.map.band.length) return this.bands.tops[c.map.band[line]] + c.map.sub[line];
        // Below the end of the file: one band per missing line.
        let extra = line - c.map.band.length + 1;
        let band = min<i32>(c.map.bands - 1 + extra, this.bands.count - 1);
        return this.bands.tops[max<i32>(band, 0)];
    }

    // Character column of `ch` once a leading tab shows as INDENT spaces.
    displayCol(text: string, ch: i32): i32 {
        if (text.length > 0 && text.charCodeAt(0) == 9 && ch > 0) return ch + INDENT - 1;
        return ch;
    }

    chFromDisplay(text: string, col: i32): i32 {
        if (text.length > 0 && text.charCodeAt(0) == 9) {
            if (col < INDENT) return col * 2 < INDENT ? 0 : 1;
            return min<i32>(col - INDENT + 1, text.length);
        }
        return min<i32>(max<i32>(col, 0), text.length);
    }

    // The document position under a point in column `ci`.
    posAt(ci: i32, x: f64, y: f64): Pos {
        let c = this.columns[ci];
        let gridLine = <i32>Math.floor((y - this.gridTop() + this.scrollY) / this.lineH);
        gridLine = max<i32>(gridLine, 0);
        let band = this.bands.bandAt(gridLine);
        let sub = gridLine - this.bands.tops[band];
        let line: i32;
        if (band < c.map.bands && c.map.firstLine[band] >= 0) {
            line = c.map.firstLine[band] + min<i32>(sub, c.map.lineCount[band] - 1);
        } else {
            // Below the end of the file: the line that would sit on that row.
            line = c.doc.lines.length - 1 + (band - c.map.bands + 1);
        }
        let colX = this.columnX(ci) + this.padX;
        let col = <i32>Math.round((x - colX) / this.charW);
        let text = line < c.doc.lines.length ? c.doc.lines[line] : "";
        return new Pos(line, this.chFromDisplay(text, max<i32>(col, 0)));
    }

    columnAtX(x: f64): i32 {
        for (let i = 0; i < this.columns.length; i++) {
            let left = this.columnX(i);
            if (i > 0 && left < this.pinnedRight() - 1) {
                // Scrolled under the pinned conductor.
                if (x < this.pinnedRight()) continue;
            }
            if (x >= left && x < left + this.columnWidth(this.columns[i])) return i;
        }
        return -1;
    }

    maxScrollY(): f64 {
        return Math.max(0, <f64>this.bands.totalLines * this.lineH - (this.height - this.gridTop()) + this.lineH * 4);
    }

    clampScroll(): void {
        this.scrollY = Math.min(Math.max(this.scrollY, 0), this.maxScrollY());
        let visible = this.width - this.pinnedRight();
        let channels = this.contentWidth() - (this.pinnedRight() - this.gutterW);
        this.scrollX = Math.min(Math.max(this.scrollX, 0), Math.max(0, channels - visible + 20));
    }

    // Scrolls so the cursor is on screen.
    reveal(): void {
        let c = this.focused;
        if (c == null) return;
        let y = this.lineY(this.gridLineOf(c, c.doc.cursor.line));
        let top = this.gridTop() + this.lineH;
        let bottom = this.height - this.lineH * 2;
        if (y < top) this.scrollY -= top - y;
        else if (y > bottom) this.scrollY += y - bottom;
        if (this.focus > 0 && !c.isConductor) {
            let left = this.columnX(this.focus);
            let right = left + this.columnWidth(c);
            if (left < this.pinnedRight()) this.scrollX -= this.pinnedRight() - left;
            else if (right > this.width) this.scrollX += right - this.width;
        }
        this.clampScroll();
    }

    // --- Per frame -------------------------------------------------------------

    advance(seconds: f64): void {
        this.clock += seconds;
        for (let i = 0; i < this.columns.length; i++) this.columns[i].doc.clock = this.clock;
        if (this.follow && this.playing && this.playRow >= 0 && this.playRow < this.bands.count) {
            // Keep the playhead at 35 % of the view.
            let target = <f64>this.bands.tops[this.playRow] * this.lineH - (this.height - this.gridTop()) * 0.35;
            target = Math.min(Math.max(target, 0), this.maxScrollY());
            this.scrollY += (target - this.scrollY) * Math.min(1, seconds * 12);
        }
    }

    // The hint line: the signature of the command under the cursor, then the
    // first problem on the cursor's line.
    hint(): string {
        let c = this.focused;
        if (c == null) return "";
        let doc = c.doc;
        let line = doc.cursor.line;
        let text = doc.lines[line];
        let out = "";
        let name = commandAt(text, doc.cursor.ch);
        if (name.length > 0) {
            let spec = registry().get(name);
            if (spec != null) out = `${spec.signature()} — ${spec.summary}`;
        }
        for (let i = 0; i < c.diagnostics.length; i++) {
            let d = c.diagnostics[i];
            if (d.line == line + 1) {
                let sev = d.isError ? "error" : "warning";
                return `${c.doc.path}:${d.line}:${d.col}  ${sev} ${d.code}: ${d.message}`;
            }
        }
        return out;
    }

    // --- Drawing ---------------------------------------------------------------

    rect(renderer: Renderer, x: f64, y: f64, w: f64, h: f64, color: Color): void {
        if (w <= 0 || h <= 0) return;
        this.fill.style = PaintStyle.fill;
        this.fill.color = color;
        let p = this.path;
        p.reset();
        p.moveTo(Vector.xy(<f32>x, <f32>y));
        p.lineTo(Vector.xy(<f32>(x + w), <f32>y));
        p.lineTo(Vector.xy(<f32>(x + w), <f32>(y + h)));
        p.lineTo(Vector.xy(<f32>x, <f32>(y + h)));
        p.close();
        renderer.drawPath(p, this.fill);
    }

    textFor(text: string): Text? {
        if (this.styles.length == 0) return null;
        if (this.cache.has(text)) return this.cache.get(text);
        if (this.cache.size > CACHE_LIMIT) this.cache.clear();
        let shown = text;
        let lead = "";
        if (shown.length > 0 && shown.charCodeAt(0) == 9) {
            lead = "  ";
            shown = shown.substring(1);
        }
        let t = new Text();
        t.wrap = TextWrap.noWrap;
        if (lead.length > 0) t.append(lead, this.styles[Hue.Text]);
        let spans = highlight(text);
        let offset = lead.length > 0 ? 1 : 0;
        for (let i = 0; i < spans.length; i++) {
            let s = spans[i];
            let a = max<i32>(s.start - offset, 0);
            let b = s.end - offset;
            if (b <= a) continue;
            let piece = shown.substring(a, b).replaceAll("\t", " ");
            t.append(piece, this.styles[<i32>s.hue]);
        }
        if (t.isEmpty) t.append(" ", this.styles[Hue.Text]);
        this.cache.set(text, t);
        return t;
    }

    labelFor(text: string, bold: bool): Text? {
        let style = bold ? this.boldStyle : this.labelStyle;
        if (style == null) return null;
        let key = (bold ? "b:" : "l:") + text;
        if (this.labels.has(key)) return this.labels.get(key);
        let t = new Text();
        t.wrap = TextWrap.noWrap;
        t.append(text.length > 0 ? text : " ", style);
        this.labels.set(key, t);
        return t;
    }

    drawText(renderer: Renderer, t: Text?, x: f64, y: f64): void {
        if (t == null) return;
        renderer.save();
        renderer.transform(Mat2D.withTranslation(<f32>x, <f32>y));
        t.draw(renderer);
        renderer.restore();
    }

    draw(renderer: Renderer): void {
        let k = this.colors;
        this.rect(renderer, 0, 0, this.width, this.height, k.background);
        if (this.columns.length == 0) return;
        let top = this.gridTop();
        let firstLine = max<i32>(<i32>Math.floor(this.scrollY / this.lineH), 0);
        let lastLine = <i32>Math.ceil((this.scrollY + this.height - top) / this.lineH);
        let firstBand = this.bands.bandAt(firstLine);
        let lastBand = min<i32>(this.bands.bandAt(lastLine), this.bands.count - 1);

        // Conductor background and band shading across the whole width.
        if (this.columns[0].isConductor) {
            this.rect(renderer, this.gutterW, top, this.columnWidth(this.columns[0]), this.height - top, k.conductor);
        }
        let grid = this.grid;
        for (let b = firstBand; b <= lastBand; b++) {
            let y = this.lineY(this.bands.tops[b]);
            let h = <f64>this.bands.heights[b] * this.lineH;
            if (grid != null && b < grid.rows.length) {
                let g = grid.rows[b];
                if (g.rowInBeat == 0) this.rect(renderer, this.gutterW, y, this.width - this.gutterW, 1, g.beat == 0 ? k.bar : k.beat);
            }
            if (b == this.playRow) this.rect(renderer, 0, y, this.width, h, k.playhead);
        }

        // Cursor row and selection in the focused column.
        let fc = this.focused;
        if (fc != null) {
            let doc = fc.doc;
            let x0 = this.columnX(this.focus);
            let cy = this.lineY(this.gridLineOf(fc, doc.cursor.line));
            this.rect(renderer, x0, cy, this.columnWidth(fc), this.lineH, k.cursorRow);
            if (doc.hasSelection) {
                let a = doc.selStart();
                let e = doc.selEnd();
                for (let line = a.line; line <= e.line; line++) {
                    let text = doc.lines[line];
                    let from = line == a.line ? a.ch : 0;
                    let to = line == e.line ? e.ch : text.length;
                    let sx = x0 + this.padX + <f64>this.displayCol(text, from) * this.charW;
                    let ex = x0 + this.padX + <f64>this.displayCol(text, to) * this.charW + (line < e.line ? this.charW * 0.5 : 0);
                    let ly = this.lineY(this.gridLineOf(fc, line));
                    this.rect(renderer, sx, ly, ex - sx, this.lineH, k.selection);
                }
            }
        }

        // Columns: channels first (they scroll under the pinned conductor).
        let pinned = this.pinnedRight();
        for (let pass = 0; pass < 2; pass++) {
            for (let ci = 0; ci < this.columns.length; ci++) {
                let c = this.columns[ci];
                let isPinned = ci == 0 && c.isConductor;
                if ((pass == 0) == isPinned) continue;
                let x0 = this.columnX(ci);
                let w = this.columnWidth(c);
                if (x0 + w < (isPinned ? 0 : pinned) || x0 > this.width) continue;
                renderer.save();
                let clipLeft = isPinned ? x0 : Math.max(x0, pinned);
                this.clipRect(renderer, clipLeft, top, Math.max(x0 + w - clipLeft, 0), this.height - top);
                this.rect(renderer, x0 + w - 1, top, 1, this.height - top, k.divider);
                let doc = c.doc;
                for (let b = firstBand; b <= lastBand; b++) {
                    if (b >= c.map.bands) break;
                    let first = c.map.firstLine[b];
                    if (first < 0) continue;
                    for (let s = 0; s < c.map.lineCount[b]; s++) {
                        let line = first + s;
                        let text = doc.lines[line];
                        if (text.length == 0) continue;
                        let y = this.lineY(this.bands.tops[b] + s);
                        let tx = x0 + this.padX;
                        let ty = y + (this.lineH - <f64>this.fontSize * 1.2) * 0.5;
                        this.drawText(renderer, this.textFor(text), tx, ty);
                    }
                }
                // Problems: an underline under the span, a dot in the gutter.
                for (let d = 0; d < c.diagnostics.length; d++) {
                    let diag = c.diagnostics[d];
                    let line = diag.line - 1;
                    if (line < 0 || line >= doc.lines.length) continue;
                    let text = doc.lines[line];
                    let y = this.lineY(this.gridLineOf(c, line));
                    if (y < top - this.lineH || y > this.height) continue;
                    let sx = x0 + this.padX + <f64>this.displayCol(text, diag.col - 1) * this.charW;
                    let ex = x0 + this.padX + <f64>this.displayCol(text, max<i32>(diag.endCol - 1, diag.col)) * this.charW;
                    this.rect(renderer, sx, y + this.lineH - 3, Math.max(ex - sx, this.charW), 2, diag.isError ? k.error : k.warning);
                }
                if (ci == this.focus) this.drawCaret(renderer, c, x0);
                renderer.restore();
            }
        }

        // Gutter: bar.beat labels and marks.
        this.rect(renderer, 0, top, this.gutterW, this.height - top, k.gutter);
        for (let b = firstBand; b <= lastBand; b++) {
            let y = this.lineY(this.bands.tops[b]) + (this.lineH - 13) * 0.5;
            let label = `${b + 1}`;
            let strong = false;
            if (grid != null && b < grid.rows.length) {
                let g = grid.rows[b];
                label = g.label();
                strong = g.rowInBeat == 0;
            }
            this.drawText(renderer, this.labelFor(label, strong && grid != null && b < grid.rows.length && grid.rows[b].beat == 0), 8, y);
            if (b == this.playRow) {
                this.rect(renderer, 0, this.lineY(this.bands.tops[b]), 3, this.lineH, k.focus);
            }
        }
        // A dot in the gutter for every line with a problem.
        for (let ci = 0; ci < this.columns.length; ci++) {
            let c = this.columns[ci];
            for (let d = 0; d < c.diagnostics.length; d++) {
                let diag = c.diagnostics[d];
                let line = diag.line - 1;
                if (line < 0 || line >= c.doc.lines.length) continue;
                let y = this.lineY(this.gridLineOf(c, line));
                if (y < top - this.lineH || y > this.height) continue;
                this.rect(renderer, this.gutterW - 8, y + this.lineH * 0.5 - 2, 4, 4, diag.isError ? k.error : k.warning);
            }
        }
        this.drawHeaders(renderer);
    }

    clipRect(renderer: Renderer, x: f64, y: f64, w: f64, h: f64): void {
        let p = new Path();
        p.moveTo(Vector.xy(<f32>x, <f32>y));
        p.lineTo(Vector.xy(<f32>(x + w), <f32>y));
        p.lineTo(Vector.xy(<f32>(x + w), <f32>(y + h)));
        p.lineTo(Vector.xy(<f32>x, <f32>(y + h)));
        p.close();
        renderer.clipPath(p);
    }

    drawCaret(renderer: Renderer, c: Column, x0: f64): void {
        let doc = c.doc;
        let on = ((this.clock - this.blinkStart) % 1.0) < 0.6;
        if (!on) return;
        let text = doc.cursor.line < doc.lines.length ? doc.lines[doc.cursor.line] : "";
        let x = x0 + this.padX + <f64>this.displayCol(text, doc.cursor.ch) * this.charW;
        let y = this.lineY(this.gridLineOf(c, doc.cursor.line));
        this.rect(renderer, x - 0.5, y + 2, 2, this.lineH - 4, this.colors.caret);
    }

    drawHeaders(renderer: Renderer): void {
        let k = this.colors;
        let h = this.headerH;
        this.rect(renderer, 0, 0, this.width, h, k.header);
        this.rect(renderer, 0, h - 1, this.width, 1, k.divider);
        let pinned = this.pinnedRight();
        for (let pass = 0; pass < 2; pass++) {
            for (let ci = 0; ci < this.columns.length; ci++) {
                let c = this.columns[ci];
                let isPinned = ci == 0 && c.isConductor;
                if ((pass == 0) == isPinned) continue;
                let x0 = this.columnX(ci);
                let w = this.columnWidth(c);
                if (x0 > this.width || x0 + w < 0) continue;
                if (pass == 0) {
                    renderer.save();
                    this.clipRect(renderer, pinned, 0, this.width - pinned, h);
                }
                if (ci == this.focus) this.rect(renderer, x0, h - 3, w, 2, k.focus);
                this.drawText(renderer, this.labelFor(c.name, true), x0 + this.padX, (h - 16) * 0.5);
                if (!c.isConductor) {
                    let bx = x0 + w - 52;
                    this.rect(renderer, bx, 8, 16, 16, c.mute ? k.mute : k.off);
                    this.drawText(renderer, this.labelFor("M", true), bx + 4, 8);
                    this.rect(renderer, bx + 20, 8, 16, 16, c.solo ? k.solo : k.off);
                    this.drawText(renderer, this.labelFor("S", true), bx + 24, 8);
                    let level = Math.min(c.meter, 1.0);
                    this.rect(renderer, x0 + w - 10, 6, 4, 20, k.off);
                    this.rect(renderer, x0 + w - 10, 6 + 20 * (1 - level), 4, 20 * level, k.meter);
                }
                if (pass == 0) renderer.restore();
            }
        }
        this.rect(renderer, 0, 0, this.gutterW, h, k.header);
    }

    // --- Input -----------------------------------------------------------------

    pointerDown(e: PointerEvent): void {
        let x = <f64>e.position.x;
        let y = <f64>e.position.y;
        if (x < 0 || y < 0 || x > this.width || y > this.height) return;
        e.hit();
        let ci = this.columnAtX(x);
        if (ci < 0) return;
        if (y < this.headerH) {
            this.headerClick(ci, x);
            return;
        }
        this.focus = ci;
        let c = this.columns[ci];
        let p = this.posAt(ci, x, y);
        let doc = c.doc;
        if (p.line >= doc.lines.length) {
            // Clicking below the end makes the rows down to there.
            doc.ensureLine(p.line);
            this.relayout();
        }
        let double = this.clock - this.lastClickTime < 0.35 && this.lastClickPos.equals(p);
        if (double) {
            doc.selectWord(p);
        } else {
            doc.moveTo(p, false);
        }
        this.lastClickTime = this.clock;
        this.lastClickPos = p;
        this.dragging = !double;
        this.dragColumn = ci;
        this.blinkStart = this.clock;
    }

    pointerMove(e: PointerEvent): void {
        if (!this.dragging || this.dragColumn < 0) return;
        e.hit();
        let c = this.columns[this.dragColumn];
        let p = this.posAt(this.dragColumn, <f64>e.position.x, <f64>e.position.y);
        c.doc.moveTo(c.doc.clampPos(p), true);
    }

    pointerUp(e: PointerEvent): void {
        if (this.dragging) e.hit();
        this.dragging = false;
    }

    headerClick(ci: i32, x: f64): void {
        let c = this.columns[ci];
        this.focus = ci;
        if (c.isConductor) return;
        let bx = this.columnX(ci) + this.columnWidth(c) - 52;
        if (x >= bx && x < bx + 16) this.actions.push(`mute:${ci}`);
        else if (x >= bx + 20 && x < bx + 36) this.actions.push(`solo:${ci}`);
    }

    pointerScroll(e: ScrollEvent): void {
        let x = <f64>e.position.x;
        let y = <f64>e.position.y;
        if (x < 0 || y < 0 || x > this.width || y > this.height) return;
        e.hit();
        // `delta` follows the content, so content moving up means scrolling down.
        this.scrollY -= <f64>e.delta.y;
        this.scrollX -= <f64>e.delta.x;
        if (e.delta.y != 0) this.follow = false;
        this.clampScroll();
    }

    textInput(e: TextInput): bool {
        return this.typeText(e.text);
    }

    // Inserts typed text at the cursor (control characters are dropped).
    typeText(text: string): bool {
        let c = this.focused;
        if (c == null) return false;
        let clean = "";
        for (let i = 0; i < text.length; i++) {
            let code = text.charCodeAt(i);
            if (code >= 32 && code != 127) clean += String.fromCharCode(code);
        }
        if (clean.length == 0) return false;
        let doc = c.doc;
        doc.ensureLine(doc.cursor.line);
        doc.insert(clean, "type");
        this.edited();
        return true;
    }

    keyboard(e: KeyboardEvent): bool {
        return this.key(<i32>e.key, e.shift, e.control, e.alt, e.meta, e.phase);
    }

    // One key press; on macOS Cmd and elsewhere Ctrl act as Mod (§10.5).
    key(key: i32, shift: bool, control: bool, alt: bool, meta: bool, phase: string = "down"): bool {
        if (phase == "up") return false;
        let mod = meta || control;
        let c = this.focused;
        if (c == null) return false;
        let doc = c.doc;
        let pageLines = max<i32>(<i32>((this.height - this.headerH) / this.lineH) - 2, 1);

        // Transport and app commands.
        if (mod && key == KEY_ENTER) {
            this.actions.push(shift ? "playFromCursor" : "play");
            return true;
        }
        if (alt && key == KEY_ENTER) {
            this.actions.push("audition");
            return true;
        }
        if (mod && key == 46) {
            this.actions.push("stop");
            return true;
        }
        if (mod && key == 83) { // S
            this.actions.push(shift ? `solo:${this.focus}` : "save");
            return true;
        }
        if (mod && key == 77) { // M
            this.actions.push(`mute:${this.focus}`);
            return true;
        }
        if (mod && key == 76) { // L
            this.actions.push("loop");
            return true;
        }
        if (mod && key == 70) { // F
            this.follow = !this.follow;
            return true;
        }
        if (mod && key == 91) { // [
            this.switchColumn(-1);
            return true;
        }
        if (mod && key == 93) { // ]
            this.switchColumn(1);
            return true;
        }

        // Editing.
        if (mod && key == 90) { // Z
            if (shift ? doc.redo() : doc.undo()) this.edited();
            return true;
        }
        if (mod && key == 89) { // Y
            if (doc.redo()) this.edited();
            return true;
        }
        if (mod && key == 65) { // A
            doc.selectAll();
            return true;
        }
        if (mod && (key == 67 || key == 88)) { // C, X
            let text = doc.hasSelection ? doc.selectedText() : doc.lines[doc.cursor.line] + "\n";
            this.clipboard = text;
            this.actions.push("copied");
            if (key == 88) {
                if (doc.hasSelection) {
                    doc.checkpoint("");
                    doc.deleteSelection();
                } else {
                    doc.checkpoint("");
                    doc.anchor = new Pos(doc.cursor.line, 0);
                    doc.cursor = new Pos(min<i32>(doc.cursor.line + 1, doc.lines.length - 1), doc.cursor.line + 1 < doc.lines.length ? 0 : doc.lines[doc.cursor.line].length);
                    doc.deleteSelection();
                }
                this.edited();
            }
            return true;
        }
        if (mod && key == 86) { // V
            if (this.clipboard.length > 0) {
                doc.insert(this.clipboard, "paste");
                doc.breakUndo();
                this.edited();
            }
            return true;
        }
        if (mod && key == 68) { // D
            doc.duplicateRow();
            this.edited();
            return true;
        }
        if (alt && (key == KEY_UP || key == KEY_DOWN)) {
            doc.moveRow(key == KEY_UP ? -1 : 1);
            this.edited();
            return true;
        }

        if (key == KEY_ENTER) {
            doc.ensureLine(doc.cursor.line);
            // Shift+Enter opens a continuation line below.
            doc.insert(shift ? "\n\t" : "\n", "newline");
            this.edited();
            return true;
        }
        if (key == KEY_TAB) {
            doc.ensureLine(doc.cursor.line);
            doc.insert("\t", "type");
            this.edited();
            return true;
        }
        if (key == KEY_BACKSPACE) {
            doc.backspace();
            this.edited();
            return true;
        }
        if (key == KEY_DELETE) {
            doc.deleteForward();
            this.edited();
            return true;
        }
        if (key == KEY_ESCAPE) {
            doc.moveTo(doc.cursor, false);
            return true;
        }

        // Movement.
        let moved = true;
        if (key == KEY_LEFT) {
            if (mod) doc.home(shift);
            else doc.left(shift);
        } else if (key == KEY_RIGHT) {
            if (mod) doc.end(shift);
            else doc.right(shift);
        } else if (key == KEY_UP) {
            if (mod) doc.moveTo(new Pos(0, 0), shift);
            else doc.vertical(-1, shift);
        } else if (key == KEY_DOWN) {
            if (mod) doc.moveTo(new Pos(doc.lines.length - 1, 0), shift);
            else doc.vertical(1, shift);
        } else if (key == KEY_PAGE_UP) {
            doc.vertical(-pageLines, shift);
        } else if (key == KEY_PAGE_DOWN) {
            doc.vertical(pageLines, shift);
        } else if (key == KEY_HOME) {
            doc.home(shift);
        } else if (key == KEY_END) {
            doc.end(shift);
        } else {
            moved = false;
        }
        if (moved) {
            this.blinkStart = this.clock;
            this.reveal();
        }
        return moved;
    }

    switchColumn(delta: i32): void {
        if (this.columns.length == 0) return;
        let from = this.focused;
        let row = from != null && from.doc.cursor.line < from.map.band.length ? from.map.band[from.doc.cursor.line] : 0;
        this.focus = (this.focus + delta + this.columns.length) % this.columns.length;
        // Keep the same row in the new column.
        let c = this.columns[this.focus];
        if (row < c.map.bands && c.map.firstLine[row] >= 0) c.doc.moveTo(new Pos(c.map.firstLine[row], c.doc.cursor.ch), false);
        this.reveal();
    }

    // The source row under the cursor, for "play from cursor".
    cursorRow(): i32 {
        let c = this.focused;
        if (c == null) return 0;
        let line = c.doc.cursor.line;
        if (line < c.map.band.length) return c.map.band[line];
        return c.map.bands + (line - c.map.band.length);
    }
}

// The command whose statement holds character `ch` of `text`, or "".
export function commandAt(text: string, ch: i32): string {
    let skip = text.length > 0 && text.charCodeAt(0) == 9 ? 1 : 0;
    let tokens = lexLine(skip == 1 ? text.substring(1) : text, 1);
    let current = "";
    for (let i = 0; i < tokens.length; i++) {
        let t = tokens[i];
        let start = t.col - 1 + skip;
        if (start > ch) break;
        if (t.kind == Tok.Semi) current = "";
        else if (t.kind == Tok.Word && i + 1 < tokens.length && tokens[i + 1].kind == Tok.LParen) current = t.text;
    }
    return current;
}
