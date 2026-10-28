// The score compiler (docs/spec.md §9.1): simulates every channel in playback
// order and emits the events the engine plays.

import { CheckedCommand, CheckedFile, ParamArg } from "../lang/check";
import { chordIntervals } from "../lang/commands";
import { Diagnostic, Diagnostics } from "../lang/diagnostics";
import { OSC_FIELDS, ParamId, paramById, ParamInfo, ParamScope } from "../lang/params";
import { Song } from "../lang/song";
import { DurUnit, Typed } from "../lang/types";
import { Curve, curveFromName, curveValue } from "./curves";
import { EventKind, ScoreEvent, sortEvents } from "./events";
import { DEFAULT_INSTRUMENT, diagnosticsFor, InstrumentDef, InstrumentLibrary } from "./instrument";
import { buildGrid, buildPlayback, Grid, Playback, PlaybackOptions, songRows } from "./timeline";

export const MAX_PATTERN_DEPTH: i32 = 8;
// Rows patterns may keep playing past the end of the song.
export const MAX_TAIL_ROWS: i32 = 100000;

export class CompileOptions {
    loops: i32 = 1;
    startRow: i32 = 0;
}

export class Score {
    events: Array<ScoreEvent> = [];
    instruments: Array<InstrumentDef> = [];
    channelNames: Array<string> = [];
    grid: Grid = new Grid();
    playback: Playback = new Playback();
    duration: f64 = 0; // when the End event fires
    loopStart: f64 = -1; // the endless loop, in seconds; -1 when there is none
    loopEnd: f64 = -1;
    diagnostics: Array<Diagnostic> = [];

    // The source row playing at `time`, for the playhead.
    rowAt(time: f64): i32 {
        let p = this.playback.playedAt(time);
        return p < 0 ? 0 : this.playback.source[p];
    }

    count(kind: EventKind): i32 {
        let n = 0;
        for (let i = 0; i < this.events.length; i++) if (this.events[i].kind == kind) n++;
        return n;
    }

    // One line per event, for tests and debugging.
    dump(kind: i32 = -1): string {
        let out = "";
        for (let i = 0; i < this.events.length; i++) {
            let e = this.events[i];
            if (kind >= 0 && <i32>e.kind != kind) continue;
            out += e.describe() + "\n";
        }
        return out;
    }
}

// A parameter's value over time, as far as the compiler knows it.
class ParamTrack {
    value: f64 = NaN;
    from: f64 = NaN;
    start: f64 = 0;
    seconds: f64 = 0;
    curve: i32 = Curve.Linear;

    valueAt(t: f64): f64 {
        if (this.seconds <= 0 || t >= this.start + this.seconds) return this.value;
        if (isNaN(this.from)) return this.value;
        return curveValue(this.from, this.value, (t - this.start) / this.seconds, this.curve);
    }

    clone(): ParamTrack {
        let p = new ParamTrack();
        p.value = this.value;
        p.from = this.from;
        p.start = this.start;
        p.seconds = this.seconds;
        p.curve = this.curve;
        return p;
    }
}

// The persistent state of a channel or a pattern instance (§4.5).
class ChannelState {
    inst: i32 = 0;
    oct: f64 = 4;
    transpose: f64 = 0;
    vel: f64 = 0.8;
    len: Typed = Typed.duration(DurUnit.Rows, 1);
    // Keyed by (instrument + 1) × 256 + param: channel-strip params use instrument -1.
    params: Map<i32, ParamTrack> = new Map<i32, ParamTrack>();

    clone(): ChannelState {
        let s = new ChannelState();
        s.inst = this.inst;
        s.oct = this.oct;
        s.transpose = this.transpose;
        s.vel = this.vel;
        s.len = this.len;
        let keys = this.params.keys();
        for (let i = 0; i < keys.length; i++) s.params.set(keys[i], this.params.get(keys[i]).clone());
        return s;
    }

    track(inst: i32, param: i32): ParamTrack {
        let key = (inst + 1) * 256 + param;
        if (!this.params.has(key)) this.params.set(key, new ParamTrack());
        return this.params.get(key);
    }
}

class Instance {
    rep: i32 = -1;
    owner: i32 = 0;
    active: bool = true;
    state: ChannelState;

