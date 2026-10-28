// The Partition app (docs/spec.md §10–§11): the editor grid, the song and its
// compiled score, the transport, WAV export, and the view model that the RML
// chrome and a host drive it through.

import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { KeyboardEvent, PointerEvent, ScrollEvent, TextInput } from "rive/events";
import { ViewModel } from "rive/data";
import { SongFile } from "../lang/bundle";
import { CONDUCTOR_PATH } from "../lang/config";
import { Diagnostic } from "../lang/diagnostics";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { MAX_CHANNELS } from "../synth/engine";
import { Column, EditorView } from "../editor/view";
import { Doc } from "../editor/doc";
import { Bindings, itemNum, itemStr, newItem, setItemBool, setItemNum, setItemStr } from "./bindings";
import { exampleBundle, exampleInfo, examples } from "./examples";
import { ExportState, exportStateName, Exporter, formatId } from "./exporter";
import { Transport, TransportState } from "./transport";

export const COMPILE_DELAY: f64 = 0.15; // seconds after the last edit
export const CHANGED_DELAY: f64 = 0.3; // before telling the host (§11.3)
export const DEFAULT_EXAMPLE: string = "deep-house";

// The examples dropdown as scene.rml lays it out (§10.1): two columns of rows,
// pinned to the right edge just under the toolbar.
export const MENU_WIDTH: f64 = 616;
export const MENU_RIGHT: f64 = 10;
export const MENU_ROW: f64 = 30;
export const MENU_GAP: f64 = 4;
export const MENU_PAD: f64 = 6;

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
    view: EditorView = new EditorView();
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
    currentExample: string = "";
    exampleItems: Array<ViewModel> = [];

    override init(context: Context): bool {
        this.context = context;
        this.view.setFonts(context.font("mono"), context.font("mono-bold"));
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

    override dispose(): void {
        this.transport.dispose();
        this.exporter.cancel();
    }

    override resize(width: f64, height: f64, scale: f64): void {
        this.view.width = width;
        this.view.height = height;
        this.view.clampScroll();
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
        vm.setNum(vm.song, "song", "examplesDisplay", open ? 0 : 1);
        vm.setStr(vm.song, "song", "examplesLabel", open ? "Examples ▴" : "Examples ▾");
        if (!open) {
            for (let i = 0; i < this.exampleItems.length; i++) setItemNum(this.exampleItems[i], "hover", 0);
        }
    }

    // Whether a point (in this layout's coordinates) is on the open dropdown.
    onMenu(x: f64, y: f64): bool {
        if (!this.menuOpen) return false;
        let rows = <f64>((examples().length + 1) / 2);
        let height = MENU_PAD * 2 + rows * MENU_ROW + Math.max(rows - 1, 0) * MENU_GAP;
        let right = this.view.width - MENU_RIGHT;
        return x >= right - MENU_WIDTH && x <= right && y >= 0 && y <= height;
    }

    // Replaces the whole song: new columns, a fresh score, the transport stopped.
    setSong(song: Song): void {
        this.transport.stop();
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
        this.view.setColumns(columns);
        this.view.focus = columns.length > 1 ? 1 : 0;
        this.view.scrollY = 0;
        this.view.scrollX = 0;
        this.applyMix();
        this.compileNow();
    }

    compileNow(): void {
        this.compileAt = -1;
        let options = new CompileOptions();
        options.startRow = this.startRow;
        let score = compileSong(this.song, options);
        this.score = score;
        this.view.grid = score.grid;
        this.assignDiagnostics(score.diagnostics);
        let state = this.transport.state;
        this.transport.setScore(score, state != TransportState.Stopped);
        if (!this.userLoop) this.transport.setLoop(score.loopStart, score.loopEnd);
        else this.applyUserLoop();
        this.publishSong();
    }

    assignDiagnostics(all: Array<Diagnostic>): void {
        let columns = this.view.columns;
        for (let i = 0; i < columns.length; i++) {
            let c = columns[i];
            let mine = new Array<Diagnostic>();
            for (let k = 0; k < all.length; k++) if (all[k].path == c.doc.path) mine.push(all[k]);
            c.diagnostics = mine;
        }
    }

    // A file changed in the editor: tell the song, then compile shortly.
    fileEdited(path: string, text: string): void {
        this.song.setFile(path, text);
        this.compileAt = this.clock + COMPILE_DELAY;
        this.changedAt = this.clock + CHANGED_DELAY;
        if (!this.changedPaths.includes(path)) this.changedPaths.push(path);
        this.writeFileToVm(path, text, true);
    }

    // --- Transport ---------------------------------------------------------------

    playFrom(row: i32): void {
        this.startRow = row;
        this.transport.state = TransportState.Stopped;
        this.compileNow();
        this.transport.play(0);
    }

    togglePlay(): void {
        let t = this.transport;
        if (t.state == TransportState.Playing) t.pause();
        else if (t.state == TransportState.Paused) t.play(-1);
        else this.playFrom(this.userLoop ? this.loopStartRow : 0);
    }

    stop(): void {
        this.transport.stop();
        this.startRow = 0;
    }

    audition(): void {
        let row = this.view.cursorRow();
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
        let c = this.view.focused;
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
            let grid = this.view.grid;
            let row = this.view.cursorRow();
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
        let columns = this.view.columns;
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
        let changed = this.view.takeChanged();
        for (let i = 0; i < changed.length; i++) {
            let c = this.view.columns[changed[i]];
            this.fileEdited(c.doc.path, c.doc.text());
        }
        if (this.compileAt >= 0 && this.clock >= this.compileAt) this.compileNow();
        this.transport.poll(seconds);
        if (this.transport.failureCount > this.reportedFailures) {
            this.reportedFailures = this.transport.failureCount;
            this.say(`audio stopped: ${this.transport.lastError}${this.transport.failures <= 3 ? " (restarting)" : ""}`);
        }
        this.exporter.advance(seconds);
        this.syncView();
        this.view.advance(seconds);
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
        if (action == "play" || action == "transport.toggle") this.togglePlay();
        else if (action == "transport.play") {
            if (this.transport.state == TransportState.Paused) this.transport.play(-1);
            else if (this.transport.state == TransportState.Stopped) this.playFrom(0);
        } else if (action == "transport.pause") {
            if (this.transport.state == TransportState.Playing) this.transport.pause();
        } else if (action == "stop" || action == "transport.stop") this.stop();
        else if (action == "playFromCursor" || action == "transport.playFromCursor") this.playFrom(this.view.cursorRow());
        else if (action == "audition") this.audition();
        else if (action == "loop" || action == "transport.loopToggle") this.toggleLoop();
        else if (action == "editor.followToggle") this.view.follow = !this.view.follow;
        else if (action == "menu.toggle") this.setMenu(!this.menuOpen);
        else if (action == "menu.close") this.setMenu(false);
        else if (action.startsWith("example:")) {
            this.setMenu(false);
            this.loadExample(action.substring(8));
        }
        else if (action.startsWith("mute:") || action.startsWith("solo:")) {
            let index = <i32>parseInt(action.substring(5));
            if (index > 0 && index < this.view.columns.length) {
                let c = this.view.columns[index];
                if (action.startsWith("mute:")) c.mute = !c.mute;
                else c.solo = !c.solo;
                this.applyMix();
            }
        } else if (action == "save") {
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
        this.view.playing = playing;
        this.view.playRow = this.transport.state == TransportState.Stopped && st.playing == 0 ? -1 : <i32>st.row;
        let columns = this.view.columns;
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
            let n = min<i32>(score.diagnostics.length, 200);
            for (let i = 0; i < n; i++) {
                let d = score.diagnostics[i];
                let item = newItem("Diagnostic");
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
        vm.setStr(t, "transport", "position", `${bar}.${beat}  ${minutes}:${whole < 10 ? "0" : ""}${whole}.${tenths}  ${<i32>Math.round(bpm)} bpm`);
        vm.setStr(t, "transport", "info", `${<i32>st.voices} voices${this.userLoop ? " · loop" : ""}${this.view.follow ? " · follow" : ""}`);

        // Editor
        let e = vm.editor;
        let focused = this.view.focused;
        if (focused != null) {
            vm.setStr(e, "editor", "cursorPath", focused.doc.path);
            vm.setNum(e, "editor", "cursorRow", <f64>this.view.cursorRow());
            vm.setNum(e, "editor", "cursorCol", <f64>focused.doc.cursor.ch);
        }
        vm.setBool(e, "editor", "follow", this.view.follow);
        let hint = this.clock < this.messageUntil ? this.message : this.view.hint();
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

    // --- Input and drawing ---------------------------------------------------------------

    // While the dropdown is open the editor under it takes no clicks: a click
    // on a row belongs to the row's listener, and one anywhere else closes it.
    override pointerDown(event: PointerEvent): void {
        if (this.menuOpen) {
            let x = <f64>event.position.x;
            let y = <f64>event.position.y;
            if (!this.onMenu(x, y)) {
                if (y >= 0) {
                    this.setMenu(false);
                    event.hit();
                }
            }
            return;
        }
        this.view.pointerDown(event);
    }

    override pointerMove(event: PointerEvent): void {
        if (this.menuOpen) return;
        this.view.pointerMove(event);
    }

    override pointerUp(event: PointerEvent): void {
        if (this.menuOpen) return;
        this.view.pointerUp(event);
    }

    override pointerScroll(event: ScrollEvent): void {
        if (this.menuOpen && this.onMenu(<f64>event.position.x, <f64>event.position.y)) return;
        this.view.pointerScroll(event);
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        if (this.menuOpen && <i32>event.key == 256 && event.phase != "up") {
            this.setMenu(false);
            return true;
        }
        return this.view.keyboard(event);
    }

    override textEvent(event: TextInput): bool {
        return this.view.textInput(event);
    }

    override draw(renderer: Renderer): void {
        this.view.draw(renderer);
    }
}
