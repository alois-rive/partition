// The Partition app (docs/spec.md §10–§11): the editor grid, the song and its
// compiled score, the transport, WAV export, and the view model that the RML
// chrome and a host drive it through.

import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { Mat2D } from "rive/mat2d";
import { KeyboardEvent, PointerEvent, ScrollEvent, TextInput } from "rive/events";
import { ViewModel } from "rive/data";
import { Audio } from "rive/audio";
import { parseBundle, SongFile } from "../lang/bundle";
import { Buffer } from "rive/buffer";
import { CONDUCTOR_PATH, SONG_YAML } from "../lang/config";
import { Diagnostic } from "../lang/diagnostics";
import { Song } from "../lang/song";
import { CheckedFile } from "../lang/check";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { Grid, GridRow } from "../score/timeline";
import { Rail, RAIL_WIDTH } from "../editor/rail";
import { FileList, LIST_WIDTH } from "../editor/filelist";
import { SettingsPanel } from "../editor/settings";
import { isName } from "../lang/types";
import { renameReferences } from "../lang/rename";
import { INSTRUMENTS_DIR, PATTERNS_DIR } from "../lang/song";
import { MAX_CHANNELS } from "../synth/engine";
import { Column, EditorView, summaryAt } from "../editor/view";
import { Doc, Pos } from "../editor/doc";
import { buildOverview } from "../editor/overview";
import { Bindings, itemNum, itemStr, newItem, setItemBool, setItemColor, setItemNum, setItemStr } from "./bindings";
import { exampleBundle, exampleInfo, examples } from "./examples";
import { ExportState, exportStateName, Exporter, formatId } from "./exporter";
import { Transport, TransportState } from "./transport";

export const COMPILE_DELAY: f64 = 0.15; // seconds after the last edit
export const CHANGED_DELAY: f64 = 0.3; // before telling the host (§11.3)
export const DEFAULT_EXAMPLE: string = "deep-house";
// Toolbar toggles (loop, follow): lit when on.
export const TOGGLE_ON: u32 = 0xFF3B5E8C;
export const TOGGLE_OFF: u32 = 0xFF2B303B;

// The examples dropdown as scene.rml lays it out (§10.1): two columns of rows,
// pinned to the right edge just under the toolbar.
export const MENU_WIDTH: f64 = 616;
export const MENU_RIGHT: f64 = 8;
export const MENU_ROW: f64 = 26;
export const MENU_GAP: f64 = 2;
export const MENU_PAD: f64 = 4;
// The narrow layout (docs/spec.md §10.7) starts below this width.
export const NARROW_WIDTH: f64 = 1000;
// The "More" popover and the Diagnostics popover, as tools/gen_scene.py lays them out.
export const MORE_WIDTH: f64 = 196;
export const MORE_HEIGHT: f64 = 4 * 2 + 6 * 26 + 5 * 2;
export const DIAG_WIDTH: f64 = 576;
export const DIAG_ROW: f64 = 24;
export const DIAG_LIMIT: i32 = 20;
// Toggle looks (equal RGB channels only).
export const LOOK_FILL: u32 = 0xFF151515;
export const LOOK_FILL_ON: u32 = 0xFF222222;
export const LOOK_INK: u32 = 0xFFA0A0A0;
export const LOOK_INK_ON: u32 = 0xFFFFFFFF;
export const LOOK_EDGE: u32 = 0xFF303030;
export const LOOK_EDGE_ON: u32 = 0xFF666666;

// A column wide enough for its longest line, within reason.
function autoWidth(doc: Doc, least: i32): i32 {
    let longest = 0;
    for (let i = 0; i < doc.lines.length; i++) {
        let line = doc.lines[i];
        let n = line.length > 0 && line.charCodeAt(0) == 9 ? line.length + 1 : line.length;
        longest = max<i32>(longest, n);
    }
    return min<i32>(max<i32>(longest + 2, least), 64);
}

export class Partition extends Layout {
    context: Context? = null;
    vm: Bindings? = null;
    ready: bool = false;
    framesWithoutVm: i32 = 0;
    // One editor per tab (§10.9): tracks, patterns, instruments, and an empty
    // one for the settings tab (its keys and documentation panel). `view` is
    // the one on screen.
    tracksView: EditorView = new EditorView();
    patternsView: EditorView = new EditorView();
    instrumentsView: EditorView = new EditorView();
    settingsView: EditorView = new EditorView();
    settings: SettingsPanel = new SettingsPanel();
    view: EditorView = new EditorView();
    tab: i32 = 0;
    auditioning: bool = false;
    auditionPath: string = "";
    rail: Rail = new Rail();
    patternList: FileList = new FileList("Patterns", "pattern");
    instrumentList: FileList = new FileList("Instruments", "instrument");
    // Editor columns of pattern and instrument files, kept (with their undo
    // history) while the files exist.
    fileColumnCache: Map<string, Column> = new Map<string, Column>();
    layoutW: f64 = 1280;
    layoutH: f64 = 700;
    transport: Transport = new Transport();
    exporter: Exporter = new Exporter();
    song: Song = new Song();
    score: Score? = null;
    clock: f64 = 0;
    compileAt: f64 = -1;
    changedAt: f64 = -1;
    changedPaths: Array<string> = [];
    startRow: i32 = 0;
    userLoop: bool = false;
    loopStartRow: i32 = 0;
    loopEndRow: i32 = 0;
    message: string = "";
    messageUntil: f64 = 0;
    // Host side of the files: the revision last seen for each path.
    seenRevision: Map<string, f64> = new Map<string, f64>();
    pollFilesIn: f64 = 0;
    reportedFailures: i32 = 0;
    menuOpen: bool = false;
    moreOpen: bool = false;
    diagnosticsOpen: bool = false;
    narrow: bool = false;
    editedSinceLoad: bool = false;
    diagnosticItems: Array<Diagnostic> = [];
    currentExample: string = "";
    // Opened by the Rust shell (docs/spec.md §12): the song came from the
    // `host-song` blob, and changes go back as PARTITION-HOST lines on the log.
    hostBridge: bool = false;
    hostPaths: Array<string> = [];
    hostAt: f64 = -1;
    hostReady: bool = false;
    exampleItems: Array<ViewModel> = [];

    views(): Array<EditorView> {
        return [this.tracksView, this.patternsView, this.instrumentsView, this.settingsView];
    }

    override init(context: Context): bool {
        this.context = context;
        this.view = this.tracksView;
        this.patternsView.docsTopic = "patterns";
        this.instrumentsView.docsTopic = "instruments";
        this.instrumentsView.strip = 0;
        this.settingsView.docsTopic = "settings";
        this.settingsView.strip = 0;
        let views = this.views();
        for (let i = 0; i < views.length; i++) {
            views[i].setFonts(context.font("mono"), context.font("mono-bold"), context.font("ui"), context.font("ui-bold"));
        }
        this.tryStart();
        return true;
    }

    // The player builds this layout once without a view model and throws it
    // away (docs/m0-findings.md), so nothing starts until one is bound, or
    // until a few frames show there will not be one.
    tryStart(): void {
        if (this.ready) return;
        let context = this.context!;
        let vm = Bindings.bind(context.viewModel());
        if (vm == null && this.framesWithoutVm < 3) return;
        this.vm = vm;
        this.ready = true;
        this.publishExamples();
        if (this.openHostSong()) return;
        let id = DEFAULT_EXAMPLE;
        let autoplay = false;
        if (vm != null) {
            let requested = vm.str(vm.song, "exampleId", "");
            if (requested.length > 0) id = requested;
            autoplay = vm.bool(vm.song, "autoplay");
        }
        this.loadExample(id);
        if (autoplay) this.playFrom(0);
    }

    // The song the shell put in the `host-song` blob, if any.
    openHostSong(): bool {
        let context = this.context!;
        let bytes = context.blob("host-song");
        if (bytes == null) return false;
        let bundle = parseBundle("host-song", Buffer.tostring(bytes));
        if (bundle.diagnostics.items.length > 0 || bundle.files.length == 0) return false;
        this.hostBridge = true;
        let vm = this.vm;
        if (vm != null) vm.setBool(vm.app, "app", "hosted", true);
        this.setSong(Song.fromFiles(bundle.files));
        this.publishFiles();
        this.currentExample = "";
        this.markCurrentExample();
        this.say(`opened ${this.song.config.title}`);
        return true;
    }

    // One message to the shell: a JSON object on its own log line.
    hostSend(json: string): void {
        let c = this.context;
        if (this.hostBridge && c != null) c.log("PARTITION-HOST " + json);
    }

    // A file the shell should write (or delete, when the song no longer has it).
    hostChanged(path: string): void {
        if (!this.hostBridge) return;
        if (!this.hostPaths.includes(path)) this.hostPaths.push(path);
        this.hostAt = this.clock + CHANGED_DELAY;
    }