    constructor(
        public name: string,
        public pattern: CheckedFile,
        public start: i32, // played row of its first row
        public times: i32,
        public callState: ChannelState,
        public snapshotOwner: i32, // a frozen copy of the caller's parameters at the call
        public depth: i32,
        public id: string,
    ) {
        this.state = callState.clone();
    }

    get length(): i32 {
        return this.pattern.rowCount;
    }

    get endRow(): i32 {
        return this.start + this.length * this.times;
    }
}

class Compiler {
    score: Score = new Score();
    library: InstrumentLibrary;
    playback: Playback = new Playback();
    grid: Grid = new Grid();
    diagnostics: Map<string, Diagnostics> = new Map<string, Diagnostics>();
    reported: Map<string, bool> = new Map<string, bool>();
    cyclic: Map<string, bool> = new Map<string, bool>(); // "pattern:line" of calls that close a cycle
    seq: i32 = 0;
    nextNote: i32 = 0;

    // Per channel while it is simulated:
    channel: i32 = 0;
    path: string = "";
    nextOwner: i32 = 1;
    instances: Array<Instance> = [];
    selected: Map<i32, bool> = new Map<i32, bool>(); // instruments selected on this channel
    lastPitch: f64 = NaN;

    constructor(public song: Song, public options: CompileOptions) {
        this.library = InstrumentLibrary.forSong(song, this.diagnostics);
    }

    report(path: string, line: i32, col: i32, endCol: i32, code: string, message: string): void {
        // Rows run again on every repeat and jump; report each problem once.
        let key = `${path}:${line}:${col}:${code}`;
        if (this.reported.has(key)) return;
        this.reported.set(key, true);
        diagnosticsFor(this.diagnostics, path).error(line, col, endCol, code, message);
    }

    emit(kind: EventKind, time: f64): ScoreEvent {
        let e = new ScoreEvent();
        e.kind = kind;
        e.time = time;
        e.seq = this.seq++;
        e.channel = this.channel;
        this.score.events.push(e);
        return e;
    }

    compile(): Score {
        let song = this.song;
        let score = this.score;
        let rows = songRows(song);
        this.grid = buildGrid(song, max<i32>(rows, song.rowCount), this.diagnostics);
        let po = new PlaybackOptions();
        po.loops = this.options.loops;
        po.startRow = this.options.startRow;
        this.playback = buildPlayback(song, this.grid, po, rows, this.diagnostics);
        score.grid = this.grid;
        score.playback = this.playback;
        score.instruments = this.library.defs;
        for (let i = 0; i < this.playback.events.length; i++) {
            let e = this.playback.events[i];
            e.seq = this.seq++;
            score.events.push(e);
        }
        this.findCycles();

        let tailEnd = this.playback.count;
        for (let ch = 0; ch < song.channels.length; ch++) {
            score.channelNames.push(song.channels[ch].name);
            tailEnd = max<i32>(tailEnd, this.runChannel(ch));
        }

        let pb = this.playback;
        for (let p = 0; p < pb.count; p++) {
            let mark = this.emit(EventKind.RowMark, pb.rowTime(p));
            mark.channel = -1;
            mark.row = pb.source[p];
            mark.played = p;
            mark.value = pb.bpm[p];
        }
        // The song ends after its last row and its last note, whichever is later.
        let endTime = pb.timeAt(<f64>tailEnd);
        for (let i = 0; i < score.events.length; i++) {
            let e = score.events[i];
            if (e.kind == EventKind.NoteOff && e.time > endTime) endTime = e.time;
        }
        let end = this.emit(EventKind.End, endTime);
        end.channel = -1;
        score.duration = end.time;
        if (pb.loopStart >= 0) {
            score.loopStart = pb.rowTime(pb.loopStart);
            score.loopEnd = pb.timeAt(<f64>pb.loopEnd);
        }
        if (pb.firstAudible > 0) this.foldPrefix();
        sortEvents(score.events);

        let all = song.diagnostics();
        let keys = this.diagnostics.keys();
        for (let i = 0; i < keys.length; i++) {
            let d = this.diagnostics.get(keys[i]);
            for (let k = 0; k < d.items.length; k++) all.push(d.items[k]);
        }
        score.diagnostics = all;
        return score;
    }

