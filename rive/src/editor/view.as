// The channel grid (docs/spec.md §10): the gutter, one column per channel with
// the conductor first, time-aligned bands, one shared vertical scroll, the
// playhead, and text editing. It draws through a Renderer and takes input
// events; the app owns the song and the transport and talks to it through
// `columns`, `actions` and `changed`.

import { Font, Text, TextRunStyle, TextSizing, TextWrap } from "rive/text";
import { Renderer } from "rive/renderer";
import { Paint, PaintStyle, StrokeCap } from "rive/paint";
import { Path } from "rive/path";
import { Mat2D } from "rive/mat2d";
import { Vector } from "rive/vector";
import { Color } from "rive/color";
import { KeyboardEvent, PointerEvent, ScrollEvent, TextInput } from "rive/events";
import { Diagnostic, Diagnostics } from "../lang/diagnostics";
import { CommandNode } from "../lang/ast";
import { parseLine } from "../lang/parser";
import { registry } from "../lang/commands";
import { lexLine, Tok } from "../lang/lexer";
import { Grid } from "../score/timeline";
import { Bands, ColumnMap } from "./bands";
import { Doc, Pos } from "./doc";
import { highlight, Hue } from "./highlight";
import { Mark, Overview, OverviewMark } from "./overview";
import { DocBlock, docBlocks, DocKind } from "./docs";

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
export const COLLAPSED_WIDTH: f64 = 64; // a collapsed column (§10.6)
// Every column starts with its overview strip; expanded ones add the text after it.
export const STRIP: f64 = COLLAPSED_WIDTH;
export const EXTRA_BANDS: i32 = 48; // empty rows after the end, room to type
const CACHE_LIMIT: i32 = 3000;

export class Column {
    map: ColumnMap = new ColumnMap();
    diagnostics: Array<Diagnostic> = [];
    meter: f64 = 0;
    controls: bool = true; // M and S buttons (tracks only)
    collapsed: bool = false; // collapsed by the user
    folded: bool = false; // collapsed by the layout to make room (narrow windows)
    extraW: f64 = 0; // width the layout gives the selected column beyond its own
    color: u32 = 0xFFFFFFFF; // the track's identity colour (header dot, notes)
    overview: Overview? = null; // the overview strip, rebuilt on every compile