    flushHost(): void {
        if (this.hostAt < 0 || this.clock < this.hostAt) return;
        this.hostAt = -1;
        for (let i = 0; i < this.hostPaths.length; i++) {
            let path = this.hostPaths[i];
            if (this.song.files.has(path)) this.hostSend(`{"op":"write","path":${jsonString(path)},"text":${jsonString(this.song.text(path))}}`);
            else this.hostSend(`{"op":"remove","path":${jsonString(path)}}`);
        }
        this.hostPaths = [];
    }

    override dispose(): void {
        this.transport.dispose();
        this.exporter.cancel();
    }

    override resize(width: f64, height: f64, scale: f64): void {
        this.narrow = width < NARROW_WIDTH;
        this.layoutW = width;
        this.layoutH = height;
        this.rail.height = height;
        let views = this.views();
        for (let i = 0; i < views.length; i++) {
            // Tracks and settings sit right of the rail; files right of the rail and the list.
            let left = i == 1 || i == 2 ? RAIL_WIDTH + LIST_WIDTH : RAIL_WIDTH;
            views[i].originX = left;
            views[i].width = Math.max(width - left, 120);
            views[i].height = height;
            views[i].fit();
            views[i].relayout();
        }
    }

    listFor(tab: i32): FileList {
        return tab == 2 ? this.instrumentList : this.patternList;
    }

    // --- Tabs (§10.9) --------------------------------------------------------------

    setTab(tab: i32): void {
        if (tab < 0 || tab > 3 || tab == this.tab) return;
        let docs = this.view.docsOpen;
        this.closePopovers();
        this.tab = tab;
        this.rail.tab = tab;
        this.view = this.views()[tab];
        if (docs && !this.view.docsOpen) this.view.openDocs();
        else if (!docs) this.view.docsOpen = false;
        if (tab == 3) {
            this.settings.cancelEdit();
            this.settings.load(this.song.text(SONG_YAML));
        }
        this.view.fit();
        this.view.relayout();
    }

    // The patterns and instruments tabs: a file list and one file.
    get fileTab(): bool {
        return this.tab == 1 || this.tab == 2;
    }

    // --- Settings (§10.10) ---------------------------------------------------------

    // What the settings form changed: track files to add or remove, the live
    // mix, and song.yaml itself.
    applySettings(): void {
        let actions = this.settings.takeActions();
        let removed = new Array<string>();
        for (let i = 0; i < actions.length; i++) {
            let a = actions[i];
            if (a.startsWith("trackAdd:")) {
                let path = a.substring(9);
                if (!this.song.files.has(path)) {
                    this.song.setFile(path, "");
                    this.writeFileToVm(path, "", true);
                }
            } else if (a.startsWith("trackDelete:")) {
                removed.push(a.substring(12));
            } else if (a.startsWith("trackMix:")) {
                let parts = a.split(":");
                let columns = this.tracksView.columns;
                for (let c = 1; c < columns.length; c++) {
                    if (columns[c].doc.path != parts[1]) continue;
                    columns[c].mute = parts[2] == "1";
                    columns[c].solo = parts[3] == "1";
                }
                this.applyMix();
            }
        }
        let yaml = this.settings.takeYaml();
        if (yaml.length == 0) return;
        this.fileEdited(SONG_YAML, yaml);
        for (let i = 0; i < removed.length; i++) {
            let path = removed[i];
            let used = false;
            for (let c = 0; c < this.song.channels.length; c++) if (this.song.channels[c].config.file == path) used = true;
            if (used || !this.song.files.has(path)) continue;
            this.song.removeFile(path);
            this.removeFileFromVm(path);
        }
        this.syncTracks();
    }

    // The track columns after song.yaml changed: kept columns keep their text,
    // undo history and live mix; new tracks get a column, removed ones lose it.
    syncTracks(): void {
        let old = this.tracksView.columns;
        let byPath = new Map<string, Column>();
        for (let i = 1; i < old.length; i++) byPath.set(old[i].doc.path, old[i]);
        let focused = this.tracksView.focused;
        let focusPath = focused != null ? focused.doc.path : "";
        let columns = new Array<Column>();
        if (old.length > 0) columns.push(old[0]);
        else {
            let conductor = new Doc(CONDUCTOR_PATH, this.song.text(CONDUCTOR_PATH));
            columns.push(new Column(conductor, "conductor", autoWidth(conductor, 22), true, false, false));
        }
        let channels = this.song.channels;
        for (let i = 0; i < channels.length; i++) {
            let ch = channels[i];
            let path = ch.config.file;
            let c: Column;
            if (byPath.has(path)) {
                c = byPath.get(path);
                c.name = ch.name;
            } else {
                c = new Column(new Doc(path, this.song.text(path)), ch.name, 26, false, ch.config.mute, ch.config.solo);
            }
            c.widthChars = ch.config.widthSet ? ch.config.width : autoWidth(c.doc, 26);
            columns.push(c);
        }
        this.tracksView.setColumns(columns);
        for (let i = 0; i < columns.length; i++) if (columns[i].doc.path == focusPath) this.tracksView.focus = i;
        this.applyMix();
        this.compileAt = this.clock + COMPILE_DELAY;
    }

    // The tab and view that edit `path`.
    tabOf(path: string): i32 {
        if (path.startsWith(PATTERNS_DIR)) return 1;
        if (path.startsWith(INSTRUMENTS_DIR)) return 2;
        return 0;
    }

    // The file lists and, in each file tab, the column of the selected file.
    refreshFileTabs(): void {
        this.refreshList(1);
        this.refreshList(2);
    }

    refreshList(tab: i32): void {
        let list = this.listFor(tab);
        let pattern = tab == 1;
        let names = pattern ? this.song.patternNames : this.song.instrumentNames;
        list.names = [];
        list.details = [];
        for (let i = 0; i < names.length; i++) {
            list.names.push(names[i]);
            let file = pattern ? this.song.patterns.get(names[i]) : this.song.instruments.get(names[i]);
            if (pattern) {
                list.details.push(`${file.rowCount} rows`);
            } else {
                // The preset it starts from, if any.
                let base = "";
                let cmds = file.commands();
                for (let k = 0; k < cmds.length; k++) if (cmds[k].name == "base") base = cmds[k].str("preset", "");
                list.details.push(base);
            }
        }
        if (!list.names.includes(list.selected)) list.selected = list.names.length > 0 ? list.names[0] : "";
        this.showFile(tab, list.selected);
    }

    // Puts file `name` of a tab in that tab's editor.
    showFile(tab: i32, name: string): void {
        let list = this.listFor(tab);
        let view = this.views()[tab];
        list.selected = name;
        if (name.length == 0) {
            view.setColumns([]);
            return;
        }
        let pattern = tab == 1;
        let path = (pattern ? PATTERNS_DIR : INSTRUMENTS_DIR) + name + (pattern ? ".pat" : ".inst");
        let c: Column;
        if (this.fileColumnCache.has(path)) {
            c = this.fileColumnCache.get(path);
            if (c.doc.text() != this.song.text(path) && !(pattern && c.doc.lines.join("\n") + "\n" == this.song.text(path))) c.doc.replaceAll(this.song.text(path));
        } else {
            let doc = new Doc(path, this.song.text(path));
            doc.keepTrailing = pattern; // a pattern's trailing rests are part of its length
            c = new Column(doc, name, autoWidth(doc, pattern ? 24 : 40), false, false, false);
            c.controls = false;
            this.fileColumnCache.set(path, c);
        }
        c.name = name;
        view.setColumns([c]);
        view.focus = 0;
        view.fit();
        view.relayout();
        // A pattern shown for the first time gets its overview now; edits rebuild it on compile.
        if (pattern && c.overview == null && this.patternsView.grid != null) {
            let file = this.song.checked(path);
            if (file != null) {
                let ov = buildOverview(file!, this.song, this.patternsView.grid!, [this.song.config.bpm]);
                ov.revision = this.song.revision;
                c.overview = ov;
            }
        }
    }

    // A grid for the patterns tab: the song's meter from row 0, with no conductor.
    patternGrid(): Grid {
        let g = new Grid();
        let config = this.song.config;
        let rows = 0;
        let columns = this.patternsView.columns;
        for (let i = 0; i < columns.length; i++) rows = max<i32>(rows, columns[i].map.bands);
        rows += 64;
        let perBar = config.rowsPerBeat * config.sigNum;
        for (let r = 0; r < rows; r++) {
            let row = new GridRow();
            row.rpb = config.rowsPerBeat;
            row.sigNum = config.sigNum;
            row.sigDen = config.sigDen;
            row.bar = r / perBar;
            row.beat = (r % perBar) / config.rowsPerBeat;
            row.rowInBeat = r % config.rowsPerBeat;
            g.rows.push(row);
        }
        return g;
    }

