// The score compiler (docs/spec.md §9.1): simulates every channel in playback
// order and emits the events the engine plays.

import { checkArgValue, CheckedCommand, CheckedFile, ParamArg } from "../lang/check";
import { ValueKind, ValueNode } from "../lang/ast";
import { MODES } from "../lang/commands";
import { degreeSemitones, parseNumeral, progressionTokens } from "../lang/scales";
import { chordIntervals } from "../lang/commands";
import { Diagnostic, Diagnostics } from "../lang/diagnostics";
import { OSC_FIELDS, ParamId, paramById, ParamInfo, ParamScope } from "../lang/params";
import { BUS_CHANNEL, FILTER_MODES, FX_BASE, fxParams, fxTypeId, SEND_BASE } from "../lang/fx";
import { Song } from "../lang/song";
import { DurUnit, Typed } from "../lang/types";
import { Curve, curveFromName, curveValue } from "./curves";
import { EventKind, ScoreEvent, sortEvents } from "./events";
import { DEFAULT_INSTRUMENT, diagnosticsFor, InstrumentDef, InstrumentLibrary } from "./instrument";
import { buildGrid, buildPlayback, Grid, makeTuning, Playback, PlaybackOptions, songRows } from "./timeline";

export const MAX_PATTERN_DEPTH: i32 = 8;
// Rows patterns may keep playing past the end of the song.
export const MAX_TAIL_ROWS: i32 = 100000;

export class CompileOptions {
    loops: i32 = 1;
    startRow: i32 = 0;
    // The last source row to play (-1: the whole song). Playback stops when it
    // first passes this row; notes still held are released there.
    endRow: i32 = -1;
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
    keyRoot: i32 = -1; // the track's own key (§5.6), or -1 to follow the song's
    keyMode: i32 = 0;
    humanizeTime: Typed? = null; // humanize (§6.5): the most a note moves, and its velocity
    humanizeVel: f64 = 0;
    tuning: i32 = -1; // the track's own tuning (an index into the playback's), or -1 for the song's
    // Keyed by (instrument + 1) × 256 + param: channel-strip params use instrument -1.
    params: Map<i32, ParamTrack> = new Map<i32, ParamTrack>();