    // Marks every pattern call that can lead back to its own pattern.
    findCycles(): void {
        let song = this.song;
        for (let i = 0; i < song.patternNames.length; i++) {
            let from = song.patternNames[i];
            let cmds = song.patterns.get(from).commands();
            for (let c = 0; c < cmds.length; c++) {
                if (cmds[c].name != "pattern") continue;
                let to = cmds[c].str("name", "");
                if (this.reaches(to, from, new Map<string, bool>())) {
                    this.cyclic.set(`${from}:${cmds[c].line}:${cmds[c].node.col}`, true);
                    let v = cmds[c].get("name");
                    this.report(song.patterns.get(from).path, cmds[c].line, v.col, v.endCol, "pattern-cycle", `'${to}' leads back to '${from}', which would never end`);
                }
            }
        }
    }

    reaches(from: string, target: string, seen: Map<string, bool>): bool {
        if (from == target) return true;
        if (seen.has(from) || !this.song.patterns.has(from)) return false;
        seen.set(from, true);
        let cmds = this.song.patterns.get(from).commands();
        for (let c = 0; c < cmds.length; c++) {
            if (cmds[c].name == "pattern" && this.reaches(cmds[c].str("name", ""), target, seen)) return true;
        }
        return false;
    }

    // Simulates channel `ch`; returns the played row its last pattern ends on.
    runChannel(ch: i32): i32 {
        let source = this.song.channels[ch];
        this.channel = ch;
        this.path = source.file.path;
        this.nextOwner = 1;
        this.instances = [];
        this.selected = new Map<i32, bool>();
        this.lastPitch = NaN;
        let state = new ChannelState();
        state.inst = max<i32>(this.library.indexOf(DEFAULT_INSTRUMENT), 0);
        let file = source.file;
        let pb = this.playback;
        let p = 0;
        let last = pb.count;
        while (true) {
            let inSong = p < pb.count;
            // After end() nothing more starts, patterns included.
            if (!inSong && (pb.ended || !this.anyActive())) break;
            if (p >= pb.count + MAX_TAIL_ROWS) {
                this.report(this.path, 1, 1, 1, "limit", `patterns keep playing more than ${MAX_TAIL_ROWS} rows after the song ends`);
                break;
            }
            if (inSong) {
                let row = pb.source[p];
                if (row < file.rowCount) this.runRow(file.rows[row], p, state, 0, null);
            }
            // Instances started on this row play their first row now, so loop
            // by index: the list grows while it is walked.
            for (let i = 0; i < this.instances.length; i++) {
                let inst = this.instances[i];
                if (!inst.active || p < inst.start) continue;
                let k = p - inst.start;
                let rep = k / inst.length;
                if (rep >= inst.times) {
                    inst.active = false;
                    continue;
                }
                if (rep != inst.rep) {
                    inst.rep = rep;
                    inst.state = inst.callState.clone();
                    inst.owner = this.fork(inst.snapshotOwner, pb.rowTime(p));
                }
                let rowIndex = k % inst.length;
                this.runRow(inst.pattern.rows[rowIndex], p, inst.state, inst.owner, inst);
                if (k + 1 >= inst.length * inst.times) {
                    inst.active = false;
                    last = max<i32>(last, p + 1);
                }
            }
            p++;
        }
        return last;
    }

    anyActive(): bool {
        for (let i = 0; i < this.instances.length; i++) if (this.instances[i].active) return true;
        return false;
    }

    fork(parent: i32, time: f64): i32 {
        let owner = this.nextOwner++;
        let e = this.emit(EventKind.Fork, time);
        e.owner = owner;
        e.parent = parent;
        return owner;
    }

    runRow(cmds: Array<CheckedCommand>, p: i32, state: ChannelState, owner: i32, inst: Instance?): void {
        let path = inst != null ? inst.pattern.path : this.path;
        for (let i = 0; i < cmds.length; i++) this.run(cmds[i], p, state, owner, inst, path);
    }