    // Adds a pattern or an instrument file (from the add column).
    newFile(): void {
        let pattern = this.tab == 1;
        let dir = pattern ? PATTERNS_DIR : INSTRUMENTS_DIR;
        let ext = pattern ? ".pat" : ".inst";
        let stem = pattern ? "pattern" : "instrument";
        let n = 1;
        while (this.song.files.has(`${dir}${stem}_${n}${ext}`)) n++;
        let path = `${dir}${stem}_${n}${ext}`;
        let text = "";
        if (pattern) {
            // One bar: a note on each beat, then rests to the bar's end.
            let rpb = this.song.config.rowsPerBeat;
            let rows = rpb * this.song.config.sigNum;
            for (let r = 0; r < rows; r++) text += (r % rpb == 0 ? "note(p: C4)" : "") + "\n";
        } else {
            text = "base(preset: saw)\nfilter(type: lowpass, cutoff: 2k, res: 0.2)\nenv(a: 5ms, d: 300ms, s: 0.6, r: 200ms)\n";
        }
        this.song.setFile(path, text);
        let list = this.listFor(this.tab);
        list.selected = `${stem}_${n}`;
        this.refreshFileTabs();
        this.selectFile(this.tab, list.selected);
        this.fileEdited(path, text);
        // Name it right away: the new row opens for renaming.
        list.startRename(list.names.indexOf(`${stem}_${n}`));
        this.say(`added ${path}; type its name, then call it with ${pattern ? "pattern(name: …)" : "inst(name: …)"}`);
    }

    handleListActions(): void {
        if (!this.fileTab) return;
        let list = this.listFor(this.tab);
        let actions = list.takeActions();
        for (let i = 0; i < actions.length; i++) {
            let a = actions[i];
            if (a == "add") this.newFile();
            else if (a.startsWith("select:")) this.selectFile(this.tab, a.substring(7)); else if (a.startsWith("delete:")) this.deleteFile(this.tab, a.substring(7));
            else if (a.startsWith("rename:")) {
                let parts = a.split(":");
                if (parts.length == 3) this.renameFile(this.tab, parts[1], parts[2]);
            }
        }
    }

    // Opens another file of a tab. While playing, the new file plays from its start.
    selectFile(tab: i32, name: string): void {
        let playing = this.transport.state == TransportState.Playing;
        this.endAudition();
        this.showFile(tab, name);
        if (playing && tab == this.tab) this.auditionFile(false);
    }

    filePath(tab: i32, name: string): string {
        return tab == 1 ? `${PATTERNS_DIR}${name}.pat` : `${INSTRUMENTS_DIR}${name}.inst`;
    }

    deleteFile(tab: i32, name: string): void {
        let path = this.filePath(tab, name);
        if (!this.song.files.has(path)) return;
        if (this.auditionPath == path) this.stop();
        this.song.removeFile(path);
        this.fileColumnCache.delete(path);
        this.removeFileFromVm(path);
        this.refreshFileTabs();
        this.editedSinceLoad = true;
        this.compileAt = this.clock + COMPILE_DELAY;
        this.say(`deleted ${path}`);
    }

    // Renames a pattern or instrument and the references to it in every file.
    renameFile(tab: i32, from: string, to: string): void {
        let pattern = tab == 1;
        let list = this.listFor(tab);
        if (!isName(to)) {
            this.say(`'${to}' is not a valid name: use lowercase letters, digits and '_'`);
            return;
        }
        let oldPath = this.filePath(tab, from);
        let newPath = this.filePath(tab, to);
        if (this.song.files.has(newPath)) {
            this.say(`there is already a ${pattern ? "pattern" : "instrument"} named '${to}'`);
            return;
        }
        let text = this.song.text(oldPath);
        let cached = this.fileColumnCache.has(oldPath) ? this.fileColumnCache.get(oldPath) : null;
        if (cached != null) {
            text = cached.doc.text();
            cached.doc.path = newPath;
            this.fileColumnCache.delete(oldPath);
            this.fileColumnCache.set(newPath, cached);
        }
        this.song.setFile(newPath, text);
        this.song.removeFile(oldPath);
        this.removeFileFromVm(oldPath);
        this.writeFileToVm(newPath, text, true);
        // References: pattern(name: old) for patterns; inst(name: old) and inst: old for instruments.
        let changed = 0;
        let paths = this.song.paths.slice(0);
        for (let i = 0; i < paths.length; i++) {
            let p = paths[i];
            if (!p.endsWith(".ch") && !p.endsWith(".pat")) continue;
            let before = this.song.text(p);
            let after = renameReferences(before, from, to, pattern);
            if (after == before) continue;
            changed++;
            this.song.setFile(p, after);
            this.writeFileToVm(p, after, true);
            this.updateOpenDoc(p, after);
        }
        if (this.auditionPath == oldPath) this.auditionPath = newPath;
        list.selected = to;
        this.refreshFileTabs();
        this.editedSinceLoad = true;
        this.compileAt = this.clock + COMPILE_DELAY;
        this.say(`renamed ${from} to ${to}${changed > 0 ? `, updated ${changed} file${changed == 1 ? "" : "s"}` : ""}`);
    }

    // A file changed outside its editor: show the new text where it is open.
    updateOpenDoc(path: string, text: string): void {
        let views = this.views();
        for (let v = 0; v < views.length; v++) {
            let columns = views[v].columns;
            for (let i = 0; i < columns.length; i++) {
                if (columns[i].doc.path == path) {
                    columns[i].doc.replaceAll(text);
                    views[v].relayout();
                }
            }
        }
        if (this.fileColumnCache.has(path)) this.fileColumnCache.get(path).doc.replaceAll(text);
    }

    removeFileFromVm(path: string): void {
        this.hostChanged(path);
        let vm = this.vm;
        if (vm == null) return;
        let list = vm.list(vm.song, "files");
        if (list == null) return;
        for (let i = 0; i < list.length; i++) {
            if (itemStr(list.get(i), "path") == path) {
                list.removeAt(i);
                break;
            }
        }
        this.seenRevision.delete(path);
    }

    // --- Auditions (§10.9) ---------------------------------------------------------

    // Plays the focused pattern on a loop, or a phrase on the focused
    // instrument, without the rest of the song.
    auditionFile(keep: bool): void {
        let c = this.view.focused;
        if (c == null || !this.fileTab) return;
        let path = c.doc.path;
        let name = c.name;
        let config = this.song.config;
        let rpb = config.rowsPerBeat;
        let line = "";
        let loopRows = 0;
        if (this.tab == 1) {
            // The pattern alone, called again on every pass of the loop.
            line = `${this.callerInstrument(name)}pattern(name: ${name})\n`;
            loopRows = max<i32>(c.map.bands, 1);
        } else {
            // An example track: an arpeggio, a held chord, a low line (two bars).
            let rows = new Array<string>(rpb * 8);
            for (let r = 0; r < rows.length; r++) rows[r] = "";
            rows[0] = `inst(name: ${name}); note(p: C3, len: 1b)`;
            rows[rpb] = "note(p: E3, len: 1b)";
            rows[rpb * 2] = "note(p: G3, len: 1b)";
            rows[rpb * 3] = "note(p: C4, len: 1b)";
            rows[rpb * 4] = "chord(root: C3, type: maj7, len: 2b, strum: 30ms)";
            rows[rpb * 6] = "note(p: G2, len: 1/8); note(p: G3, len: 1/8, at: 0.5)";
            rows[rpb * 7] = "note(p: C2, len: 1b)";
            line = rows.join("\n") + "\n";
            loopRows = rpb * 8;
        }
        let conductor = "mark(name: audition)\n";
        for (let r = 1; r < loopRows - 1; r++) conductor += "\n";
        conductor += loopRows > 1 ? "jump(to: audition)\n" : "";
        let yaml = `bpm: ${config.bpm}\nsignature: ${config.sigNum}/${config.sigDen}\nrows_per_beat: ${rpb}\nswing: ${config.swing}\nchannels:\n  - file: audition.ch\n`;
        let files = new Array<SongFile>();
        let all = this.song.toFiles();
        for (let i = 0; i < all.length; i++) {
            let p = all[i].path;
            if (p.startsWith(PATTERNS_DIR) || p.startsWith(INSTRUMENTS_DIR)) files.push(all[i]);
        }
        files.push(new SongFile("song.yaml", yaml));
        files.push(new SongFile("conductor.ch", conductor));
        files.push(new SongFile("audition.ch", line));
        let options = new CompileOptions();
        options.loops = 0;
        let score = compileSong(Song.fromFiles(files), options);
        this.auditioning = true;
        this.auditionPath = path;
        this.transport.setLoop(score.loopStart, score.loopEnd);
        if (keep && this.transport.state == TransportState.Playing) {
            this.transport.setScore(score, true);
        } else {
            this.transport.state = TransportState.Stopped;
            this.transport.setScore(score, false);
            this.transport.play(0);
        }
        this.say(this.tab == 1 ? `playing pattern ${name} (Cmd+. stops)` : `playing ${name} (Cmd+. stops)`);
    }