    get shut(): bool {
        return this.collapsed || this.folded;
    }

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

// Chrome colours use equal RGB channels only; colour is kept for code and
// for each track's musical marks (docs/spec.md §10.7).
class Palette {
    background: Color = 0xFF000000;
    gutter: Color = 0xFF000000;
    header: Color = 0xFF0A0A0A;
    conductor: Color = 0xFF050505;
    control: Color = 0xFF151515;
    beat: Color = 0xFF141414;
    bar: Color = 0xFF303030;
    divider: Color = 0xFF303030;
    edge: Color = 0xFF666666;
    cursorRow: Color = 0xFF1A1A1A;
    selection: Color = 0xFF3A3A3A;
    caret: Color = 0xFFFFFFFF;
    white: Color = 0xFFFFFFFF;
    secondary: Color = 0xFFA0A0A0;
    subdued: Color = 0xFF808080;
    label: Color = 0xFF808080;
    error: Color = 0xFFF05A6E;
    warning: Color = 0xFFE8A35C;
}

// Track identity colours, in column order (the conductor takes the first).
export const TRACK_COLORS: StaticArray<u32> = [
    0xFF8BD97A, 0xFF5AA9E6, 0xFFF2C46B, 0xFFF2557A, 0xFFB8E986,
    0xFF7FD6E6, 0xFFB48EF0, 0xFFF29B5A, 0xFFE6D38A, 0xFF9AA7FF,
];

export function trackColor(index: i32): u32 {
    return TRACK_COLORS[index % TRACK_COLORS.length];
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

    // Metrics (docs/spec.md §10.7): code at 13 px on 18 px lines, 28 px headers.
    fontSize: f32 = 13;
    lineH: f64 = 18; // height of a grid line: the text line, or a compact row
    textLineH: f64 = 18;
    // Row height when every column is collapsed; -1 fits the song to the view.
    compactRowH: f64 = -1;
    charW: f64 = 7.8;
    ascent: f64 = 10;
    headerH: f64 = 28;
    gutterW: f64 = 64;
    padX: f64 = 10;
    // Fold other tracks to their strips when the expanded ones do not fit.
    autoFit: bool = true;
    // Where the view sits in the layout (the rail and file list are to its left);
    // pointer positions are taken relative to it.
    originX: f64 = 0;
    // The overview strip's width (0 for files that are not on a time grid).
    strip: f64 = STRIP;
    // The "add a file" column after the last one ("" for none).
    addLabel: string = "";
    addWidth: f64 = 132;

    font: Font? = null;
    bold: Font? = null;
    ui: Font? = null;
    uiBold: Font? = null;
    styles: Array<TextRunStyle> = [];
    boldStyle: TextRunStyle? = null; // track names (selected)
    nameStyle: TextRunStyle? = null; // track names
    labelStyle: TextRunStyle? = null; // row numbers in the gutter
    beatStyle: TextRunStyle? = null; // bar.beat labels
    buttonStyle: TextRunStyle? = null; // M / S
    pressedStyle: TextRunStyle? = null; // M / S when on
    cache: Map<string, Text> = new Map<string, Text>();
    labels: Map<string, Text> = new Map<string, Text>();
    colors: Palette = new Palette();
    fill: Paint = new Paint();
    stroke: Paint = new Paint();
    path: Path = new Path();

    // The documentation panel (§10.8)
    docsOpen: bool = false;
    docsScroll: f64 = 0;
    // The docs anchor to open at when no command is under the cursor.
    docsTopic: string = "";
    docs: Array<DocBlock> = [];
    docsTexts: Array<Text?> = [];
    docsTops: Array<f64> = [];
    docsHeights: Array<f64> = [];
    docsAnchors: Map<string, f64> = new Map<string, f64>();
    docsLaidOutFor: f64 = -1;
    docsHeight: f64 = 0;
    titleStyle: TextRunStyle? = null;
    headingStyle: TextRunStyle? = null;
    paraStyle: TextRunStyle? = null;
    hintStyle: TextRunStyle? = null; // settings: field descriptions
    errorStyle: TextRunStyle? = null; // settings: a refused value
    valueStyle: TextRunStyle? = null; // settings: values in fields

    // Pointer state
    dragging: bool = false;
    dragColumn: i32 = -1;
    lastClickTime: f64 = -1;
    lastClickPos: Pos = new Pos(-1, -1);

    // `regular` and `bold` set the code (a narrow monospace); `ui` and `uiBold`
    // the labels (a condensed sans), falling back to the code face.
    setFonts(regular: Font?, bold: Font?, ui: Font? = null, uiBold: Font? = null): void {
        this.font = regular;
        this.bold = bold;
        this.ui = ui;
        this.uiBold = uiBold;
        this.styles = [];
        if (regular == null) return;
        let hues: Array<Color> = [
            0xFFE0E0E0, // Text
            0xFF6CB6FF, // Command
            0xFFB4B4B4, // Arg
            0xFFF2C46B, // Pitch
            0xFFB5E08A, // Number
            0xFFE8A87C, // String
            0xFF8C8C8C, // Punct
            0xFFF05A6E, // Error
            0xFFF28FCB, // Name
        ];
        for (let i = 0; i < hues.length; i++) this.styles.push(this.style(regular, hues[i], this.fontSize));
        let label = ui != null ? ui : regular;
        let labelBold = uiBold != null ? uiBold : (bold != null ? bold : regular);
        this.boldStyle = this.style(labelBold, this.colors.white, 13);
        this.nameStyle = this.style(label, this.colors.secondary, 13);
        this.labelStyle = this.style(regular, this.colors.subdued, 10);
        this.beatStyle = this.style(labelBold, this.colors.white, 13);
        this.buttonStyle = this.style(label, this.colors.secondary, 11);
        this.pressedStyle = this.style(labelBold, 0xFF000000, 11);
        this.titleStyle = this.style(labelBold, this.colors.white, 18);
        this.headingStyle = this.style(labelBold, this.colors.white, 14);
        this.paraStyle = this.style(label, this.colors.secondary, 13);
        this.hintStyle = this.style(label, this.colors.subdued, 12);
        this.errorStyle = this.style(label, this.colors.error, 12);
        this.valueStyle = this.style(regular, this.colors.white, 13);
        this.docsLaidOutFor = -1;
        this.lineH = this.textLineH;
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
        for (let i = 0; i < columns.length; i++) columns[i].color = trackColor(i);
        this.fit();
        this.relayout();
    }

    relayout(): void {
        let maps = new Array<ColumnMap>();
        for (let i = 0; i < this.columns.length; i++) {
            let c = this.columns[i];
            c.map = ColumnMap.build(c.doc.lines);
            maps.push(c.map);
        }
        // Keep the row at the top of the view through a change of row height.
        let topRow = this.bands.count > 0 ? this.bands.bandAt(<i32>Math.floor(this.scrollY / Math.max(this.lineH, 0.5))) : 0;
        let bands = Bands.build(maps, EXTRA_BANDS);
        if (this.allCollapsed) {
            // No text anywhere: a compact grid where the song fits the view (§10.6).
            this.bands = Bands.uniform(bands.count);
            this.lineH = this.compactRowH > 0 ? this.compactRowH : this.fitRowH();
        } else {
            this.bands = bands;
            this.lineH = this.textLineH;
        }
        if (topRow < this.bands.count) this.scrollY = <f64>this.bands.tops[topRow] * this.lineH;
        this.clampScroll();
    }

    // A compact row height that shows every row of the song at once.
    fitRowH(): f64 {
        let rows = 0;
        for (let i = 0; i < this.columns.length; i++) rows = max<i32>(rows, this.columns[i].map.bands);
        let space = this.height - this.gridTop() - this.textLineH;
        return Math.min(Math.max(space / <f64>max<i32>(rows, 1), 1.5), 12);
    }

    // Zooms the compact overview in (> 1) or out (< 1).
    zoom(factor: f64): void {
        this.compactRowH = Math.min(Math.max(this.lineH * factor, 1), 24);
        this.relayout();
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
        if (c.shut) return COLLAPSED_WIDTH;
        return this.strip + <f64>c.widthChars * this.charW + this.padX * 2 + c.extraW;
    }

    // Lays the columns out for the width (docs/spec.md §10.7): when the open
    // tracks do not fit, the others fold to their strips; the selected track
    // takes whatever width is left. Returns true when anything changed.
    fit(): bool {
        let changed = false;
        let avail = this.layoutWidth() - this.gutterW - (this.addLabel.length > 0 ? this.addWidth : 0);
        let need = 0.0;
        for (let i = 0; i < this.columns.length; i++) {
            let c = this.columns[i];
            c.extraW = 0;
            if (c.folded) {
                c.folded = false;
                changed = true;
            }
            need += this.columnWidth(c);
        }
        if (this.autoFit && need > avail) {
            for (let i = 0; i < this.columns.length; i++) {
                let c = this.columns[i];
                if (i != this.focus && !c.collapsed) {
                    c.folded = true;
                    changed = true;
                }
            }
        }
        // Re-folding the same columns is no change.
        let f = this.focused;
        if (f != null && !f.shut) {
            let used = 0.0;
            for (let i = 0; i < this.columns.length; i++) used += this.columnWidth(this.columns[i]);
            if (used < avail) f.extraW = Math.floor(avail - used);
        }
        return changed;
    }

    // Where a column's text starts (after its overview strip).
    textLeft(ci: i32): f64 {
        return this.columnX(ci) + this.strip + this.padX;
    }

    // --- Collapsing (§10.6) ---------------------------------------------------

    setCollapsed(ci: i32, collapsed: bool): void {
        if (ci < 0 || ci >= this.columns.length) return;
        this.columns[ci].collapsed = collapsed;
        this.relayout();
    }

    toggleCollapsed(ci: i32): void {
        if (ci < 0 || ci >= this.columns.length) return;
        this.setCollapsed(ci, !this.columns[ci].collapsed);
    }

    get allCollapsed(): bool {
        if (this.columns.length == 0) return false;
        for (let i = 0; i < this.columns.length; i++) if (!this.columns[i].collapsed) return false;
        return true;
    }

    // Collapses every column, or expands them all when all are collapsed.
    toggleAll(): void {
        let collapse = !this.allCollapsed;
        for (let i = 0; i < this.columns.length; i++) this.columns[i].collapsed = collapse;
        this.relayout();
    }

    // Typing into a collapsed column opens it first, so no edit is invisible.
    expandFocused(): void {
        let c = this.focused;
        if (c != null && c.collapsed) {
            c.collapsed = false;
            this.relayout();
            this.reveal();
        }
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
        let colX = this.textLeft(ci);
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

    // Which columns are folded, as a key to notice changes.
    foldKey(): string {
        let out = "";
        for (let i = 0; i < this.columns.length; i++) out += this.columns[i].folded ? "1" : "0";
        return out;
    }

    advance(seconds: f64): void {
        this.clock += seconds;
        let before = this.foldKey();
        this.fit();
        if (this.foldKey() != before) this.clampScroll();
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
        return this.labelIn(text, bold ? this.boldStyle : this.labelStyle, bold ? "b:" : "l:");
    }

    labelIn(text: string, style: TextRunStyle?, kind: string): Text? {
        if (style == null) return null;
        let key = kind + text;
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
        if (this.columns.length == 0) {
            if (this.docsOpen) this.drawDocs(renderer);
            return;
        }
        let top = this.gridTop();
        let firstLine = max<i32>(<i32>Math.floor(this.scrollY / this.lineH), 0);
        let lastLine = <i32>Math.ceil((this.scrollY + this.height - top) / this.lineH);
        let firstBand = this.bands.bandAt(firstLine);
        let lastBand = min<i32>(this.bands.bandAt(lastLine), this.bands.count - 1);
        let grid = this.grid;

        // Beat and bar rules across the grid (thinned out when rows are small).
        for (let b = firstBand; b <= lastBand; b++) {
            if (grid == null || b >= grid.rows.length) break;
            let g = grid.rows[b];
            if (g.rowInBeat != 0) continue;
            let beatPx = <f64>g.rpb * this.lineH;
            if (g.beat != 0 && beatPx < 10) continue;
            this.rect(renderer, this.gutterW, this.lineY(this.bands.tops[b]), this.width - this.gutterW, 1, g.beat == 0 ? k.bar : k.beat);
        }

        // The selected event: a neutral row fill in the focused track.
        let fc = this.focused;
        if (fc != null) {
            let x0 = this.columnX(this.focus);
            let cy = this.lineY(this.gridLineOf(fc, fc.doc.cursor.line));
            let band = this.cursorRow();
            let h = band < this.bands.count ? <f64>this.bands.heights[band] * this.lineH : this.lineH;
            let by = band < this.bands.count ? this.lineY(this.bands.tops[band]) : cy;
            this.rect(renderer, x0, by, this.columnWidth(fc), h, k.cursorRow);
            if (!fc.shut && fc.doc.hasSelection) {
                let doc = fc.doc;
                let a = doc.selStart();
                let e = doc.selEnd();
                for (let line = a.line; line <= e.line; line++) {
                    let text = doc.lines[line];
                    let from = line == a.line ? a.ch : 0;
                    let to = line == e.line ? e.ch : text.length;
                    let sx = x0 + this.strip + this.padX + <f64>this.displayCol(text, from) * this.charW;
                    let ex = x0 + this.strip + this.padX + <f64>this.displayCol(text, to) * this.charW + (line < e.line ? this.charW * 0.5 : 0);
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
                if (isPinned) this.rect(renderer, x0, top, w, this.height - top, k.conductor);
                this.rect(renderer, x0 + w - 1, top, 1, this.height - top, k.divider);
                let doc = c.doc;
                if (this.strip > 0) this.drawOverview(renderer, c, x0, firstBand, lastBand);
                if (c.shut) {
                    renderer.restore();
                    continue;
                }
                if (this.strip > 0) this.rect(renderer, x0 + this.strip - 1, top, 1, this.height - top, k.divider);
                // The selected event's marker: a white bar where the code starts.
                if (ci == this.focus) {
                    let band = this.cursorRow();
                    if (band < this.bands.count) {
                        this.rect(renderer, x0 + this.strip, this.lineY(this.bands.tops[band]), 2, <f64>this.bands.heights[band] * this.lineH, k.white);
                    }
                }
                for (let b = firstBand; b <= lastBand; b++) {
                    if (b >= c.map.bands) break;
                    let first = c.map.firstLine[b];
                    if (first < 0) continue;
                    for (let sub = 0; sub < c.map.lineCount[b]; sub++) {
                        let line = first + sub;
                        let text = doc.lines[line];
                        if (text.length == 0) continue;
                        let y = this.lineY(this.bands.tops[b] + sub);
                        let ty = y + (this.lineH - <f64>this.fontSize * 1.25) * 0.5;
                        this.drawText(renderer, this.textFor(text), x0 + this.strip + this.padX, ty);
                    }
                }
                // Problems: an underline under the span.
                for (let d = 0; d < c.diagnostics.length; d++) {
                    let diag = c.diagnostics[d];
                    let line = diag.line - 1;
                    if (line < 0 || line >= doc.lines.length) continue;
                    let text = doc.lines[line];
                    let y = this.lineY(this.gridLineOf(c, line));
                    if (y < top - this.lineH || y > this.height) continue;
                    let sx = x0 + this.strip + this.padX + <f64>this.displayCol(text, diag.col - 1) * this.charW;
                    let ex = x0 + this.strip + this.padX + <f64>this.displayCol(text, max<i32>(diag.endCol - 1, diag.col)) * this.charW;
                    this.rect(renderer, sx, y + this.lineH - 2, Math.max(ex - sx, this.charW), 1.5, diag.isError ? k.error : k.warning);
                }
                if (ci == this.focus) this.drawCaret(renderer, c, x0);
                renderer.restore();
            }
        }

        // The playhead: a thin white line across every track.
        if (this.playRow >= 0 && this.playRow < this.bands.count) {
            let py = this.lineY(this.bands.tops[this.playRow]);
            if (py >= top) this.rect(renderer, this.gutterW, py, this.width - this.gutterW, 1, k.white);
        }
        this.drawGutter(renderer, firstBand, lastBand);
        this.drawHeaders(renderer);
        if (this.docsOpen) this.drawDocs(renderer);
    }

    // --- Documentation panel (§10.8) -------------------------------------------

    // The width the tracks lay out in: the panel takes its share beside them
    // on wide windows, and covers them on narrow ones.
    layoutWidth(): f64 {
        if (this.docsOpen && this.width >= 720) return this.width - this.docsWidth();
        return this.width;
    }

    docsWidth(): f64 {
        // Beside the code on wide windows; over everything on narrow ones.
        return this.width < 720 ? this.width : Math.min(460, this.width - 120);
    }

    docsLeft(): f64 {
        return this.width - this.docsWidth();
    }

    toggleDocs(): void {
        if (this.docsOpen) this.docsOpen = false;
        else this.openDocs();
    }

    // Opens the panel at the command under the cursor, if there is one.
    openDocs(): void {
        this.docsOpen = true;
        this.layoutDocs();
        let c = this.focused;
        if (c == null) {
            if (this.docsTopic.length > 0 && this.docsAnchors.has(this.docsTopic)) this.docsScroll = this.docsAnchors.get(this.docsTopic);
            this.clampDocs();
            return;
        }
        let line = c.doc.cursor.line < c.doc.lines.length ? c.doc.lines[c.doc.cursor.line] : "";
        let name = commandAt(line, c.doc.cursor.ch);
        if (name.length > 0 && this.docsAnchors.has(name)) this.docsScroll = Math.max(this.docsAnchors.get(name) - 12, 0);
        else if (this.docsTopic.length > 0 && this.docsAnchors.has(this.docsTopic)) this.docsScroll = Math.max(this.docsAnchors.get(this.docsTopic) - 12, 0);
        this.clampDocs();
    }

    clampDocs(): void {
        let visible = this.height - this.headerH;
        this.docsScroll = Math.min(Math.max(this.docsScroll, 0), Math.max(this.docsHeight - visible + 24, 0));
    }

    layoutDocs(): void {
        let width = this.docsWidth() - 40;
        if (this.docsLaidOutFor == width) return;
        this.docsLaidOutFor = width;
        if (this.docs.length == 0) this.docs = docBlocks();
        this.docsTexts = [];
        this.docsTops = [];
        this.docsHeights = [];
        this.docsAnchors.clear();
        let y = 16.0;
        for (let i = 0; i < this.docs.length; i++) {
            let b = this.docs[i];
            let h = 0.0;
            let t: Text? = null;
            if (b.kind == DocKind.Code || b.kind == DocKind.Signature) {
                if (b.kind == DocKind.Signature) y += 10;
                let lines = b.text.split("\n");
                h = <f64>lines.length * this.textLineH + (b.kind == DocKind.Code ? 12 : 0);
            } else {
                let style = b.kind == DocKind.Title ? this.titleStyle : b.kind == DocKind.Heading ? this.headingStyle : this.paraStyle;
                if (b.kind == DocKind.Heading) y += 18;
                if (style != null) {
                    let text = new Text();
                    text.sizing = TextSizing.autoHeight;
                    text.wrap = TextWrap.wrap;
                    text.maxWidth = <f32>width;
                    text.append(b.text, style);
                    let bounds = text.bounds();
                    h = <f64>(bounds.v1.y - bounds.v0.y);
                    t = text;
                }
            }
            if (b.anchor.length > 0) this.docsAnchors.set(b.anchor, y);
            this.docsTexts.push(t);
            this.docsTops.push(y);
            this.docsHeights.push(h);
            y += h + 6;
        }
        this.docsHeight = y + 16;
    }

    drawDocs(renderer: Renderer): void {
        let k = this.colors;
        this.layoutDocs();
        let x0 = this.docsLeft();
        let w = this.docsWidth();
        this.rect(renderer, x0, 0, w, this.height, k.header);
        this.rect(renderer, x0, 0, 1, this.height, k.divider);
        // Header: title and close.
        this.rect(renderer, x0, this.headerH - 1, w, 1, k.divider);
        this.drawText(renderer, this.labelIn("Documentation", this.boldStyle, "n1:"), x0 + 14, (this.headerH - 16) * 0.5);
        let cx = x0 + w - 18;
        let cy = this.headerH * 0.5;
        this.line(renderer, cx - 4, cy - 4, cx + 4, cy + 4, 1.4, k.secondary);
        this.line(renderer, cx - 4, cy + 4, cx + 4, cy - 4, 1.4, k.secondary);
        renderer.save();
        this.clipRect(renderer, x0 + 1, this.headerH, w - 1, this.height - this.headerH);
        let left = x0 + 20;
        let top = this.headerH - this.docsScroll;
        for (let i = 0; i < this.docs.length; i++) {
            let y = top + this.docsTops[i];
            let h = this.docsHeights[i];
            if (y + h < this.headerH || y > this.height) continue;
            let b = this.docs[i];
            if (b.kind == DocKind.Code || b.kind == DocKind.Signature) {
                let lines = b.text.split("\n");
                let pad = b.kind == DocKind.Code ? 6.0 : 0.0;
                if (b.kind == DocKind.Code) this.rect(renderer, left - 8, y, w - 32, h, k.control);
                for (let l = 0; l < lines.length; l++) {
                    let ly = y + pad + <f64>l * this.textLineH + (this.textLineH - <f64>this.fontSize * 1.25) * 0.5;
                    this.drawText(renderer, this.textFor(lines[l]), left, ly);
                }
            } else {
                this.drawText(renderer, this.docsTexts[i], left, y);
            }
        }
        renderer.restore();
    }

    // A press on the panel: the close button, or nothing (it stops the editor
    // under it from taking the press). True when the panel took it.
    docsPointerDown(x: f64, y: f64): bool {
        if (!this.docsOpen || x < this.docsLeft()) return false;
        if (y < this.headerH && x > this.width - 36) this.docsOpen = false;
        return true;
    }

    // The gutter: bar.beat on each beat's first row, the row within the beat
    // in small figures beside it, and the playhead's marker.
    drawGutter(renderer: Renderer, firstBand: i32, lastBand: i32): void {
        let k = this.colors;
        let top = this.gridTop();
        this.rect(renderer, 0, top, this.gutterW, this.height - top, k.gutter);
        this.rect(renderer, this.gutterW - 1, top, 1, this.height - top, k.divider);
        let grid = this.grid;
        let lastLabel = -1000.0;
        for (let b = firstBand; b <= lastBand; b++) {
            let ly = this.lineY(this.bands.tops[b]);
            if (grid == null || b >= grid.rows.length) {
                if (this.lineH >= 12) this.drawText(renderer, this.labelIn(`${b + 1}`, this.labelStyle, "r:"), this.gutterW - 14, ly + (this.lineH - 12) * 0.5);
                continue;
            }
            let g = grid.rows[b];
            if (this.lineH >= 12) {
                // Row figures run down a narrow column beside the beat labels.
                this.drawText(renderer, this.labelIn(`${g.rowInBeat + 1}`, this.labelStyle, "r:"), this.gutterW - 14, ly + (this.lineH - 12) * 0.5);
                if (g.rowInBeat == 0) this.drawText(renderer, this.labelIn(`${g.bar + 1}.${g.beat + 1}`, this.beatStyle, "g:"), 12, ly + (this.lineH - 16) * 0.5);
            } else {
                // Compact rows: bars only (and beats where there is room), never overlapping.
                let barStart = g.rowInBeat == 0 && g.beat == 0;
                let beatStart = g.rowInBeat == 0 && <f64>g.rpb * this.lineH >= 16;
                if (!barStart && !beatStart) continue;
                if (ly - lastLabel < 16) continue;
                lastLabel = ly;
                let label = barStart ? `${g.bar + 1}` : `${g.bar + 1}.${g.beat + 1}`;
                this.drawText(renderer, this.labelIn(label, this.beatStyle, "g:"), 12, ly - 2);
            }
        }
        // Problems on the left edge of the gutter.
        for (let ci = 0; ci < this.columns.length; ci++) {
            let c = this.columns[ci];
            for (let d = 0; d < c.diagnostics.length; d++) {
                let diag = c.diagnostics[d];
                let line = diag.line - 1;
                if (line < 0 || line >= c.doc.lines.length) continue;
                let y = this.lineY(this.gridLineOf(c, line));
                if (y < top - this.lineH || y > this.height) continue;
                this.rect(renderer, 2, y + 3, 2, Math.max(this.lineH - 6, 2), diag.isError ? k.error : k.warning);
            }
        }
        if (this.playRow >= 0 && this.playRow < this.bands.count) {
            let py = this.lineY(this.bands.tops[this.playRow]);
            if (py >= top) {
                this.poly(renderer, [3, 10, 3], [py - 5, py, py + 5], k.white);
                this.rect(renderer, 10, py, this.gutterW - 10, 1, k.white);
            }
        }
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
        let x = x0 + this.strip + this.padX + <f64>this.displayCol(text, doc.cursor.ch) * this.charW;
        let y = this.lineY(this.gridLineOf(c, doc.cursor.line));
        this.rect(renderer, x - 0.5, y + 2, 1.5, this.lineH - 4, this.colors.caret);
    }

    // Header geometry: the M and S buttons sit at the right of an open header.
    soloX(ci: i32): f64 {
        return this.columnX(ci) + this.columnWidth(this.columns[ci]) - 26;
    }

    muteX(ci: i32): f64 {
        return this.soloX(ci) - 22;
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
                renderer.save();
                let clipLeft = isPinned ? x0 : Math.max(x0, pinned);
                this.clipRect(renderer, clipLeft, 0, Math.max(x0 + w - clipLeft, 0), h);
                if (isPinned) this.rect(renderer, x0, 0, w, h - 1, k.header);
                this.rect(renderer, x0 + w - 1, 0, 1, h, k.divider);
                let selected = ci == this.focus;
                this.drawChevron(renderer, x0 + 11, h * 0.5, c.shut);
                this.dot(renderer, x0 + 24, h * 0.5, 3.5, c.color, false);
                let name = c.shut && c.name.length > 4 ? c.name.substring(0, 4) : c.name;
                let style = selected ? this.boldStyle : this.nameStyle;
                this.drawText(renderer, this.labelIn(name, style, selected ? "n1:" : "n0:"), x0 + 32, (h - 16) * 0.5);
                if (selected) this.rect(renderer, x0, h - 1, w, 1, k.white);
                if (c.controls && !c.isConductor && !c.shut) {
                    this.toggleBox(renderer, this.muteX(ci), (h - 18) * 0.5, "M", c.mute);
                    this.toggleBox(renderer, this.soloX(ci), (h - 18) * 0.5, "S", c.solo);
                } else if (c.controls && !c.isConductor && (c.mute || c.solo)) {
                    // A collapsed track still says it is muted or soloed.
                    this.drawText(renderer, this.labelIn(c.solo ? "S" : "M", this.buttonStyle, "m0:"), x0 + w - 12, (h - 14) * 0.5);
                }
                renderer.restore();
            }
        }
        if (this.addLabel.length > 0) {
            let ax = this.addX();
            if (ax < this.width) {
                this.dot(renderer, ax + 14, h * 0.5, 6, k.control, false);
                this.line(renderer, ax + 11, h * 0.5, ax + 17, h * 0.5, 1.2, k.secondary);
                this.line(renderer, ax + 14, h * 0.5 - 3, ax + 14, h * 0.5 + 3, 1.2, k.secondary);
                this.drawText(renderer, this.labelIn(this.addLabel, this.nameStyle, "n0:"), ax + 26, (h - 16) * 0.5);
            }
        }
        this.rect(renderer, 0, 0, this.gutterW, h, k.header);
        this.rect(renderer, this.gutterW - 1, 0, 1, h, k.divider);
    }

    // Left edge of the "add a file" column.
    addX(): f64 {
        return this.columnX(this.columns.length);
    }

    // An M or S button: an explicit pressed fill when on (no colour).
    toggleBox(renderer: Renderer, x: f64, y: f64, label: string, on: bool): void {
        let k = this.colors;
        this.rect(renderer, x, y, 18, 18, on ? k.white : k.divider);
        this.rect(renderer, x + 1, y + 1, 16, 16, on ? k.white : k.control);
        let t = this.labelIn(label, on ? this.pressedStyle : this.buttonStyle, on ? "m1:" : "m0:");
        this.drawText(renderer, t, x + (label == "M" ? 4.5 : 5.5), y + 2);
    }

    // --- Overview (§10.6) -------------------------------------------------------

    // Screen y of a fractional source row.
    yAtRow(row: f64): f64 {
        let n = this.bands.count;
        if (n == 0) return this.lineY(0);
        let r = Math.max(row, 0);
        let b = <i32>Math.floor(r);
        if (b >= n) {
            let last = this.lineY(this.bands.tops[n - 1]) + <f64>this.bands.heights[n - 1] * this.lineH;
            return last + (r - <f64>n) * this.lineH;
        }
        return this.lineY(this.bands.tops[b]) + (r - <f64>b) * <f64>this.bands.heights[b] * this.lineH;
    }

    line(renderer: Renderer, x1: f64, y1: f64, x2: f64, y2: f64, width: f64, color: Color): void {
        let paint = this.stroke;
        paint.style = PaintStyle.stroke;
        paint.thickness = <f32>width;
        paint.color = color;
        paint.cap = StrokeCap.round;
        let p = this.path;
        p.reset();
        p.moveTo(Vector.xy(<f32>x1, <f32>y1));
        p.lineTo(Vector.xy(<f32>x2, <f32>y2));
        renderer.drawPath(p, paint);
    }

    dot(renderer: Renderer, x: f64, y: f64, r: f64, color: Color, hollow: bool): void {
        let p = this.path;
        p.reset();
        // A circle from four cubic arcs.
        let k = r * 0.5523;
        p.moveTo(Vector.xy(<f32>(x + r), <f32>y));
        p.cubicTo(Vector.xy(<f32>(x + r), <f32>(y + k)), Vector.xy(<f32>(x + k), <f32>(y + r)), Vector.xy(<f32>x, <f32>(y + r)));
        p.cubicTo(Vector.xy(<f32>(x - k), <f32>(y + r)), Vector.xy(<f32>(x - r), <f32>(y + k)), Vector.xy(<f32>(x - r), <f32>y));
        p.cubicTo(Vector.xy(<f32>(x - r), <f32>(y - k)), Vector.xy(<f32>(x - k), <f32>(y - r)), Vector.xy(<f32>x, <f32>(y - r)));
        p.cubicTo(Vector.xy(<f32>(x + k), <f32>(y - r)), Vector.xy(<f32>(x + r), <f32>(y - k)), Vector.xy(<f32>(x + r), <f32>y));
        p.close();
        if (hollow) {
            let paint = this.stroke;
            paint.style = PaintStyle.stroke;
            paint.thickness = 1.2;
            paint.color = color;
            renderer.drawPath(p, paint);
        } else {
            this.fill.style = PaintStyle.fill;
            this.fill.color = color;
            renderer.drawPath(p, this.fill);
        }
    }

    poly(renderer: Renderer, xs: StaticArray<f64>, ys: StaticArray<f64>, color: Color): void {
        let p = this.path;
        p.reset();
        p.moveTo(Vector.xy(<f32>xs[0], <f32>ys[0]));
        for (let i = 1; i < xs.length; i++) p.lineTo(Vector.xy(<f32>xs[i], <f32>ys[i]));
        p.close();
        this.fill.style = PaintStyle.fill;
        this.fill.color = color;
        renderer.drawPath(p, this.fill);
    }

    drawChevron(renderer: Renderer, x: f64, y: f64, collapsed: bool): void {
        let c: Color = 0xFF808080;
        // ▸ when collapsed (opens to the right), ▾ when open.
        if (collapsed) this.poly(renderer, [x - 2, x + 3, x - 2], [y - 4, y, y + 4], c);
        else this.poly(renderer, [x - 4, x + 4, x], [y - 2, y - 2, y + 3], c);
    }

    // The icon at the top of a mark (6 px).
    drawIcon(renderer: Renderer, m: OverviewMark, x: f64, y: f64, color: Color): void {
        let kind = m.kind;
        if (kind == Mark.Note) this.dot(renderer, x, y, 1.6 + m.weight * 1.4, color, false);
        else if (kind == Mark.Chord) this.dot(renderer, x, y, 2.2, color, true);
        else if (kind == Mark.Pattern) {
            this.rect(renderer, x - 3, y - 3, 6, 6, color);
            this.rect(renderer, x - 1, y - 1, 2, 2, 0xFF181B21);
        } else if (kind == Mark.Ramp) {
            if (m.to >= m.from) this.poly(renderer, [x, x + 3.5, x - 3.5], [y - 3, y + 3, y + 3], color);
            else this.poly(renderer, [x - 3.5, x + 3.5, x], [y - 3, y - 3, y + 3], color);
        } else if (kind == Mark.Lfo) {
            this.line(renderer, x - 3.5, y, x - 1.5, y - 2.5, 1.2, color);
            this.line(renderer, x - 1.5, y - 2.5, x + 1.5, y + 2.5, 1.2, color);
            this.line(renderer, x + 1.5, y + 2.5, x + 3.5, y, 1.2, color);
        } else if (kind == Mark.Glide) this.line(renderer, x - 3, y + 3, x + 3, y - 3, 1.5, color);
        else if (kind == Mark.Inst) this.poly(renderer, [x, x + 3.5, x, x - 3.5], [y - 3.5, y, y + 3.5, y], color);
        else if (kind == Mark.Cut) {
            this.line(renderer, x - 3, y - 3, x + 3, y + 3, 1.5, color);
            this.line(renderer, x - 3, y + 3, x + 3, y - 3, 1.5, color);
        } else if (kind == Mark.Flag) {
            this.line(renderer, x - 2, y - 4, x - 2, y + 4, 1.2, color);
            this.poly(renderer, [x - 2, x + 4, x - 2], [y - 4, y - 1.5, y + 1], color);
        } else if (kind == Mark.Tempo) this.poly(renderer, [x - 3, x + 3, x + 1, x - 1], [y + 3, y + 3, y - 3.5, y - 3.5], color);
        else this.rect(renderer, x - 2.5, y - 2.5, 5, 5, color);
    }

    drawOverview(renderer: Renderer, c: Column, x0: f64, firstBand: i32, lastBand: i32): void {
        let ov = c.overview;
        if (ov == null) return;
        let top = this.gridTop();
        let patternX = x0 + 5;
        let autoX = x0 + 16;
        let notesLeft = x0 + 25;
        let notesWidth = COLLAPSED_WIDTH - 31;
        let fromRow = <f64>firstBand - 64; // long marks that started above still show
        let toRow = <f64>lastBand + 1;
        let play = <f64>this.playRow;
        let marks = ov.marks;
        // Back to front: patterns, automation, notes, then marks across the column.
        for (let pass = 0; pass < 4; pass++) {
            for (let i = 0; i < marks.length; i++) {
                let m = marks[i];
                if (<i32>m.lane != pass) continue;
                let end = m.row + Math.max(m.length, 0) + m.tail;
                if (m.row > toRow || end < fromRow) continue;
                let y0 = this.yAtRow(m.row);
                let y1 = this.yAtRow(m.row + m.length);
                if (y1 < top || y0 > this.height) {
                    if (m.kind != Mark.Pattern && m.kind != Mark.Lfo && m.tail <= 0) continue;
                }
                let sounding = this.playRow >= 0 && play >= Math.floor(m.row) && play < m.row + Math.max(m.length, 1);
                this.drawMark(renderer, c, m, y0, y1, patternX, autoX, notesLeft, notesWidth, x0, sounding);
            }
        }
        // A tick where the source has a problem.
        for (let d = 0; d < c.diagnostics.length; d++) {
            let line = c.diagnostics[d].line - 1;
            if (line < 0 || line >= c.map.band.length) continue;
            let y = this.yAtRow(<f64>c.map.band[line]);
            this.rect(renderer, x0 + COLLAPSED_WIDTH - 5, y + 2, 3, this.lineH - 4, c.diagnostics[d].isError ? this.colors.error : this.colors.warning);
        }
    }

    drawMark(renderer: Renderer, c: Column, m: OverviewMark, y0: f64, y1: f64, patternX: f64, autoX: f64, notesLeft: f64, notesWidth: f64, x0: f64, sounding: bool): void {
        let ov = c.overview!;
        let kind = m.kind;
        // Musical marks take the track's colour; structural ones stay neutral (§10.7).
        let musical = kind == Mark.Note || kind == Mark.Chord || kind == Mark.Pattern || kind == Mark.Ramp ||
            kind == Mark.Lfo || kind == Mark.Glide || kind == Mark.Set || kind == Mark.Inst;
        let col: Color = musical ? c.color : (kind == Mark.Cut || kind == Mark.End ? this.colors.error : this.colors.white);
        if (kind == Mark.Note || kind == Mark.Chord) {
            let x = notesLeft + ov.pitchPos(m.pitch) * notesWidth;
            let alpha = (0.45 + m.weight * 0.55) * (m.fromPattern ? 0.8 : 1.0);
            let width = 1.2 + m.weight * 2.6;
            let bottom = Math.max(y1, y0 + 3);
            if (m.tail > 0) {
                // The echo of the sends: a faint continuation past the note.
                this.line(renderer, x, bottom, x, this.yAtRow(m.row + m.length + m.tail), 1, withAlpha(col, 0.18));
            }
            if (sounding) this.line(renderer, x, y0, x, bottom, width + 5, withAlpha(col, 0.28));
            this.line(renderer, x, y0, x, bottom, width, withAlpha(col, sounding ? 1.0 : alpha));
            // Heads only where rows leave room for them (compact rows are too tight).
            if (this.lineH >= 6) this.drawIcon(renderer, m, x, y0, withAlpha(col, sounding ? 1.0 : Math.min(alpha + 0.15, 1)));
        } else if (kind == Mark.Pattern) {
            let bottom = Math.max(y1, y0 + 4);
            this.rect(renderer, patternX - 3, y0, 6, bottom - y0, withAlpha(col, 0.28));
            // A tick at every repetition.
            let times = <i32>m.weight;
            if (times > 1 && times <= 64) {
                let each = m.length / <f64>times;
                for (let r = 1; r < times; r++) {
                    let y = this.yAtRow(m.row + each * <f64>r);
                    this.rect(renderer, patternX - 3, y, 6, 1, withAlpha(col, 0.7));
                }
            }
            this.drawIcon(renderer, m, patternX, y0 + 3, col);
        } else if (kind == Mark.Ramp) {
            // A wedge whose width follows the value from start to end.
            let bottom = Math.max(y1, y0 + 4);
            let w0 = 1 + 4.5 * m.from;
            let w1 = 1 + 4.5 * m.to;
            this.poly(renderer, [autoX - w0, autoX + w0, autoX + w1, autoX - w1], [y0, y0, bottom, bottom], withAlpha(col, 0.55));
            this.drawIcon(renderer, m, autoX, y0 + 3, col);
        } else if (kind == Mark.Lfo) {
            // A wave at the LFO's own rate (capped so it stays readable).
            let bottom = Math.min(Math.max(y1, y0 + 4), this.height + 20);
            let top = Math.max(y0, this.gridTop() - 20);
            let amp = 1.5 + 3.5 * m.weight;
            let cyclesPerPx = m.from / Math.max(this.lineH, 1);
            let paint = this.stroke;
            paint.style = PaintStyle.stroke;
            paint.thickness = 1.2;
            paint.color = withAlpha(col, 0.6);
            let p = this.path;
            p.reset();
            let started = false;
            let step = 3.0;
            for (let y = top; y <= bottom; y += step) {
                let phase = (y - y0) * Math.min(cyclesPerPx, 0.08) * 6.283185307179586;
                let x = autoX + Math.sin(phase) * amp;
                if (!started) {
                    p.moveTo(Vector.xy(<f32>x, <f32>y));
                    started = true;
                } else {
                    p.lineTo(Vector.xy(<f32>x, <f32>y));
                }
            }
            renderer.drawPath(p, paint);
            if (y0 >= this.gridTop() - 6) this.drawIcon(renderer, m, autoX, y0 + 3, col);
        } else if (kind == Mark.Glide) {
            let xa = notesLeft + ov.pitchPos(m.pitch) * notesWidth;
            let xb = notesLeft + ov.pitchPos(m.pitchTo) * notesWidth;
            this.line(renderer, xa, y0, xb, Math.max(y1, y0 + 4), 1.4, withAlpha(col, 0.75));
            this.drawIcon(renderer, m, xa, y0, col);
        } else if (kind == Mark.Inst || kind == Mark.Set || kind == Mark.Tempo || kind == Mark.Meter || kind == Mark.Master) {
            let y = y0 + 4;
            if (kind == Mark.Set || kind == Mark.Master) {
                // A short bar as long as the value.
                this.rect(renderer, autoX - 5, y - 1, 10 * Math.max(m.to, 0.08), 2, withAlpha(col, 0.85));
            } else {
                this.drawIcon(renderer, m, autoX, y, col);
            }
        } else if (kind == Mark.Cut) {
            this.rect(renderer, x0 + 3, y0 + 1, COLLAPSED_WIDTH - 6, 2, withAlpha(col, 0.8));
            this.drawIcon(renderer, m, autoX, y0 + 5, col);
        } else if (kind == Mark.Stop) {
            this.drawIcon(renderer, m, patternX, y0 + 4, col);
        } else if (kind == Mark.Flag) {
            this.rect(renderer, x0 + 2, y0, COLLAPSED_WIDTH - 4, 1, withAlpha(col, 0.5));
            this.drawIcon(renderer, m, x0 + 7, y0 + 5, col);
        } else if (kind == Mark.Jump) {
            // An arrow from this row back up to the mark it jumps to.
            let x = x0 + COLLAPSED_WIDTH - 10;
            let target = this.yAtRow(m.from);
            let from = y0 + this.lineH * 0.5;
            this.line(renderer, x, from, x, target + 2, 1.5, withAlpha(col, 0.8));
            this.line(renderer, x - 8, from, x, from, 1.5, withAlpha(col, 0.8));
            this.poly(renderer, [x, x + 3.5, x - 3.5], [target, target + 5, target + 5], col);
        } else if (kind == Mark.End) {
            this.rect(renderer, x0 + 2, y0 + this.lineH - 3, COLLAPSED_WIDTH - 4, 3, withAlpha(col, 0.9));
        }
    }

    // --- Input -----------------------------------------------------------------

    pointerDown(e: PointerEvent): void {
        let x = (<f64>e.position.x - this.originX);
        let y = <f64>e.position.y;
        if (x < 0 || y < 0 || x > this.width || y > this.height) return;
        e.hit();
        if (this.docsPointerDown(x, y)) return;
        let ci = this.columnAtX(x);
        if (ci < 0) {
            if (this.addLabel.length > 0 && y < this.headerH && x >= this.addX() && x < this.addX() + this.addWidth) this.actions.push("newFile");
            return;
        }
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
        let p = this.posAt(this.dragColumn, (<f64>e.position.x - this.originX), <f64>e.position.y);
        c.doc.moveTo(c.doc.clampPos(p), true);
    }

    pointerUp(e: PointerEvent): void {
        if (this.dragging) e.hit();
        this.dragging = false;
    }

    headerClick(ci: i32, x: f64): void {
        let c = this.columns[ci];
        this.focus = ci;
        let x0 = this.columnX(ci);
        // The chevron, or anywhere on a header the user collapsed, toggles it;
        // a header folded for room only takes the selection (which opens it).
        if (x < x0 + 18 || c.collapsed) {
            this.toggleCollapsed(ci);
            return;
        }
        if (c.folded || c.isConductor || !c.controls) return;
        let mx = this.muteX(ci);
        let sx = this.soloX(ci);
        if (x >= mx && x < mx + 18) this.actions.push(`mute:${ci}`);
        else if (x >= sx && x < sx + 18) this.actions.push(`solo:${ci}`);
    }

    pointerScroll(e: ScrollEvent): void {
        let x = (<f64>e.position.x - this.originX);
        let y = <f64>e.position.y;
        if (x < 0 || y < 0 || x > this.width || y > this.height) return;
        e.hit();
        if (this.docsOpen && x >= this.docsLeft()) {
            this.docsScroll -= <f64>e.delta.y;
            this.clampDocs();
            return;
        }
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
        this.expandFocused();
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
        let pageLines = max<i32>(<i32>((this.height - this.headerH) / this.lineH) - 2, 1);

        // App-wide keys first: they work in a tab with nothing to edit too.
        if (mod && key >= 49 && key <= 53) { // 1–5: tracks, patterns, instruments, samples, settings
            this.actions.push(`tab:${key - 49}`);
            return true;
        }
        if (mod && key == 44) { // Cmd+,: settings
            this.actions.push("tab:4");
            return true;
        }
        if (key == 290 || (mod && key == 47)) { // F1, Cmd+/: the documentation
            this.toggleDocs();
            return true;
        }
        if (key == KEY_ESCAPE && this.docsOpen) {
            this.docsOpen = false;
            return true;
        }
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
        if (mod && key == 83 && !shift) { // S
            this.actions.push("save");
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

        // The rest needs a column.
        let c = this.focused;
        if (c == null) return false;
        let doc = c.doc;
        if (mod && key == 83) { // Shift+S
            this.actions.push(`solo:${this.focus}`);
            return true;
        }
        if (mod && key == 77) { // M
            this.actions.push(`mute:${this.focus}`);
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

        if (mod && this.allCollapsed && (key == 61 || key == 45)) { // = and -: zoom the overview
            this.zoom(key == 61 ? 1.25 : 0.8);
            return true;
        }
        if (mod && key == 69) { // E: collapse this column, or every column with Shift
            if (shift) this.toggleAll();
            else this.toggleCollapsed(this.focus);
            return true;
        }

        // Editing: a collapsed column opens first.
        let edits = (mod && (key == 90 || key == 89 || key == 88 || key == 86 || key == 68)) ||
            (alt && (key == KEY_UP || key == KEY_DOWN)) ||
            key == KEY_ENTER || key == KEY_TAB || key == KEY_BACKSPACE || key == KEY_DELETE;
        if (edits && c.collapsed) this.expandFocused();
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

// `color` with its alpha replaced by `alpha` (0..1).
export function withAlpha(color: u32, alpha: f64): u32 {
    let a = <u32>Math.round(Math.min(Math.max(alpha, 0), 1) * 255);
    return (a << 24) | (color & 0x00FFFFFF);
}

// A few words for the command under the cursor, for the footer's breadcrumb:
// "F3 maj7" for a chord, "C4 · 1/8" for a note, the name otherwise.
export function summaryAt(text: string, ch: i32): string {
    let skip = text.length > 0 && text.charCodeAt(0) == 9 ? 1 : 0;
    let d = new Diagnostics("");
    let commands = parseLine(skip == 1 ? text.substring(1) : text, 1, 1 + skip, d);
    if (commands.length == 0) return "";
    let pick = commands[0];
    for (let i = 0; i < commands.length; i++) {
        if (commands[i].col - 1 <= ch) pick = commands[i];
    }
    let arg = (name: string, node: CommandNode): string => {
        let a = node.arg(name);
        return a != null ? a.value.text : "";
    };
    let n = pick.name;
    if (n == "chord") return `${arg("root", pick)} ${arg("type", pick)}`.trim();
    if (n == "note") {
        let len = arg("len", pick);
        return arg("p", pick) + (len.length > 0 ? ` · ${len}` : "");
    }
    if (n == "pattern") {
        let times = arg("times", pick);
        return `pattern ${arg("name", pick)}${times.length > 0 ? " ×" + times : ""}`;
    }
    if (n == "inst") return arg("name", pick);
    if (pick.args.length > 0) return `${n} ${pick.args[0].name}: ${pick.args[0].value.text}`;
    return n;
}