    run(c: CheckedCommand, p: i32, state: ChannelState, owner: i32, inst: Instance?, path: string): void {
        let n = c.name;
        let pb = this.playback;
        let t = pb.rowTime(p);
        if (n == "note") {
            let pitches = c.get("p").items;
            let list = new Array<f64>();
            for (let i = 0; i < pitches.length; i++) list.push(this.pitchOf(pitches[i], state));
            this.notes(c, p, state, owner, list, 0, path);
        } else if (n == "chord") {
            let root = this.pitchOf(c.get("root"), state);
            let intervals = chordIntervals(c.str("type", "maj"));
            let list = new Array<f64>();
            for (let i = 0; i < intervals.length; i++) list.push(root + <f64>intervals[i]);
            let inv = <i32>c.num("inv", 0);
            for (let k = 0; k < inv; k++) {
                let low = list.shift();
                list.push(low + 12);
            }
            let spread = c.num("spread", 0);
            for (let k = 1; k < list.length; k += 2) list[k] += 12 * spread;
            let strum = c.has("strum") ? pb.secondsOf(c.get("strum"), <f64>p) : 0;
            this.notes(c, p, state, owner, list, strum, path);
        } else if (n == "cut") {
            let e = this.emit(EventKind.Cut, t);
            e.seconds = c.has("fade") ? pb.secondsOf(c.get("fade"), <f64>p) : 0.005;
        } else if (n == "inst") {
            let name = c.str("name", "");
            let index = this.instrument(c, name, path);
            if (index >= 0) {
                state.inst = index;
                if (!this.selected.has(index)) {
                    this.selected.set(index, true);
                    this.applyDefaults(this.library.def(index), t, state, owner);
                }
            }
        } else if (n == "oct") {
            state.oct = c.num("v", state.oct);
        } else if (n == "transpose") {
            state.transpose = c.num("v", 0);
        } else if (n == "vel") {
            state.vel = c.num("v", state.vel);
        } else if (n == "len") {
            state.len = c.get("v");
        } else if (n == "vol") {
            this.setParam(state, owner, -1, ParamId.Vol, c.num("v", 0.8), t, 0, Curve.Linear);
        } else if (n == "pan") {
            this.setParam(state, owner, -1, ParamId.Pan, c.num("v", 0), t, 0, Curve.Linear);
        } else if (n == "set" || n == "ramp") {
            let seconds = n == "ramp" ? pb.secondsOf(c.get("over"), <f64>p) : 0;
            let curve = curveFromName(c.str("curve", "linear"));
            for (let k = 0; k < c.params.length; k++) {
                let pa = c.params[k];
                let target = this.resolveParam(pa, state, c, path);
                if (target == null) continue;
                let value = target.value;
                this.setParam(state, owner, target.inst, target.info.id, value, t, seconds, curve);
            }
        } else if (n == "glide") {
            let e = this.emit(EventKind.Glide, t);
            e.pitch = this.pitchOf(c.get("to"), state);
            e.seconds = pb.secondsOf(c.get("over"), <f64>p);
        } else if (n == "lfo" || n == "lfo_off") {
            let target = this.resolveParam(c.params[0], state, c, path);
            if (target == null) return;
            let e = this.emit(n == "lfo" ? EventKind.Lfo : EventKind.LfoOff, t);
            e.owner = owner;
            e.inst = target.inst;
            e.param = target.info.id;
            e.note = idNumber(c.str("id", ""));
            if (n == "lfo") {
                let rate = c.get("rate");
                if (rate.unit == DurUnit.Hz) {
                    e.rate = rate.num;
                } else {
                    let cycle = pb.secondsOf(rate, <f64>p);
                    e.rate = cycle > 0 ? 1 / cycle : 0;
                }
                e.value = c.num("depth", 0);
                e.curve = lfoShape(c.str("shape", "sine"));
            }
        } else if (n == "pattern") {
            this.startPattern(c, p, state, owner, inst, path);
        } else if (n == "stop") {
            let id = c.str("id", "");
            for (let i = 0; i < this.instances.length; i++) {
                let other = this.instances[i];
                if (id.length == 0 || other.id == id) other.active = false;
            }
        }
    }

    pitchOf(v: Typed, state: ChannelState): f64 {
        let midi = v.hasOctave ? v.num : (state.oct + 1) * 12 + v.num;
        return midi + state.transpose;
    }

    instrument(c: CheckedCommand, name: string, path: string): i32 {
        let index = this.library.indexOf(name);
        if (index < 0) {
            let v = c.has("name") ? c.get("name") : c.get("inst");
            this.report(path, c.line, v.col, v.endCol, "unknown-instrument", `there is no instrument or preset named '${name}'`);
        }
        return index;
    }