    // `inst(name: …); ` for the instrument pattern `name` plays with: the one
    // selected before the first call to it in a track, or, through patterns
    // that call it, the one they play with. "" when none is found.
    callerInstrument(name: string): string {
        let inst = this.instrumentCalling(name, 0);
        return inst.length > 0 ? `inst(name: ${inst}); ` : "";
    }

    instrumentCalling(name: string, depth: i32): string {
        if (depth > 8) return "";
        let channels = this.song.channels;
        for (let i = 0; i < channels.length; i++) {
            let inst = instrumentBefore(channels[i].file, name);
            if (inst != null && inst.length > 0) return inst;
        }
        // Patterns that call it, and in turn whatever plays them.
        let names = this.song.patternNames;
        for (let i = 0; i < names.length; i++) {
            if (names[i] == name) continue;
            let inst = instrumentBefore(this.song.patterns.get(names[i]), name);
            if (inst == null) continue;
            if (inst.length > 0) return inst;
            let outer = this.instrumentCalling(names[i], depth + 1);
            if (outer.length > 0) return outer;
        }
        return "";
    }

    endAudition(): void {
        if (!this.auditioning) return;
        this.auditioning = false;
        this.patternsView.playRow = -1;
        this.instrumentsView.playRow = -1;
    }

    log(message: string): void {
        let c = this.context;
        if (c != null) c.log(`partition: ${message}`);
    }

    say(message: string): void {
        this.message = message;
        this.messageUntil = this.clock + 4;
        this.log(message);
    }

    // --- Songs -------------------------------------------------------------------

    loadExample(id: string): void {
        let info = exampleInfo(id);
        let context = this.context!;
        let bytes = info != null ? context.blob(info.blobName) : null;
        if (info == null || bytes == null) {
            this.say(`there is no example named '${id}'`);
            return;
        }
        let bundle = exampleBundle(id, bytes);
        this.setSong(Song.fromFiles(bundle.files));
        this.publishFiles();
        this.currentExample = id;
        this.markCurrentExample();
        this.say(`loaded ${info.title}`);
    }

    markCurrentExample(): void {
        let all = examples();
        for (let i = 0; i < this.exampleItems.length && i < all.length; i++) {
            setItemNum(this.exampleItems[i], "current", all[i].id == this.currentExample ? 1 : 0);
        }
    }

    setMenu(open: bool): void {
        this.menuOpen = open;
        let vm = this.vm;
        if (vm == null) return;
        if (open) {
            this.moreOpen = false;
            this.diagnosticsOpen = false;
        }
        vm.setNum(vm.song, "song", "examplesDisplay", open ? 0 : 1);
        if (!open) {
            for (let i = 0; i < this.exampleItems.length; i++) setItemNum(this.exampleItems[i], "hover", 0);
        }
    }

    // Closes every popover; true if one was open.
    closePopovers(): bool {
        let any = this.menuOpen || this.moreOpen || this.diagnosticsOpen;
        this.setMenu(false);
        this.moreOpen = false;
        this.diagnosticsOpen = false;
        return any;
    }

    get popoverOpen(): bool {
        return this.menuOpen || this.moreOpen || this.diagnosticsOpen;
    }

    // Whether a point (in this layout's coordinates) is on an open popover.
    onPopover(x: f64, y: f64): bool {
        let w = this.layoutW;
        if (this.onMenu(x, y)) return true;
        if (this.moreOpen && x >= w - 8 - MORE_WIDTH && x <= w - 8 && y >= 0 && y <= MORE_HEIGHT) return true;
        if (this.diagnosticsOpen) {
            let n = <f64>max<i32>(min<i32>(this.diagnosticItems.length, DIAG_LIMIT), 0);
            let h = 8 + n * DIAG_ROW + Math.max(n - 1, 0) * 2;
            let bottom = this.layoutH - 3; // the popover sits 3 px above the footer's rule
            if (x >= w - 8 - DIAG_WIDTH && x <= w - 8 && y >= bottom - h && y <= bottom) return true;
        }
        return false;
    }

    // Moves the cursor to a problem's place and shows it.
    jumpTo(d: Diagnostic): void {
        let tab = this.tabOf(d.path);
        this.setTab(tab);
        if (tab > 0) {
            let slash = d.path.lastIndexOf("/");
            let dot = d.path.lastIndexOf(".");
            this.showFile(tab, d.path.substring(slash + 1, dot));
        }
        let columns = this.view.columns;
        for (let i = 0; i < columns.length; i++) {
            let c = columns[i];
            if (c.doc.path != d.path) continue;
            this.view.focus = i;
            c.collapsed = false;
            c.doc.moveTo(new Pos(max<i32>(d.line - 1, 0), max<i32>(d.col - 1, 0)), false);
            this.view.fit();
            this.view.relayout();
            this.view.follow = false;
            this.view.reveal();
            return;
        }
        this.say(`${d.path}:${d.line}: ${d.message}`);
    }

    // Whether a point (in this layout's coordinates) is on the open dropdown.
    onMenu(x: f64, y: f64): bool {
        if (!this.menuOpen) return false;
        let rows = <f64>((examples().length + 1) / 2);
        let height = MENU_PAD * 2 + rows * MENU_ROW + Math.max(rows - 1, 0) * MENU_GAP;
        let right = this.layoutW - MENU_RIGHT;
        return x >= right - MENU_WIDTH && x <= right && y >= 0 && y <= height;
    }

    // Replaces the whole song: new columns, a fresh score, the transport stopped.
    setSong(song: Song): void {
        this.transport.stop();
        this.editedSinceLoad = false;
        this.song = song;
        this.startRow = 0;
        this.userLoop = false;
        let columns = new Array<Column>();
        let conductor = new Doc(CONDUCTOR_PATH, song.text(CONDUCTOR_PATH));
        columns.push(new Column(conductor, "conductor", autoWidth(conductor, 22), true, false, false));
        for (let i = 0; i < song.channels.length; i++) {
            let ch = song.channels[i];
            let doc = new Doc(ch.config.file, song.text(ch.config.file));
            let width = ch.config.widthSet ? ch.config.width : autoWidth(doc, 26);
            columns.push(new Column(doc, ch.name, width, false, ch.config.mute, ch.config.solo));
        }
        this.endAudition();
        let tracks = this.tracksView;
        tracks.setColumns(columns);
        tracks.focus = columns.length > 1 ? 1 : 0;
        tracks.scrollY = 0;
        tracks.scrollX = 0;
        this.patternsView.columns = [];
        this.instrumentsView.columns = [];
        this.refreshFileTabs();
        this.patternsView.focus = 0;
        this.instrumentsView.focus = 0;
        this.applyMix();
        // Compile on the next frame: parsing a large song and compiling it in
        // one call can pass the frame budget on the interpreter.
        this.compileAt = this.clock + 1e-6; // strictly after this frame
    }

    compileNow(): void {
        this.compileAt = -1;
        let options = new CompileOptions();
        options.startRow = this.startRow;
        let realtime = this.realtimeRender;
        let vm = this.vm;
        if (realtime && vm != null) {
            // A headless render through the processor (§12.1 render): the
            // export settings, and no endless loop.
            options.loops = max<i32>(<i32>vm.num(vm.render, "loops", 1), 0);
            options.startRow = max<i32>(<i32>vm.num(vm.render, "fromRow", 0), 0);
            let to = <i32>vm.num(vm.render, "toRow", 0);
            options.endRow = to > 0 ? to : -1;
        }
        let score = compileSong(this.song, options);
        this.score = score;
        this.tracksView.grid = score.grid;
        this.patternsView.grid = this.patternGrid();
        this.assignDiagnostics(score.diagnostics);
        this.buildOverviews(score);
        if (this.auditioning) {
            // An edit during an audition is heard in the audition.
            this.auditionFile(true);
        } else {
            let state = this.transport.state;
            this.transport.setScore(score, state != TransportState.Stopped);
            if (realtime) this.transport.setLoop(-1, -1);
            else if (!this.userLoop) this.transport.setLoop(score.loopStart, score.loopEnd);
            else this.applyUserLoop();
        }
        this.publishSong();
        if (!this.hostReady && this.hostBridge) {
            this.hostReady = true;
            let errors = 0;
            let items = new Array<string>();
            for (let i = 0; i < score.diagnostics.length; i++) {
                let d = score.diagnostics[i];
                if (d.isError) errors++;
                items.push(`{"path":${jsonString(d.path)},"line":${d.line},"col":${d.col},"severity":"${d.isError ? "error" : "warning"}","code":${jsonString(d.code)},"message":${jsonString(d.message)}}`);
            }
            this.hostSend(`{"op":"ready","title":${jsonString(this.song.config.title)},"duration":${score.duration},"errors":${errors},"diagnostics":[${items.join(",")}]}`);
        }
    }