    clone(): ChannelState {
        let s = new ChannelState();
        s.inst = this.inst;
        s.oct = this.oct;
        s.transpose = this.transpose;
        s.vel = this.vel;
        s.len = this.len;
        s.keyRoot = this.keyRoot;
        s.keyMode = this.keyMode;
        s.humanizeTime = this.humanizeTime;
        s.humanizeVel = this.humanizeVel;
        s.tuning = this.tuning;
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
    vars: Map<string, ValueNode> = new Map<string, ValueNode>(); // its variables' values (§8.1)

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
    fxCount: i32 = 0; // effects declared so far on the channel being compiled
    seed: u32 = 1; // song.yaml's seed (§6.5)
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

    // When playback first passes `options.endRow`, or -1.
    cutTime(): f64 {
        let last = this.options.endRow;
        if (last < 0) return -1;
        let pb = this.playback;
        for (let p = pb.firstAudible; p < pb.count; p++) {
            if (pb.source[p] > last) return pb.rowTime(p);
        }
        return -1;
    }

    compile(): Score {
        let song = this.song;
        let score = this.score;
        this.seed = <u32>song.config.seed;
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
        // Routing (§7.5): tracks that play into a bus, from the start.
        for (let ch = 0; ch < song.channels.length; ch++) {
            let bus = song.channels[ch].config.bus;
            if (bus.length == 0) continue;
            for (let b = 0; b < song.buses.length; b++) {
                if (song.buses[b].name != bus) continue;
                this.channel = ch;
                let e = this.emit(EventKind.Route, 0);
                e.value = <f64>b;
            }
        }
        for (let ch = 0; ch < song.channels.length; ch++) {
            score.channelNames.push(song.channels[ch].name);
            tailEnd = max<i32>(tailEnd, this.runChannel(ch));
        }
        for (let b = 0; b < song.buses.length; b++) {
            tailEnd = max<i32>(tailEnd, this.runSource(BUS_CHANNEL + b, song.buses[b].file));
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
        let cut = this.cutTime();
        if (cut >= 0 && cut < endTime) {
            // Cut at the end row: nothing starts after it, held notes stop there.
            let kept = new Array<ScoreEvent>();
            for (let i = 0; i < score.events.length; i++) {
                let e = score.events[i];
                if (e.time < cut) kept.push(e);
                else if (e.kind == EventKind.NoteOff) {
                    e.time = cut;
                    kept.push(e);
                }
            }
            score.events = kept;
            endTime = cut;
        }
        let end = this.emit(EventKind.End, endTime);
        end.channel = -1;
        score.duration = end.time;
        if (pb.loopStart >= 0 && !(cut >= 0 && pb.rowTime(pb.loopStart) >= cut)) {
            score.loopStart = pb.rowTime(pb.loopStart);
            score.loopEnd = Math.min(pb.timeAt(<f64>pb.loopEnd), end.time);
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
        return this.runSource(ch, this.song.channels[ch].file);
    }

    // Plays one file on channel `ch`: a track, or a bus (BUS_CHANNEL + b).
    runSource(ch: i32, file: CheckedFile): i32 {
        this.channel = ch;
        this.fxCount = 0;
        this.path = file.path;
        this.nextOwner = 1;
        this.instances = [];
        this.selected = new Map<i32, bool>();
        this.lastPitch = NaN;
        let state = new ChannelState();
        state.inst = max<i32>(this.library.indexOf(DEFAULT_INSTRUMENT), 0);
        let pb = this.playback;
        let p = 0;
        let last = pb.count;
        let visits = new Map<i32, i32>();
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
                if (row < file.rowCount) {
                    // The pass of a row: how many times it has played, jumps included.
                    let pass = visits.has(row) ? visits.get(row) + 1 : 1;
                    visits.set(row, pass);
                    this.runRow(file.rows[row], p, state, 0, null, pass);
                }
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
                this.runRow(inst.pattern.rows[rowIndex], p, inst.state, inst.owner, inst, rep + 1);
                if (k + 1 >= inst.length * inst.times) {
                    inst.active = false;
                    last = max<i32>(last, p + 1);
                }
            }
            // Finished instances are dropped, or songs that call a pattern
            // every bar would walk every instance ever made on every row.
            if (this.instances.length > 8) {
                let live = new Array<Instance>();
                for (let i = 0; i < this.instances.length; i++) if (this.instances[i].active) live.push(this.instances[i]);
                if (live.length < this.instances.length) this.instances = live;
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

    runRow(cmds: Array<CheckedCommand>, p: i32, state: ChannelState, owner: i32, inst: Instance?, pass: i32): void {
        let path = inst != null ? inst.pattern.path : this.path;
        for (let i = 0; i < cmds.length; i++) {
            let c = cmds[i];
            if (c.deferred.length > 0) {
                let bound = this.bind(c, inst, path);
                if (bound == null) continue;
                c = bound;
            }
            if (!this.passes(c, pass)) continue;
            // prob: plays this time with that chance (euclid draws per hit instead).
            if (c.has("prob") && c.name != "euclid" && this.random(c, p, owner, SALT_PROB, 0) >= c.num("prob", 1)) continue;
            this.run(c, p, state, owner, inst, path);
        }
    }

    // Whether a command plays on this pass: on: 3 (the third), on: 4/4 (the
    // fourth of every four), except: likewise, if: false (§8.2).
    passes(c: CheckedCommand, pass: i32): bool {
        if (c.has("if") && !c.get("if").bool) return false;
        if (c.has("on") && !onPass(c.get("on"), pass)) return false;
        if (c.has("except") && onPass(c.get("except"), pass)) return false;
        return true;
    }

    // A number in [0, 1) for command `c` on played row `p` (§6.5): a hash of
    // the song's seed, the track, the row, the owner, where the command is
    // written, what it is for (`salt`) and which draw it is (`k`). The same
    // seed gives the same numbers; every pass of a loop gets new ones.
    random(c: CheckedCommand, p: i32, owner: i32, salt: u32, k: i32): f64 {
        let h = mix32(this.seed ^ 0x9E3779B9);
        h = mix32(h ^ <u32>(this.channel + 17));
        h = mix32(h ^ <u32>p);
        h = mix32(h ^ <u32>owner);
        h = mix32(h ^ <u32>c.line);
        h = mix32(h ^ <u32>c.node.col);
        h = mix32(h ^ salt);
        h = mix32(h ^ <u32>k);
        return <f64>h / 4294967296.0;
    }

    // humanize: a note's start and velocity, moved at random within the track's limits.
    jitter(c: CheckedCommand, p: i32, owner: i32, state: ChannelState, k: i32, start: f64, vel: f64): Array<f64> {
        let t = start;
        let v = vel;
        let amount = state.humanizeTime;
        if (amount != null) {
            let range = this.playback.secondsOf(amount, <f64>p);
            t = Math.max(start + (this.random(c, p, owner, SALT_TIME, k) * 2 - 1) * range, 0);
        }
        if (state.humanizeVel > 0) v = Math.min(Math.max(vel + (this.random(c, p, owner, SALT_VEL, k) * 2 - 1) * state.humanizeVel, 0.01), 1);
        return [t, v];
    }

    // euclid(hits: 5, steps: 8): hits spread as evenly as they go over the
    // steps, `rot` steps later, one step per `every` (a row by default).
    euclid(c: CheckedCommand, p: i32, state: ChannelState, owner: i32, path: string): void {
        let pb = this.playback;
        let hits = <i32>c.num("hits", 0);
        let steps = <i32>c.num("steps", 1);
        let rot = <i32>c.num("rot", 0);
        let times = <i32>c.num("times", 1);
        let step = c.has("every") ? pb.rowsOf(c.get("every"), p) : 1;
        if (step <= 0 || hits <= 0) return;
        let instIndex = state.inst;
        if (c.has("inst")) {
            instIndex = this.instrument(c, c.str("inst", ""), path);
            if (instIndex < 0) return;
        }
        let pitches = new Array<f64>();
        if (c.has("d")) {
            let d = c.get("d");
            if (d.items.length == 0) pitches.push(this.degreePitch(<i32>d.num, state, p));
            for (let i = 0; i < d.items.length; i++) pitches.push(this.degreePitch(<i32>d.items[i].num, state, p));
        } else {
            let items = c.get("p").items;
            for (let i = 0; i < items.length; i++) pitches.push(this.pitchOf(items[i], state));
        }
        let prob = c.num("prob", 1);
        let vel = c.num("vel", state.vel);
        let len = c.has("len") ? c.get("len") : state.len;
        for (let t = 0; t < times; t++) {
            for (let i = 0; i < steps; i++) {
                if (!euclidHit(i, hits, steps, rot)) continue;
                let n = t * steps + i;
                if (prob < 1 && this.random(c, p, owner, SALT_PROB, n) >= prob) continue;
                let pos = <f64>p + <f64>n * step;
                let start = pb.timeAt(pos);
                this.emitNotes(pitches, start, pb.secondsOf(len, pos), vel, instIndex, owner, 0, c.line, c, p, state, n);
            }
        }
    }

    // `c` with its variables replaced by the pattern's values and typed (§8.1).
    bind(c: CheckedCommand, inst: Instance?, path: string): CheckedCommand? {
        let vars = inst != null ? inst.vars : new Map<string, ValueNode>();
        let out = new CheckedCommand(c.spec, c.node);
        let keys = c.args.keys();
        for (let i = 0; i < keys.length; i++) out.args.set(keys[i], c.args.get(keys[i]));
        out.params = c.params;
        out.vars = c.vars;
        for (let i = 0; i < c.deferred.length; i++) {
            let arg = c.deferred[i];
            let missing = new Array<string>();
            let value = substitute(arg.value, vars, missing);
            if (missing.length > 0) {
                let who = inst != null ? `pattern '${inst.name}'` : "this file";
                this.report(path, c.line, arg.value.col, arg.value.endCol, "variable", `${who} has no value for $${missing[0]}: give it in pattern(name: ..., ${missing[0]}: ...) or args(${missing[0]}: ...)`);
                return null;
            }
            let check = checkArgValue(c.spec.arg(arg.name)!, arg.name, value);
            let typed = check.value;
            if (typed == null) {
                this.report(path, c.line, arg.value.col, arg.value.endCol, "type", `${check.error} (from $${variableName(arg.value)})`);
                return null;
            }
            out.args.set(arg.name, typed);
        }
        return out;
    }

    run(c: CheckedCommand, p: i32, state: ChannelState, owner: i32, inst: Instance?, path: string): void {
        let n = c.name;
        let pb = this.playback;
        let t = pb.rowTime(p);
        if (n == "note") {
            let list = new Array<f64>();
            if (c.has("d")) {
                let d = c.get("d");
                if (d.items.length == 0) list.push(this.degreePitch(<i32>d.num, state, p));
                for (let i = 0; i < d.items.length; i++) list.push(this.degreePitch(<i32>d.items[i].num, state, p));
            } else {
                let pitches = c.get("p").items;
                for (let i = 0; i < pitches.length; i++) list.push(this.pitchOf(pitches[i], state));
            }
            if (c.has("pick")) {
                // pick: n of the listed notes, different ones, at random.
                let count = min<i32>(<i32>c.num("pick", 1), list.length);
                for (let k = 0; k < count; k++) {
                    let j = k + min<i32>(<i32>(this.random(c, p, owner, SALT_PICK, k) * <f64>(list.length - k)), list.length - k - 1);
                    let swap = list[k];
                    list[k] = list[j];
                    list[j] = swap;
                }
                list = list.slice(0, count);
            }
            this.notes(c, p, state, owner, list, 0, path);
        } else if (n == "key") {
            let root = c.get("root");
            state.keyRoot = (((<i32>root.num) % 12) + 12) % 12;
            state.keyMode = max<i32>(MODES.indexOf(c.str("mode", "major")), 0);
        } else if (n == "args") {
            // Defaults, read when the pattern starts.
        } else if (n == "prog") {
            this.progression(c, p, state, owner);
        } else if (n == "tuning") {
            let made = makeTuning(c, this.song, diagnosticsFor(this.diagnostics, path));
            if (made != null) {
                this.playback.tunings.push(made);
                state.tuning = this.playback.tunings.length - 1;
            }
        } else if (n == "humanize") {
            let time = c.has("time") ? c.get("time") : null;
            state.humanizeTime = time != null && time.num > 0 ? time : null;
            state.humanizeVel = c.num("vel", 0);
        } else if (n == "euclid") {
            this.euclid(c, p, state, owner, path);
        } else if (n == "pick") {
            // One pattern of the list, drawn again on every pass.
            let names = c.get("from").items;
            let i = min<i32>(<i32>(this.random(c, p, owner, SALT_PICK, 0) * <f64>names.length), names.length - 1);
            this.startNamed(c, names[i].str, names[i], p, state, owner, inst, path);
        } else if (n == "chord") {
            let list = new Array<f64>();
            if (c.has("d") && !c.has("type")) {
                // The key's own chord on that degree: every other scale note.
                let d = <i32>c.num("d", 1);
                let size = <i32>c.num("size", 3);
                for (let k = 0; k < size; k++) list.push(this.degreePitch(d + 2 * k, state, p));
            } else {
                let root = c.has("d") ? this.degreePitch(<i32>c.num("d", 1), state, p) : this.pitchOf(c.get("root"), state);
                let intervals = chordIntervals(c.str("type", "maj"));
                for (let i = 0; i < intervals.length; i++) list.push(root + <f64>intervals[i]);
            }
            voice(list, <i32>c.num("inv", 0), c.num("spread", 0));
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
            e.pitch = this.tuned(this.pitchOf(c.get("to"), state), state, p);
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
        } else if (n == "fx") {
            this.effect(c, t, state, owner, path);
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

    // fx(type: …): the effect, in the next place of the chain, and its
    // parameters' starting values (those it gives, or the defaults).
    effect(c: CheckedCommand, t: f64, state: ChannelState, owner: i32, path: string): void {
        let type = c.str("type", "");
        let e = this.emit(EventKind.Fx, t);
        e.note = this.fxCount++;
        e.inst = fxTypeId(type);
        e.param = -1;
        e.curve = max<i32>(FILTER_MODES.indexOf(c.str("mode", "lowpass")), 0);
        if (c.has("sidechain")) {
            let name = c.str("sidechain", "");
            for (let i = 0; i < this.song.channels.length; i++) if (this.song.channels[i].name == name) e.param = i;
            if (e.param < 0) {
                let v = c.get("sidechain");
                this.report(path, c.line, v.col, v.endCol, "unknown-track", `there is no track named '${name}' to key the compressor`);
            }
        }
        let all = fxParams();
        for (let i = 0; i < all.length; i++) {
            let f = all[i];
            if (f.type != type) continue;
            let value = c.has(f.arg) ? c.num(f.arg, f.defaultValue) : f.defaultValue;
            // A high-pass filter starts open at the bottom.
            if (type == "filter" && f.arg == "cutoff" && !c.has("cutoff") && e.curve == 1) value = 20;
            this.setParam(state, owner, -1, FX_BASE + i, value, t, 0, Curve.Linear);
        }
    }

    // The sounding pitch of written `pitch` in the tuning at row `p` (§7.6).
    tuned(pitch: f64, state: ChannelState, p: i32): f64 {
        let pb = this.playback;
        let index = state.tuning >= 0 ? state.tuning : pb.count > 0 ? pb.tuningAt[min<i32>(max<i32>(p, 0), pb.count - 1)] : 0;
        if (index <= 0 || index >= pb.tunings.length) return pitch;
        return pb.tunings[index].tune(pitch);
    }

    // The key at played row `p`: the track's own, or the song's.
    keyRootAt(state: ChannelState, p: i32): i32 {
        if (state.keyRoot >= 0) return state.keyRoot;
        let pb = this.playback;
        return pb.count > 0 ? pb.keyRoot[min<i32>(max<i32>(p, 0), pb.count - 1)] : 0;
    }

    keyModeAt(state: ChannelState, p: i32): i32 {
        if (state.keyRoot >= 0) return state.keyMode;
        let pb = this.playback;
        return pb.count > 0 ? pb.keyMode[min<i32>(max<i32>(p, 0), pb.count - 1)] : 0;
    }

    // Scale degree `d` of the key, in the octave `oct` sets (degree 1 is the root).
    degreePitch(d: i32, state: ChannelState, p: i32): f64 {
        return <f64>((<i32>state.oct + 1) * 12 + this.keyRootAt(state, p) + degreeSemitones(this.keyModeAt(state, p), d)) + state.transpose;
    }

    // prog(chords: "ii V7 I", every: 1bar): one chord per step from this row,
    // "-" holding the one before and "." resting.
    progression(c: CheckedCommand, p: i32, state: ChannelState, owner: i32): void {
        let pb = this.playback;
        let tokens = progressionTokens(c.str("chords", ""));
        let every = c.has("every") ? c.get("every") : Typed.duration(DurUnit.Bars, 1);
        let step = pb.rowsOf(every, p);
        if (step <= 0) return;
        let vel = c.num("vel", state.vel);
        let strum = c.has("strum") ? pb.secondsOf(c.get("strum"), <f64>p) : 0;
        let inv = <i32>c.num("inv", 0);
        let spread = c.num("spread", 0);
        let mode = this.keyModeAt(state, p);
        let root = this.keyRootAt(state, p);
        let base = <f64>((<i32>state.oct + 1) * 12 + root) + state.transpose;
        for (let i = 0; i < tokens.length; i++) {
            let n = parseNumeral(tokens[i], mode);
            if (n.hold || n.rest || n.error.length > 0) continue;
            let span = 1;
            while (i + span < tokens.length && tokens[i + span] == "-") span++;
            let pos = <f64>p + <f64>i * step;
            let start = pb.timeAt(pos);
            let seconds = c.has("len") ? pb.secondsOf(c.get("len"), pos) : pb.timeAt(pos + <f64>span * step) - start;
            let intervals = chordIntervals(n.type);
            let list = new Array<f64>();
            for (let k = 0; k < intervals.length; k++) list.push(base + <f64>(n.root + intervals[k]));
            voice(list, inv, spread);
            this.emitNotes(list, start, seconds, vel, state.inst, owner, strum, c.line, c, p, state, i);
        }
    }

    // Notes at `start` (strummed `strum` apart), like note(…) emits them.
    emitNotes(pitches: Array<f64>, start: f64, seconds: f64, vel: f64, instIndex: i32, owner: i32, strum: f64, line: i32,
        c: CheckedCommand, p: i32, state: ChannelState, k: i32): void {
        for (let i = 0; i < pitches.length; i++) {
            let moved = this.jitter(c, p, owner, state, k * 16 + i, start + strum * <f64>i, vel);
            let at = moved[0];
            let note = this.nextNote++;
            let on = this.emit(EventKind.NoteOn, at);
            on.owner = owner;
            on.note = note;
            on.pitch = this.tuned(pitches[i], state, p);
            on.vel = moved[1];
            on.inst = instIndex;
            on.seconds = seconds;
            on.from = NaN;
            on.value = 0;
            on.row = line;
            let off = this.emit(EventKind.NoteOff, at + seconds);
            off.owner = owner;
            off.note = note;
            this.lastPitch = on.pitch;
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
            let moved = this.jitter(c, p, owner, state, i, rowStart + at + strum * <f64>i, vel);
            let start = moved[0];
            let note = this.nextNote++;
            let on = this.emit(EventKind.NoteOn, start);
            on.owner = owner;
            on.note = note;
            on.pitch = this.tuned(pitches[i], state, p);
            on.vel = moved[1];
            on.bend = c.num("bend", 0);
            on.press = c.num("press", 0);
            on.inst = instIndex;
            on.seconds = seconds;
            on.from = glide > 0 ? this.lastPitch : NaN;
            on.value = glide;
            on.row = c.line;
            let off = this.emit(EventKind.NoteOff, start + seconds);
            off.owner = owner;
            off.note = note;
            this.lastPitch = on.pitch;
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
        let inst = info.scope == ParamScope.Channel || info.scope == ParamScope.Strip ? -1 : state.inst;
        return new Target(info, inst, value);
    }

    // A parameter's value before anything sets it: the channel strip's default,
    // or what the instrument defines.
    initialValue(inst: i32, param: i32): f64 {
        if (param >= SEND_BASE) return 0;
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
        if (param == ParamId.Pos) return 0;
        if (param == ParamId.Width) return def.width;
        if (param >= ParamId.Osc && param < ParamId.Count) {
            let o = (param - ParamId.Osc) / OSC_FIELDS.length;
            if (o >= def.oscs.length) return NaN;
            let osc = def.oscs[o];
            let field = (param - ParamId.Osc) % OSC_FIELDS.length;
            if (field == 0) return osc.level;
            if (field == 1) return osc.detune;
            if (field == 2) return osc.pw;
            if (field == 3) return osc.fm;
            return osc.pos;
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
        this.startNamed(c, c.str("name", ""), c.get("name"), p, state, owner, caller, path);
    }

    // Starts pattern `name` as `c` asks (pattern, or the one pick drew); `v`
    // is where the name is written.
    startNamed(c: CheckedCommand, name: string, v: Typed, p: i32, state: ChannelState, owner: i32, caller: Instance?, path: string): void {
        let song = this.song;
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
        // Its variables: the pattern's own defaults (args), then the call's values,
        // which may use the caller's variables.
        let vars = new Map<string, ValueNode>();
        for (let r = 0; r < file.rows.length; r++) {
            let row = file.rows[r];
            for (let k = 0; k < row.length; k++) {
                if (row[k].name != "args") continue;
                let names = row[k].vars.keys();
                for (let j = 0; j < names.length; j++) vars.set(names[j], row[k].vars.get(names[j]));
            }
        }
        let given = c.vars.keys();
        for (let j = 0; j < given.length; j++) {
            let missing = new Array<string>();
            let value = substitute(c.vars.get(given[j]), caller != null ? caller.vars : new Map<string, ValueNode>(), missing);
            if (missing.length > 0) {
                let w = c.vars.get(given[j]);
                this.report(path, c.line, w.col, w.endCol, "variable", `no value for $${missing[0]} here`);
                continue;
            }
            vars.set(given[j], value);
        }
        let snapshot = this.fork(owner, this.playback.rowTime(p));
        let times = <i32>c.num("times", 1);
        let instance = new Instance(name, file, p, times, state.clone(), snapshot, depth, c.str("id", ""));
        instance.vars = vars;
        this.instances.push(instance);
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

// Inversions move the lowest notes up an octave; spread lifts every other note.
function voice(list: Array<f64>, inv: i32, spread: f64): void {
    for (let k = 0; k < inv; k++) {
        let low = list.shift();
        list.push(low + 12);
    }
    for (let k = 1; k < list.length; k += 2) list[k] += 12 * spread;
}

// Whether `pass` is one `t` names: N, or N/M (the Nth of every M).
function onPass(t: Typed, pass: i32): bool {
    let n = <i32>t.num;
    let m = <i32>t.num2;
    if (m <= 0) return pass == n;
    return (pass - 1) % m == n - 1;
}

function variableName(v: ValueNode): string {
    if (v.kind == ValueKind.Word && v.text.startsWith("$")) return v.text.substring(1);
    for (let i = 0; i < v.items.length; i++) {
        let n = variableName(v.items[i]);
        if (n.length > 0) return n;
    }
    return "";
}

// `v` with each $name replaced by its value in `vars`; names with no value
// go to `missing`.
function substitute(v: ValueNode, vars: Map<string, ValueNode>, missing: Array<string>): ValueNode {
    if (v.kind == ValueKind.Word && v.text.startsWith("$")) {
        let name = v.text.substring(1);
        if (!vars.has(name)) {
            missing.push(name);
            return v;
        }
        let found = vars.get(name);
        let out = new ValueNode();
        out.kind = found.kind;
        out.text = found.text;
        out.num = found.num;
        out.den = found.den;
        out.unit = found.unit;
        out.items = found.items;
        out.col = v.col;
        out.endCol = v.endCol;
        return out;
    }
    if (v.kind == ValueKind.List) {
        let out = new ValueNode();
        out.kind = ValueKind.List;
        out.text = v.text;
        out.col = v.col;
        out.endCol = v.endCol;
        for (let i = 0; i < v.items.length; i++) out.items.push(substitute(v.items[i], vars, missing));
        return out;
    }
    return v;
}

// What each random draw is for, so they do not repeat each other (§6.5).
const SALT_PROB: u32 = 1;
const SALT_TIME: u32 = 2;
const SALT_VEL: u32 = 3;
const SALT_PICK: u32 = 4;

// A 32-bit integer hash (lowbias32).
function mix32(x: u32): u32 {
    let h = x;
    h ^= h >> 16;
    h *= 0x7feb352d;
    h ^= h >> 15;
    h *= 0x846ca68b;
    h ^= h >> 16;
    return h;
}

// Whether step `i` of a Euclidean rhythm of `hits` over `steps`, rotated
// `rot` steps later, is a hit.
export function euclidHit(i: i32, hits: i32, steps: i32, rot: i32): bool {
    let j = (((i - rot) % steps) + steps) % steps;
    return (j * hits) % steps < hits;
}