    notes(c: CheckedCommand, p: i32, state: ChannelState, owner: i32, pitches: Array<f64>, strum: f64, path: string): void {
        let pb = this.playback;
        let instIndex = state.inst;
        if (c.has("inst")) {
            instIndex = this.instrument(c, c.str("inst", ""), path);
            if (instIndex < 0) return;
        }
        let rowStart = pb.rowTime(p);
        let rowDur = pb.rowDur(p);
        let at = 0.0;
        if (c.has("at")) {
            let a = c.get("at");
            at = pb.secondsOf(a, <f64>p);
            if (at >= rowDur) {
                this.report(path, c.line, a.col, a.endCol, "range", "'at' reaches past the end of the row; the note starts at the end of the row instead");
                at = rowDur * 0.999;
            }
        }
        let pos = <f64>p + (rowDur > 0 ? at / rowDur : 0);
        let len = c.has("len") ? c.get("len") : state.len;
        let seconds = pb.secondsOf(len, pos);
        let vel = c.num("vel", state.vel);
        let glide = c.has("glide") ? pb.secondsOf(c.get("glide"), pos) : 0;
        for (let i = 0; i < pitches.length; i++) {
            let start = rowStart + at + strum * <f64>i;
            let note = this.nextNote++;
            let on = this.emit(EventKind.NoteOn, start);
            on.owner = owner;
            on.note = note;
            on.pitch = pitches[i];
            on.vel = vel;
            on.inst = instIndex;
            on.seconds = seconds;
            on.from = glide > 0 ? this.lastPitch : NaN;
            on.value = glide;
            on.row = c.line;
            let off = this.emit(EventKind.NoteOff, start + seconds);
            off.owner = owner;
            off.note = note;
            this.lastPitch = pitches[i];
        }
    }

    applyDefaults(def: InstrumentDef, t: f64, state: ChannelState, owner: i32): void {
        if (!isNaN(def.defaultVol)) this.setParam(state, owner, -1, ParamId.Vol, def.defaultVol, t, 0, Curve.Linear);
        if (!isNaN(def.defaultPan)) this.setParam(state, owner, -1, ParamId.Pan, def.defaultPan, t, 0, Curve.Linear);
        if (!isNaN(def.defaultDelay)) this.setParam(state, owner, -1, ParamId.Delay, def.defaultDelay, t, 0, Curve.Linear);
        if (!isNaN(def.defaultReverb)) this.setParam(state, owner, -1, ParamId.Reverb, def.defaultReverb, t, 0, Curve.Linear);
    }

    // Which parameter `pa` moves for the current instrument, and to what.
    resolveParam(pa: ParamArg, state: ChannelState, c: CheckedCommand, path: string): Target? {
        let info = pa.info;
        let value = pa.value.num;
        if (info == null) {
            let def = this.library.def(state.inst);
            let macro = def.macro(pa.name);
            if (macro == null) {
                this.report(path, c.line, pa.col, pa.endCol, "unknown-arg", `instrument '${def.name}' has no parameter '${pa.name}'`);
                return null;
            }
            info = macro.target;
            value = macro.map(value);
        }
        let inst = info.scope == ParamScope.Channel ? -1 : state.inst;
        return new Target(info, inst, value);
    }

    // A parameter's value before anything sets it: the channel strip's default,
    // or what the instrument defines.
    initialValue(inst: i32, param: i32): f64 {
        if (inst < 0) {
            let info = paramById(param);
            return info != null ? info.defaultValue : NaN;
        }
        let def = this.library.def(inst);
        if (param == ParamId.Cutoff) return def.cutoff;
        if (param == ParamId.Res) return def.res;
        if (param == ParamId.Env) return def.filterEnvAmount;
        if (param == ParamId.Keytrack) return def.keytrack;
        if (param == ParamId.Drive) return def.drive;
        if (param == ParamId.Glide) return def.glide;
        if (param == ParamId.Attack) return def.amp.a;
        if (param == ParamId.Decay) return def.amp.d;
        if (param == ParamId.Sustain) return def.amp.s;
        if (param == ParamId.Release) return def.amp.r;
        if (param == ParamId.Pw) return def.oscs[0].pw;
        if (param == ParamId.Detune) return def.oscs[0].detune;
        if (param >= ParamId.Osc && param < ParamId.Count) {
            let o = (param - ParamId.Osc) / OSC_FIELDS.length;
            if (o >= def.oscs.length) return NaN;
            let osc = def.oscs[o];
            let field = (param - ParamId.Osc) % OSC_FIELDS.length;
            if (field == 0) return osc.level;
            if (field == 1) return osc.detune;
            if (field == 2) return osc.pw;
            return osc.fm;
        }
        return NaN;
    }