    // Every column's overview strip (§10.6), from the source as just checked.
    buildOverviews(score: Score): void {
        let pb = score.playback;
        let rows = score.grid.rows.length;
        let bpm = new Array<f64>(rows);
        let fallback = this.song.config.bpm;
        for (let r = 0; r < rows; r++) bpm[r] = -1;
        for (let p = 0; p < pb.count; p++) {
            let r = pb.source[p];
            if (r < rows && bpm[r] < 0) bpm[r] = pb.bpm[p];
        }
        for (let r = 0; r < rows; r++) {
            if (bpm[r] < 0) bpm[r] = r > 0 ? bpm[r - 1] : fallback;
        }
        let patternGrid = this.patternsView.grid!;
        let views = [this.tracksView, this.patternsView];
        for (let v = 0; v < views.length; v++) {
            let columns = views[v].columns;
            let grid = v == 0 ? score.grid : patternGrid;
            for (let i = 0; i < columns.length; i++) {
                let file = this.song.checked(columns[i].doc.path);
                if (file == null) continue;
                let ov = buildOverview(file, this.song, grid, bpm);
                ov.revision = this.song.revision;
                columns[i].overview = ov;
            }
        }
    }

    assignDiagnostics(all: Array<Diagnostic>): void {
        let views = this.views();
        for (let v = 0; v < views.length; v++) {
            let columns = views[v].columns;
            for (let i = 0; i < columns.length; i++) {
                let c = columns[i];
                let mine = new Array<Diagnostic>();
                for (let k = 0; k < all.length; k++) if (all[k].path == c.doc.path) mine.push(all[k]);
                c.diagnostics = mine;
            }
        }
    }

    // A file changed in the editor: tell the song, then compile shortly.
    fileEdited(path: string, text: string): void {
        this.song.setFile(path, text);
        this.editedSinceLoad = true;
        this.compileAt = this.clock + COMPILE_DELAY;
        this.changedAt = this.clock + CHANGED_DELAY;
        if (!this.changedPaths.includes(path)) this.changedPaths.push(path);
        this.writeFileToVm(path, text, true);
    }

    // --- Transport ---------------------------------------------------------------

    // Render settings drive playback (set by the shell for `partition render`).
    get realtimeRender(): bool {
        let vm = this.vm;
        return vm != null && vm.bool(vm.render, "realtime");
    }

    playFrom(row: i32): void {
        this.endAudition();
        this.startRow = row;
        this.transport.state = TransportState.Stopped;
        this.compileNow();
        this.transport.play(0);
        let played = this.score;
        if (this.realtimeRender && played != null) this.hostSend(`{"op":"playing","clock":${this.clock},"duration":${played.duration}}`);
    }

    togglePlay(): void {
        let t = this.transport;
        // After an audition, play starts the song again.
        if (this.auditioning) {
            this.playFrom(0);
            return;
        }
        if (t.state == TransportState.Playing) t.pause();
        else if (t.state == TransportState.Paused) t.play(-1);
        else this.playFrom(this.userLoop ? this.loopStartRow : 0);
    }

    stop(): void {
        this.transport.stop();
        this.startRow = 0;
        if (this.auditioning) {
            this.endAudition();
            // Hand the processor the song again, stopped.
            let score = this.score;
            if (score != null) this.transport.setScore(score, false);
        }
    }

    audition(): void {
        if (this.fileTab) {
            this.auditionFile(false);
            return;
        }
        this.endAudition();
        let row = this.tracksView.cursorRow();
        this.startRow = row;
        this.transport.state = TransportState.Stopped;
        this.compileNow();
        let score = this.score!;
        let pb = score.playback;
        let dur = pb.firstAudible < pb.count ? pb.rowDur(pb.firstAudible) : 0.125;
        this.transport.audition(0, dur);
        this.transport.state = TransportState.Stopped;
    }

    toggleLoop(): void {
        let c = this.tracksView.focused;
        if (this.userLoop && (c == null || !c.doc.hasSelection)) {
            this.userLoop = false;
            let score = this.score;
            if (score != null) this.transport.setLoop(score.loopStart, score.loopEnd);
            else this.transport.setLoop(-1, -1);
            this.say("loop off");
            return;
        }
        if (c == null) return;
        let a = c.doc.selStart().line;
        let b = c.doc.selEnd().line;
        let first = a < c.map.band.length ? c.map.band[a] : 0;
        let last = b < c.map.band.length ? c.map.band[b] : first;
        if (!c.doc.hasSelection) {
            // No selection: loop the bar the cursor is in.
            let grid = this.tracksView.grid;
            let row = this.tracksView.cursorRow();
            if (grid != null && row < grid.rows.length) {
                let bar = grid.rows[row].bar;
                first = row;
                while (first > 0 && grid.rows[first - 1].bar == bar) first--;
                last = row;
                while (last + 1 < grid.rows.length && grid.rows[last + 1].bar == bar) last++;
            } else {
                first = row;
                last = row;
            }
        }
        this.userLoop = true;
        this.loopStartRow = first;
        this.loopEndRow = last;
        this.applyUserLoop();
        this.say(`loop rows ${first + 1}–${last + 1}`);
    }

    applyUserLoop(): void {
        let score = this.score;
        if (score == null) return;
        let pb = score.playback;
        let start = -1.0;
        let end = -1.0;
        for (let p = pb.firstAudible; p < pb.count; p++) {
            if (start < 0 && pb.source[p] == this.loopStartRow) start = pb.rowTime(p);
            if (start >= 0 && pb.source[p] == this.loopEndRow) {
                end = pb.timeAt(<f64>(p + 1));
                break;
            }
        }
        if (start >= 0 && end > start) this.transport.setLoop(start, end);
    }

    applyMix(): void {
        let mute = 0;
        let solo = 0;
        let columns = this.tracksView.columns;
        for (let i = 1; i < columns.length && i - 1 < MAX_CHANNELS; i++) {
            if (columns[i].mute) mute |= 1 << (i - 1);
            if (columns[i].solo) solo |= 1 << (i - 1);
        }
        this.transport.setMix(mute, solo);
    }

    // --- Per frame -----------------------------------------------------------------

    override advance(seconds: f64): bool {
        this.clock += seconds;
        if (!this.ready) {
            this.framesWithoutVm++;
            this.tryStart();
            if (!this.ready) return true;
        }
        this.handleActions();
        this.handleListActions();
        this.rail.advance(seconds);
        this.patternList.advance(seconds);
        this.instrumentList.advance(seconds);
        this.settings.advance(seconds);
        this.applySettings();
        if (this.tab == 3) this.settings.load(this.song.text(SONG_YAML));
        let views = this.views();
        for (let v = 0; v < views.length; v++) {
            let changed = views[v].takeChanged();
            for (let i = 0; i < changed.length; i++) {
                let c = views[v].columns[changed[i]];
                this.fileEdited(c.doc.path, c.doc.text());
            }
        }
        if (this.compileAt >= 0 && this.clock >= this.compileAt) this.compileNow();
        this.transport.poll(seconds);
        if (this.transport.failureCount > this.reportedFailures) {
            this.reportedFailures = this.transport.failureCount;
            this.say(`audio stopped: ${this.transport.lastError}${this.transport.failures <= 3 ? " (restarting)" : ""}`);
        }
        this.exporter.advance(seconds);
        this.syncView();
        for (let v = 0; v < views.length; v++) views[v].advance(seconds);
        this.syncVm(seconds);
        return true;
    }

    handleActions(): void {
        let actions = this.view.takeActions();
        let vm = this.vm;
        if (vm != null) {
            let more = vm.takeActions();
            for (let i = 0; i < more.length; i++) actions.push(more[i]);
        }
        for (let i = 0; i < actions.length; i++) this.handle(actions[i]);
    }

    handle(action: string): void {
        let vm = this.vm;
        if (action.startsWith("tab:")) this.setTab(<i32>parseInt(action.substring(4)));
        else if (action == "newFile") this.newFile();
        // In the pattern and instrument tabs, the play keys audition the file.
        else if ((action == "play" || action == "playFromCursor" || action == "transport.toggle" || action == "transport.play") && this.fileTab) {
            if (this.auditioning && this.transport.state == TransportState.Playing) this.stop();
            else this.auditionFile(false);
        } else if (action == "play" || action == "transport.toggle") this.togglePlay();
        else if (action == "transport.play") {
            if (this.transport.state == TransportState.Paused) this.transport.play(-1);
            else if (this.transport.state == TransportState.Stopped) this.playFrom(0);
        } else if (action == "transport.pause") {
            if (this.transport.state == TransportState.Playing) this.transport.pause();
        } else if (action == "stop" || action == "transport.stop") this.stop();
        else if (action == "playFromCursor" || action == "transport.playFromCursor") this.playFrom(this.tracksView.cursorRow());
        else if (action == "audition") this.audition();
        else if (action == "loop" || action == "transport.loopToggle") this.toggleLoop();
        else if (action == "editor.followToggle") this.view.follow = !this.view.follow;
        else if (action == "editor.collapseAll") this.view.toggleAll();
        else if (action == "menu.toggle") this.setMenu(!this.menuOpen);
        else if (action == "app.moreToggle") {
            let open = !this.moreOpen;
            this.closePopovers();
            this.moreOpen = open;
        } else if (action == "app.diagnosticsToggle") {
            let open = !this.diagnosticsOpen;
            this.closePopovers();
            this.diagnosticsOpen = open;
        } else if (action == "app.docsToggle") {
            this.closePopovers();
            this.view.toggleDocs();
        } else if (action.startsWith("diag:")) {
            let index = <i32>parseInt(action.substring(5));
            this.diagnosticsOpen = false;
            if (index >= 0 && index < this.diagnosticItems.length) this.jumpTo(this.diagnosticItems[index]);
        }
        else if (action == "menu.close") this.setMenu(false);
        else if (action.startsWith("example:")) {
            this.setMenu(false);
            this.loadExample(action.substring(8));
        }
        else if (action.startsWith("mute:") || action.startsWith("solo:")) {
            let index = <i32>parseInt(action.substring(5));
            if (this.tab == 0 && index > 0 && index < this.tracksView.columns.length) {
                let c = this.tracksView.columns[index];
                if (action.startsWith("mute:")) c.mute = !c.mute;
                else c.solo = !c.solo;
                this.applyMix();
            }
        } else if (action == "save") {
            if (this.hostBridge) {
                this.hostAt = this.clock; // anything pending goes first
                this.flushHost();
                this.hostSend(`{"op":"save"}`);
                this.editedSinceLoad = false;
                this.say("saved");
                return;
            }
            let hosted = vm != null && vm.bool(vm.app, "hosted");
            if (vm != null) vm.fire(vm.editor, "saveRequested");
            if (!hosted) this.say("not saved: in the previewer, edits live in memory only (spec §13.1)");
        } else if (action == "copied") {
            if (vm != null) {
                vm.setStr(vm.editor, "editor", "clipboard", this.view.clipboard);
                vm.fire(vm.editor, "copied");
            }
        } else if (action == "editor.paste") {
            if (vm != null) this.view.clipboard = vm.str(vm.editor, "clipboard");
        } else if (action == "song.loadExample") {
            if (vm != null) this.loadExample(vm.str(vm.song, "exampleId", DEFAULT_EXAMPLE));
        } else if (action == "song.autoplay") {
            if (vm != null && vm.bool(vm.song, "autoplay") && this.transport.state == TransportState.Stopped) this.playFrom(0);
        } else if (action == "song.new") {
            this.setMenu(false);
            this.loadExample("empty");
        } else if (action == "song.load") {
            this.loadFromVm();
        } else if (action == "render.start") {
            if (this.hostBridge) {
                // The shell renders the files it has saved (§12.2).
                this.hostAt = this.clock;
                this.flushHost();
                this.hostSend(`{"op":"export","title":${jsonString(this.song.config.title)}}`);
                this.say("exporting a WAV next to the song (see the terminal)");
                return;
            }
            this.startExport();
        } else if (action == "render.cancel") {
            this.exporter.cancel();
        } else if (action == "render.ack") {
            this.exporter.ack();
        }
    }

    // Playhead, meters and follow from the transport's status.
    syncView(): void {
        let st = this.transport.status;
        let playing = this.transport.state == TransportState.Playing && st.playing > 0;
        let idle = this.transport.state == TransportState.Stopped && st.playing == 0;
        let tracks = this.tracksView;
        if (this.auditioning) {
            // The audition's playhead runs through the pattern being heard.
            tracks.playing = false;
            tracks.playRow = -1;
            let config = this.song.config;
            let rowDur = 60 / (config.bpm * <f64>config.rowsPerBeat);
            let view = this.patternsView;
            let length = 0;
            for (let i = 0; i < view.columns.length; i++) if (view.columns[i].doc.path == this.auditionPath) length = view.columns[i].map.bands;
            view.playing = playing && length > 0;
            view.playRow = idle || length == 0 ? -1 : <i32>Math.floor(st.time / rowDur) % length;
            return;
        }
        tracks.playing = playing;
        tracks.playRow = idle ? -1 : <i32>st.row;
        let columns = tracks.columns;
        for (let i = 1; i < columns.length && i - 1 < MAX_CHANNELS; i++) columns[i].meter = st.channelPeaks[i - 1];
    }

    // --- Export ---------------------------------------------------------------------

    startExport(): void {
        let vm = this.vm;
        let options = new CompileOptions();
        let rate = 48000.0;
        let format = "pcm16";
        let tail = 8.0;
        if (vm != null) {
            options.loops = max<i32>(<i32>vm.num(vm.render, "loops", 1), 0);
            options.startRow = max<i32>(<i32>vm.num(vm.render, "fromRow", 0), 0);
            rate = vm.num(vm.render, "sampleRate", 48000);
            format = vm.enumValue(vm.render, "format", "pcm16");
            tail = vm.num(vm.render, "maxTail", 8);
        }
        if (rate != 44100 && rate != 48000 && rate != 96000) rate = 48000;
        let score = compileSong(this.song, options);
        this.exporter.start(score, rate, formatId(format), tail, this.song.config.title, this.song.config.author);
        this.say(`rendering ${this.song.config.title} at ${<i32>rate} Hz`);
    }

    // --- View model ------------------------------------------------------------------

    publishExamples(): void {
        let vm = this.vm;
        if (vm == null) return;
        let list = vm.list(vm.song, "examples");
        if (list == null) return;
        list.clear();
        this.exampleItems = [];
        let all = examples();
        for (let i = 0; i < all.length; i++) {
            let item = newItem("ExampleInfo");
            setItemStr(item, "id", all[i].id);
            setItemStr(item, "title", all[i].title);
            setItemStr(item, "description", all[i].description);
            setItemNum(item, "bpm", all[i].bpm);
            setItemStr(item, "genre", all[i].genre);
            setItemStr(item, "subtitle", `${all[i].genre} · ${<i32>all[i].bpm}`);
            vm.listen(item, "select", "example:" + all[i].id);
            list.push(item);
            this.exampleItems.push(item);
        }
    }

    // Mirrors the song's files into song/files.
    publishFiles(): void {
        let vm = this.vm;
        if (vm == null) return;
        let list = vm.list(vm.song, "files");
        if (list == null) return;
        list.clear();
        this.seenRevision.clear();
        let files = this.song.toFiles();
        for (let i = 0; i < files.length; i++) {
            let item = newItem("SongFile");
            setItemStr(item, "path", files[i].path);
            setItemStr(item, "text", files[i].text);
            setItemNum(item, "revision", 1);
            setItemBool(item, "dirty", false);
            list.push(item);
            this.seenRevision.set(files[i].path, 1);
        }
    }

    fileItem(path: string): ViewModel? {
        let vm = this.vm;
        if (vm == null) return null;
        let list = vm.list(vm.song, "files");
        if (list == null) return null;
        for (let i = 0; i < list.length; i++) {
            let item = list.get(i);
            if (itemStr(item, "path") == path) return item;
        }
        return null;
    }

    writeFileToVm(path: string, text: string, dirty: bool): void {
        if (dirty) this.hostChanged(path);
        let vm = this.vm;
        if (vm == null) return;
        let item = this.fileItem(path);
        if (item == null) {
            let list = vm.list(vm.song, "files");
            if (list == null) return;
            item = newItem("SongFile");
            setItemStr(item, "path", path);
            list.push(item);
        }
        let revision = itemNum(item, "revision") + 1;
        setItemStr(item, "text", text);
        setItemNum(item, "revision", revision);
        setItemBool(item, "dirty", dirty);
        this.seenRevision.set(path, revision);
    }

    // The host replaced song/files and fired song/load.
    loadFromVm(): void {
        let vm = this.vm;
        if (vm == null) return;
        let list = vm.list(vm.song, "files");
        if (list == null) return;
        let files = new Array<SongFile>();
        this.seenRevision.clear();
        for (let i = 0; i < list.length; i++) {
            let item = list.get(i);
            let path = itemStr(item, "path");
            files.push(new SongFile(path, itemStr(item, "text")));
            this.seenRevision.set(path, itemNum(item, "revision"));
        }
        this.setSong(Song.fromFiles(files));
        this.say(`loaded ${this.song.config.title} (${files.length} files)`);
    }