    setParam(state: ChannelState, owner: i32, inst: i32, param: i32, value: f64, t: f64, seconds: f64, curve: i32): void {
        let track = state.track(inst, param);
        let from = track.valueAt(t);
        if (isNaN(from)) from = this.initialValue(inst, param);
        track.from = from;
        track.value = value;
        track.start = t;
        track.seconds = seconds;
        track.curve = curve;
        let e = this.emit(EventKind.Param, t);
        e.owner = owner;
        e.inst = inst;
        e.param = param;
        e.value = value;
        e.from = seconds > 0 ? from : NaN;
        e.seconds = seconds;
        e.curve = curve;
    }

    startPattern(c: CheckedCommand, p: i32, state: ChannelState, owner: i32, caller: Instance?, path: string): void {
        let name = c.str("name", "");
        let song = this.song;
        let v = c.get("name");
        if (!song.patterns.has(name)) {
            this.report(path, c.line, v.col, v.endCol, "unknown-pattern", `there is no pattern named '${name}' (patterns/${name}.pat)`);
            return;
        }
        if (caller != null && this.cyclic.has(`${caller.name}:${c.line}:${c.node.col}`)) return;
        let depth = caller != null ? caller.depth + 1 : 1;
        if (depth > MAX_PATTERN_DEPTH) {
            this.report(path, c.line, v.col, v.endCol, "limit", `patterns nest at most ${MAX_PATTERN_DEPTH} deep`);
            return;
        }
        let file = song.patterns.get(name);
        if (file.rowCount == 0) {
            this.report(path, c.line, v.col, v.endCol, "range", `pattern '${name}' is empty`);
            return;
        }
        let snapshot = this.fork(owner, this.playback.rowTime(p));
        let times = <i32>c.num("times", 1);
        this.instances.push(new Instance(name, file, p, times, state.clone(), snapshot, depth, c.str("id", "")));
    }

    // Rows before the start set state only (§6.3): their sounds are dropped and
    // their state changes land at time 0, with ramps resumed part-way.
    foldPrefix(): void {
        let kept = new Array<ScoreEvent>();
        let dropped = new Map<i32, bool>();
        let events = this.score.events;
        for (let i = 0; i < events.length; i++) {
            let e = events[i];
            if (e.time >= 0) {
                if (e.kind == EventKind.NoteOff && dropped.has(e.note)) continue;
                kept.push(e);
                continue;
            }
            let k = e.kind;
            if (k == EventKind.NoteOn) {
                dropped.set(e.note, true);
            } else if (k == EventKind.Param) {
                if (e.seconds > 0 && e.time + e.seconds > 0) {
                    let u = -e.time / e.seconds;
                    if (!isNaN(e.from)) e.from = curveValue(e.from, e.value, u, e.curve);
                    // Exact only for linear ramps; the others resume on their own curve.
                    e.seconds = e.time + e.seconds;
                } else {
                    e.seconds = 0;
                    e.from = NaN;
                }
                e.time = 0;
                kept.push(e);
            } else if (k == EventKind.Fork || k == EventKind.Lfo || k == EventKind.LfoOff) {
                e.time = 0;
                kept.push(e);
            }
        }
        this.score.events = kept;
    }
}

class Target {
    constructor(public info: ParamInfo, public inst: i32, public value: f64) {}
}

function lfoShape(name: string): i32 {
    if (name == "tri") return 1;
    if (name == "saw") return 2;
    if (name == "square") return 3;
    if (name == "random") return 4;
    return 0;
}

// LFO ids are names in the source and numbers in the score.
function idNumber(id: string): i32 {
    let h: i32 = 0;
    for (let i = 0; i < id.length; i++) h = h * 31 + id.charCodeAt(i);
    return h & 0x7fffffff;
}

export function compileSong(song: Song, options: CompileOptions = new CompileOptions()): Score {
    let compiler = new Compiler(song, options);
    return compiler.compile();
}