    // A host bumps a file's revision after changing its text outside (§11.6).
    pollHostFiles(): void {
        let vm = this.vm;
        if (vm == null) return;
        let list = vm.list(vm.song, "files");
        if (list == null) return;
        for (let i = 0; i < list.length; i++) {
            let item = list.get(i);
            let path = itemStr(item, "path");
            let revision = itemNum(item, "revision");
            let seen = this.seenRevision.has(path) ? this.seenRevision.get(path) : -1;
            if (revision <= seen) continue;
            this.seenRevision.set(path, revision);
            let text = itemStr(item, "text");
            this.song.setFile(path, text);
            let columns = this.view.columns;
            for (let c = 0; c < columns.length; c++) {
                if (columns[c].doc.path == path) columns[c].doc.replaceAll(text);
            }
            this.view.relayout();
            if (path == "song.yaml") this.setSong(this.song);
            this.compileAt = this.clock + COMPILE_DELAY;
        }
    }

    publishSong(): void {
        let vm = this.vm;
        let score = this.score;
        if (vm == null || score == null) return;
        let s = vm.song;
        vm.setStr(s, "song", "title", this.song.config.title);
        vm.setNum(s, "song", "durationSeconds", Math.round(score.duration * 1000) / 1000);
        vm.setNum(s, "song", "rows", <f64>this.song.rowCount);
        let errors = 0;
        for (let i = 0; i < score.diagnostics.length; i++) if (score.diagnostics[i].isError) errors++;
        vm.setNum(s, "song", "errorCount", <f64>errors);
        let list = vm.list(s, "diagnostics");
        if (list != null) {
            list.clear();
            let n = min<i32>(score.diagnostics.length, DIAG_LIMIT);
            this.diagnosticItems = [];
            for (let i = 0; i < n; i++) this.diagnosticItems.push(score.diagnostics[i]);
            for (let i = 0; i < n; i++) {
                let d = score.diagnostics[i];
                let item = newItem("Diagnostic");
                setItemStr(item, "where", `${d.path}:${d.line}:${d.col}`);
                setItemColor(item, "dot", d.isError ? 0xFFF05A6E : 0xFFE8A35C);
                vm.listen(item, "select", `diag:${i}`);
                setItemStr(item, "path", d.path);
                setItemNum(item, "line", <f64>d.line);
                setItemNum(item, "col", <f64>d.col);
                setItemNum(item, "endCol", <f64>d.endCol);
                setItemStr(item, "severity", d.isError ? "error" : "warning");
                setItemStr(item, "code", d.code);
                setItemStr(item, "message", d.message);
                list.push(item);
            }
        }
    }

    syncVm(seconds: f64): void {
        let vm = this.vm;
        if (vm == null) return;
        // Edits reach the host a moment after typing stops.
        if (this.changedAt >= 0 && this.clock >= this.changedAt) {
            this.changedAt = -1;
            for (let i = 0; i < this.changedPaths.length; i++) {
                vm.setStr(vm.editor, "editor", "lastChangedPath", this.changedPaths[i]);
                vm.fire(vm.editor, "changed");
            }
            this.changedPaths = [];
        }
        this.flushHost();
        this.pollFilesIn -= seconds;
        if (this.pollFilesIn <= 0) {
            this.pollFilesIn = 0.25;
            this.pollHostFiles();
        }

        // Transport
        let t = vm.transport;
        let st = this.transport.status;
        let state = this.transport.state;
        vm.setEnum(t, "transport", "state", state == TransportState.Playing ? "playing" : state == TransportState.Paused ? "paused" : "stopped");
        vm.setStr(t, "transport", "playLabel", state == TransportState.Playing ? "Pause" : "Play");
        // The play button turns into pause while playing (displayValue: 0 shown, 1 hidden).
        vm.setNum(t, "transport", "playDisplay", state == TransportState.Playing ? 1 : 0);
        vm.setNum(t, "transport", "pauseDisplay", state == TransportState.Playing ? 0 : 1);
        vm.setColor(t, "transport", "loopColor", this.userLoop ? TOGGLE_ON : TOGGLE_OFF);
        this.look(vm, "loop", this.userLoop);
        this.look(vm, "follow", this.view.follow);
        this.look(vm, "collapse", this.view.allCollapsed);
        this.look(vm, "docs", this.view.docsOpen);
        this.look(vm, "more", this.moreOpen);
        this.look(vm, "examples", this.menuOpen);
        this.look(vm, "diagnostics", this.diagnosticsOpen);

        let a = vm.app;
        vm.setNum(a, "app", "wideDisplay", this.narrow ? 1 : 0);
        vm.setNum(a, "app", "narrowDisplay", this.narrow ? 0 : 1);
        vm.setNum(a, "app", "moreDisplay", this.moreOpen ? 0 : 1);
        vm.setNum(a, "app", "diagnosticsDisplay", this.diagnosticsOpen && this.diagnosticItems.length > 0 ? 0 : 1);
        vm.setStr(a, "app", "menuLoop", this.userLoop ? "Loop  ·  on" : "Loop");
        vm.setStr(a, "app", "menuFollow", this.view.follow ? "Follow  ·  on" : "Follow");
        vm.setStr(a, "app", "menuCollapse", this.view.allCollapsed ? "Expand all" : "Collapse all");
        let problems = this.diagnosticItems.length;
        vm.setStr(a, "app", "diagnosticsLabel", problems == 0 ? "No problems" : `${problems}${problems >= DIAG_LIMIT ? "+" : ""} problem${problems == 1 ? "" : "s"}`);
        let hosted = vm.bool(a, "hosted");
        vm.setStr(a, "app", "status", hosted ? (this.editedSinceLoad ? "Edited" : "Saved") : (this.editedSinceLoad ? "Edited, in memory" : "In memory"));
        vm.setStr(a, "app", "sampleRate", `${<i32>Math.round(Audio.sampleRate() / 1000)} kHz`);
        let row = <i32>st.row;
        let score = this.score;
        let bar = 1;
        let beat = 1;
        if (score != null && row < score.grid.rows.length) {
            bar = score.grid.rows[row].bar + 1;
            beat = score.grid.rows[row].beat + 1;
        }
        vm.setNum(t, "transport", "row", <f64>row);
        vm.setNum(t, "transport", "bar", <f64>bar);
        vm.setNum(t, "transport", "beat", <f64>beat);
        vm.setNum(t, "transport", "seconds", Math.round(st.time * 10) / 10);
        // Stopped, the engine's tempo is stale: show where the song starts.
        let bpm = st.playing > 0 || score == null || score.playback.count == 0 ? st.bpm : score.playback.bpm[0];
        vm.setNum(t, "transport", "bpm", Math.round(bpm * 10) / 10);
        vm.setNum(t, "transport", "voices", st.voices);
        vm.setBool(t, "transport", "loopEnabled", this.userLoop);
        vm.setNum(t, "transport", "loopStartRow", <f64>this.loopStartRow);
        vm.setNum(t, "transport", "loopEndRow", <f64>this.loopEndRow);
        let secs = Math.max(st.time, 0);
        let minutes = <i32>Math.floor(secs / 60);
        let rest = secs - <f64>minutes * 60;
        let tenths = <i32>Math.floor(rest * 10) % 10;
        let whole = <i32>Math.floor(rest);
        let barText = bar < 10 ? `00${bar}` : bar < 100 ? `0${bar}` : `${bar}`;
        vm.setStr(t, "transport", "position", `${barText}.${beat}`);
        vm.setStr(t, "transport", "time", `${minutes < 10 ? "0" : ""}${minutes}:${whole < 10 ? "0" : ""}${whole}.${tenths}`);
        vm.setStr(t, "transport", "tempo", `${<i32>Math.round(bpm)}`);
        let meter = "4/4";
        if (score != null && row < score.grid.rows.length) meter = `${score.grid.rows[row].sigNum}/${score.grid.rows[row].sigDen}`;
        vm.setStr(t, "transport", "meter", meter);
        vm.setStr(t, "transport", "info", `${<i32>st.voices} voices`);

        // Editor
        let e = vm.editor;
        let focused = this.view.focused;
        if (focused != null) {
            vm.setStr(e, "editor", "cursorPath", focused.doc.path);
            vm.setNum(e, "editor", "cursorRow", <f64>this.view.cursorRow());
            vm.setNum(e, "editor", "cursorCol", <f64>focused.doc.cursor.ch);
        }
        vm.setBool(e, "editor", "follow", this.view.follow);
        vm.setColor(e, "editor", "followColor", this.view.follow ? TOGGLE_ON : TOGGLE_OFF);
        vm.setStr(e, "editor", "collapseLabel", this.view.allCollapsed ? "Expand all" : "Collapse all");
        // The breadcrumb: the track, then the command under the cursor.
        let hint = "";
        if (this.clock < this.messageUntil) {
            hint = this.message;
        } else if (focused != null) {
            let line = focused.doc.cursor.line < focused.doc.lines.length ? focused.doc.lines[focused.doc.cursor.line] : "";
            let summary = summaryAt(line, focused.doc.cursor.ch);
            hint = summary.length > 0 ? `${focused.name}  /  ${summary}` : focused.name;
        }
        vm.setStr(e, "editor", "hint", hint);

        // Export
        let r = vm.render;
        let ex = this.exporter;
        vm.setEnum(r, "render", "state", exportStateName(ex.state));
        vm.setNum(r, "render", "progress", Math.round(ex.fraction * 1000) / 1000);
        vm.setStr(r, "render", "error", ex.error);
        let label = "Export WAV";
        if (ex.state == ExportState.Rendering) label = `Rendering ${<i32>(ex.fraction * 100)}%`;
        else if (ex.state == ExportState.Streaming) label = `Saving ${ex.chunkIndex + 1}/${ex.chunkCount}`;
        else if (ex.state == ExportState.Done) label = ex.unclaimed ? "Rendered (no host)" : "Exported";
        else if (ex.state == ExportState.Failed) label = "Export failed";
        vm.setStr(r, "render", "label", label);
        let chunk = ex.takeChunk();
        if (chunk != null) {
            let blob = vm.blob(r, "chunk");
            if (blob != null) blob.value = chunk;
            vm.setNum(r, "render", "chunkIndex", <f64>ex.chunkIndex);
            vm.setNum(r, "render", "chunkCount", <f64>ex.chunkCount);
            vm.setNum(r, "render", "totalBytes", <f64>ex.totalBytes);
            vm.fire(r, "chunkReady");
        }
        if (ex.state == ExportState.Done && ex.unclaimed) {
            ex.unclaimed = false;
            this.say("rendered; to save a WAV without a host use: rive rive/ --render-audio --data=song/autoplay=true (spec §13.2)");
        }
    }

    // A toggle's look: lit (white label, pressed fill, visible edge) when on.
    look(vm: Bindings, key: string, on: bool): void {
        let a = vm.app;
        vm.setColor(a, "app", key + "Fill", on ? LOOK_FILL_ON : LOOK_FILL);
        vm.setColor(a, "app", key + "Ink", on ? LOOK_INK_ON : LOOK_INK);
        vm.setColor(a, "app", key + "Edge", on ? LOOK_EDGE_ON : LOOK_EDGE);
    }

    // --- Input and drawing ---------------------------------------------------------------

    // While the dropdown is open the editor under it takes no clicks: a click
    // on a row belongs to the row's listener, and one anywhere else closes it.
    override pointerDown(event: PointerEvent): void {
        let x = <f64>event.position.x;
        let y = <f64>event.position.y;
        if (this.popoverOpen) {
            // On a popover the press belongs to its rows; elsewhere in the
            // editor it closes them (presses on the bars above and below
            // belong to their own buttons).
            if (!this.onPopover(x, y) && y >= 0 && y <= this.layoutH) {
                this.closePopovers();
                event.hit();
            }
            return;
        }
        if (y < 0 || y > this.layoutH) return;
        if (x < RAIL_WIDTH) {
            event.hit();
            let tab = this.rail.hit(x, y);
            if (tab >= 0) this.setTab(tab);
            return;
        }
        if (this.fileTab && x < RAIL_WIDTH + LIST_WIDTH) {
            event.hit();
            this.listFor(this.tab).pointerDown(x - RAIL_WIDTH, y);
            return;
        }
        if (this.tab == 3 && !this.onSettingsDocs(x)) {
            event.hit();
            this.layoutSettings();
            this.settings.pointerDown(x - RAIL_WIDTH, y);
            return;
        }
        this.view.pointerDown(event);
    }

    override pointerMove(event: PointerEvent): void {
        let x = <f64>event.position.x;
        let y = <f64>event.position.y;
        this.rail.pointerMove(x, y >= 0 && y <= this.layoutH ? y : -1000);
        if (this.fileTab) this.listFor(this.tab).pointerMove(x - RAIL_WIDTH, y);
        if (this.popoverOpen) return;
        if (this.tab == 3) {
            this.layoutSettings();
            this.settings.pointerMove(x - RAIL_WIDTH, this.onSettingsDocs(x) && this.settings.dragging.length == 0 ? -1000 : y);
            if (this.settings.dragging.length > 0) event.hit();
            return;
        }
        this.view.pointerMove(event);
    }

    override pointerUp(event: PointerEvent): void {
        this.settings.pointerUp();
        if (this.popoverOpen) return;
        this.view.pointerUp(event);
    }

    layoutSettings(): void {
        this.settings.layout(this.settingsView, this.settingsView.layoutWidth(), this.layoutH);
    }

    // In the settings tab, whether a point is on the documentation panel.
    onSettingsDocs(x: f64): bool {
        let v = this.settingsView;
        return v.docsOpen && x - RAIL_WIDTH >= v.docsLeft();
    }

    override pointerExit(event: PointerEvent): void {
        this.rail.pointerExit();
        this.patternList.hover = -1;
        this.instrumentList.hover = -1;
        this.settings.hover = "";
    }

    override pointerScroll(event: ScrollEvent): void {
        let x = <f64>event.position.x;
        if (this.popoverOpen && this.onPopover(x, <f64>event.position.y)) return;
        if (x < RAIL_WIDTH || (this.fileTab && x < RAIL_WIDTH + LIST_WIDTH)) return;
        if (this.tab == 3 && !this.onSettingsDocs(x)) {
            event.hit();
            this.settings.scroll(-<f64>event.delta.y);
            return;
        }
        this.view.pointerScroll(event);
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        let key = <i32>event.key;
        if (this.popoverOpen && key == 256 && event.phase != "up") {
            this.closePopovers();
            return true;
        }
        // A file being renamed takes the keys; F2 starts renaming.
        if (this.fileTab && event.phase != "up" && !event.meta && !event.control) {
            if (this.listFor(this.tab).key(key)) return true;
        }
        // A settings field being typed in takes the keys.
        if (this.tab == 3 && event.phase != "up" && !event.meta && !event.control) {
            if (this.settings.key(key)) return true;
        }
        return this.view.keyboard(event);
    }

    override textEvent(event: TextInput): bool {
        if (this.fileTab && this.listFor(this.tab).typeText(event.text)) return true;
        if (this.tab == 3) return this.settings.typeText(event.text);
        return this.view.textInput(event);
    }

    override draw(renderer: Renderer): void {
        // The editor, offset to the right of the rail (and the file list).
        renderer.save();
        renderer.transform(Mat2D.withTranslation(<f32>this.view.originX, 0));
        if (this.tab == 3) {
            // The settings form, then the documentation over it when open.
            let v = this.settingsView;
            this.settings.draw(renderer, v, v.layoutWidth(), this.layoutH);
            if (v.docsOpen) v.drawDocs(renderer);
        } else {
            this.view.draw(renderer);
        }
        renderer.restore();
        if (this.fileTab) this.listFor(this.tab).draw(renderer, this.view, RAIL_WIDTH, this.layoutH);
        this.rail.draw(renderer, this.view, this.layoutH);
        this.rail.drawHint(renderer, this.view);
    }
}

// The instrument `file` has selected when it first calls pattern `name`: ""
// when it selects none, null when it never calls it.
function instrumentBefore(file: CheckedFile, name: string): string? {
    let inst = "";
    let rows = file.rows;
    for (let r = 0; r < rows.length; r++) {
        let cmds = rows[r];
        for (let k = 0; k < cmds.length; k++) {
            let c = cmds[k];
            if (c.name == "inst") inst = c.str("name", "");
            if (c.name == "pattern" && c.str("name", "") == name) return inst;
        }
    }
    return null;
}

// `text` as a JSON string literal.
export function jsonString(text: string): string {
    let out = "\"";
    let start = 0;
    for (let i = 0; i < text.length; i++) {
        let c = text.charCodeAt(i);
        if (c >= 32 && c != 34 && c != 92) continue;
        out += text.substring(start, i);
        if (c == 34) out += "\\\"";
        else if (c == 92) out += "\\\\";
        else if (c == 10) out += "\\n";
        else if (c == 13) out += "\\r";
        else if (c == 9) out += "\\t";
        else out += "\\u00" + (c < 16 ? "0" : "") + c.toString(16);
        start = i + 1;
    }
    return out + text.substring(start) + "\"";
}
