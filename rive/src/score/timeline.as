// The conductor timeline (docs/spec.md §6): where each source row sits in
// bars and beats, the order rows play in once marks and jumps are followed,
// and when each played row starts.

import { CheckedCommand } from "../lang/check";
import { Diagnostics } from "../lang/diagnostics";
import { ParamId } from "../lang/params";
import { FILTER_MODES, FX_BASE, fxParams, fxTypeId } from "../lang/fx";
import { MODES } from "../lang/commands";
import { builtinTuning, parseScala, Tuning } from "../lang/tuning";
import { Song } from "../lang/song";
import { DurUnit, Typed } from "../lang/types";
import { curveFromName, curveValue, Curve } from "./curves";
import { EventKind, MASTER_CHANNEL, ScoreEvent } from "./events";
import { diagnosticsFor } from "./instrument";

// Played rows are capped so a runaway arrangement cannot exhaust memory.
export const MAX_PLAYED_ROWS: i32 = 200000;

// One source row as the gutter shows it, counted in source order (§10.2).
export class GridRow {
    bar: i32 = 0; // 0-based
    beat: i32 = 0; // 0-based within the bar
    rowInBeat: i32 = 0;
    rpb: i32 = 4;
    sigNum: i32 = 4;
    sigDen: i32 = 4;
    mark: string = "";

    // "9.1" on a beat's first row, the row within the beat otherwise.
    label(): string {
        if (this.rowInBeat == 0) return `${this.bar + 1}.${this.beat + 1}`;
        return `${this.rowInBeat + 1}`;
    }
}

export class Grid {
    rows: Array<GridRow> = [];
    marks: Map<string, i32> = new Map<string, i32>();

    row(index: i32): GridRow {
        if (index < this.rows.length) return this.rows[index];
        // Past the last row: continue the last row's meter.
        let last = this.rows.length > 0 ? this.rows[this.rows.length - 1] : new GridRow();
        let r = new GridRow();
        r.rpb = last.rpb;
        r.sigNum = last.sigNum;
        r.sigDen = last.sigDen;
        r.rowInBeat = index % last.rpb;
        return r;
    }
}

export function buildGrid(song: Song, rowCount: i32, diagnostics: Map<string, Diagnostics>): Grid {
    let grid = new Grid();
    let config = song.config;
    let rpb = config.rowsPerBeat;
    let sigNum = config.sigNum;
    let sigDen = config.sigDen;
    let segmentStart = 0;
    let barOffset = 0;
    let lastBar = -1;
    let conductor = song.conductor;
    let d = diagnosticsFor(diagnostics, conductor.path);
    for (let r = 0; r < rowCount; r++) {
        let mark = "";
        if (r < conductor.rowCount) {
            let cmds = conductor.rows[r];
            let changed = false;
            for (let i = 0; i < cmds.length; i++) {
                let c = cmds[i];
                if (c.name == "sig") {
                    let v = c.get("v");
                    sigNum = <i32>v.num;
                    sigDen = <i32>v.num2;
                    changed = true;
                } else if (c.name == "rpb") {
                    rpb = <i32>c.num("v", <f64>rpb);
                    changed = true;
                } else if (c.name == "mark") {
                    mark = c.str("name", "");
                    if (grid.marks.has(mark)) {
                        let v = c.get("name");
                        d.error(c.line, v.col, v.endCol, "duplicate-mark", `mark '${mark}' is already set on row ${grid.marks.get(mark) + 1}`);
                    } else {
                        grid.marks.set(mark, r);
                    }
                }
            }
            if (changed && r > 0) {
                segmentStart = r;
                barOffset = lastBar + 1;
            }
        }
        let k = r - segmentStart;
        let rowsPerBar = rpb * sigNum;
        let row = new GridRow();
        row.rpb = rpb;
        row.sigNum = sigNum;
        row.sigDen = sigDen;
        row.bar = barOffset + k / rowsPerBar;
        row.beat = (k % rowsPerBar) / rpb;
        row.rowInBeat = k % rpb;
        row.mark = mark;
        lastBar = row.bar;
        grid.rows.push(row);
    }
    return grid;
}

// How many rows a tempo-relative duration spans in a given meter; NaN for an
// absolute time.
export function durationRows(d: Typed, rpb: i32, sigNum: i32, sigDen: i32): f64 {
    if (d.unit == DurUnit.Rows) return d.num;
    if (d.unit == DurUnit.Beats) return d.num * <f64>rpb;
    if (d.unit == DurUnit.Bars) return d.num * <f64>rpb * <f64>sigNum;
    if (d.unit == DurUnit.Note) return d.num * <f64>sigDen * <f64>rpb;
    return NaN;
}

class TempoRamp {
    constructor(
        public start: f64, // played position
        public rows: f64,
        public from: f64,
        public to: f64,
        public curve: i32,
    ) {}

    bpmAt(pos: f64): f64 {
        let u = this.rows > 0 ? (pos - this.start) / this.rows : 1;
        return curveValue(this.from, this.to, u, this.curve);
    }

    get end(): f64 {
        return this.start + this.rows;
    }
}

// A conductor ramp of `master` whose length is known only once every row's
// time is: resolved after the pass.
class PendingRamp {
    constructor(public played: i32, public event: ScoreEvent, public duration: Typed) {}
}

export class PlaybackOptions {
    // Extra passes each endless `jump` gets before it falls through (§6.4).
    loops: i32 = 1;
    // The source row playback starts at; earlier rows only set state (§6.3).
    startRow: i32 = 0;
}

export class Playback {
    source: Array<i32> = []; // source row of each played row
    start: Array<f64> = []; // start time, before swing
    dur: Array<f64> = [];
    swing: Array<f64> = []; // delay added to the start by swing
    bpm: Array<f64> = []; // tempo at the start
    rpb: Array<i32> = [];
    sigNum: Array<i32> = [];
    sigDen: Array<i32> = [];
    // The song's key at each played row (§5.6): its root (0..11) and mode (lang/scales.as).
    keyRoot: Array<i32> = [];
    keyMode: Array<i32> = [];
    // Tunings (§7.6): the list (0 is equal temperament) and the song's at each played row.
    tunings: Array<Tuning> = [builtinTuning("equal", 12, 60)];
    tuningAt: Array<i32> = [];
    firstAudible: i32 = 0; // played rows before it only set state
    loopStart: i32 = -1; // the endless loop's last pass, as played rows [start, end)
    loopEnd: i32 = -1;
    ended: bool = false; // stopped at `end()`
    events: Array<ScoreEvent> = []; // conductor events (master volume)

    get count(): i32 {
        return this.source.length;
    }

    get endTime(): f64 {
        let n = this.source.length;
        return n == 0 ? 0 : this.start[n - 1] + this.dur[n - 1];
    }

    // Row duration past the last played row.
    get lastDur(): f64 {
        let n = this.source.length;
        return n == 0 ? 0.125 : this.dur[n - 1];
    }

    // The time at a fractional played position, before swing. Positions past
    // the end continue at the last row's tempo.
    timeAt(pos: f64): f64 {
        let n = this.source.length;
        if (pos < 0) return n == 0 ? pos * 0.125 : this.start[0] + pos * this.dur[0];
        let i = <i32>Math.floor(pos);
        if (i < n) return this.start[i] + (pos - <f64>i) * this.dur[i];
        return this.endTime + (pos - <f64>n) * this.lastDur;
    }

    rowTime(played: i32): f64 {
        if (played < this.source.length) return this.start[played] + this.swing[played];
        return this.timeAt(<f64>played);
    }

    rowDur(played: i32): f64 {
        return played < this.source.length ? this.dur[played] : this.lastDur;
    }

    rpbAt(played: i32): i32 {
        let n = this.source.length;
        if (n == 0) return 4;
        return this.rpb[min<i32>(played, n - 1)];
    }

    sigNumAt(played: i32): i32 {
        let n = this.source.length;
        if (n == 0) return 4;
        return this.sigNum[min<i32>(played, n - 1)];
    }

    sigDenAt(played: i32): i32 {
        let n = this.source.length;
        if (n == 0) return 4;
        return this.sigDen[min<i32>(played, n - 1)];
    }

    // How many rows `d` spans when it starts on played row `played`; NaN for
    // absolute times.
    rowsOf(d: Typed, played: i32): f64 {
        return durationRows(d, this.rpbAt(played), this.sigNumAt(played), this.sigDenAt(played));
    }

    // How long `d` lasts in seconds when it starts at played position `pos`.
    secondsOf(d: Typed, pos: f64): f64 {
        if (d.unit == DurUnit.Seconds) return d.num;
        let played = <i32>Math.floor(Math.max(pos, 0));
        let rows = this.rowsOf(d, played);
        return this.timeAt(pos + rows) - this.timeAt(pos);
    }

    // The played row sounding at `time`: the last one starting at or before it.
    playedAt(time: f64): i32 {
        let lo = 0;
        let hi = this.source.length - 1;
        if (hi < 0) return -1;
        if (time < this.rowTime(0)) return 0;
        while (lo < hi) {
            let mid = (lo + hi + 1) >> 1;
            if (this.rowTime(mid) <= time) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }
}

// Seconds that a row starting at `pos` lasts, with `ramp` (if any) applied.
function rowSeconds(pos: f64, bpm: f64, rpb: i32, ramp: TempoRamp?): f64 {
    let k = 60.0 / <f64>rpb;
    if (ramp == null || pos >= ramp.end) return k / bpm;
    let r = ramp;
    // The tempo is a function of the played position, so a row lasts the
    // integral of 60 / (bpm(x) × rpb) over it.
    let a = pos;
    let b = pos + 1;
    if (r.curve == Curve.Linear && r.end >= b) {
        let b0 = r.bpmAt(a);
        let b1 = r.bpmAt(b);
        if (Math.abs(b1 - b0) < 1e-12) return k / b0;
        return k * (Math.log(b1) - Math.log(b0)) / (b1 - b0);
    }
    // Simpson's rule otherwise (exact enough at 16 steps for these curves).
    let steps = 16;
    let h = (b - a) / <f64>steps;
    let sum = 0.0;
    for (let i = 0; i <= steps; i++) {
        let x = a + <f64>i * h;
        let bx = x >= r.end ? r.to : r.bpmAt(x);
        let w = i == 0 || i == steps ? 1.0 : (i % 2 == 1 ? 4.0 : 2.0);
        sum += w * k / bx;
    }
    return sum * h / 3;
}

// The number of source rows that play: up to the last row holding a command
// in the conductor or any channel.
export function songRows(song: Song): i32 {
    let n = song.conductor.usedRowCount;
    for (let i = 0; i < song.channels.length; i++) n = max<i32>(n, song.channels[i].file.usedRowCount);
    return n;
}

function eventFor(kind: EventKind, seq: i32): ScoreEvent {
    let e = new ScoreEvent();
    e.kind = kind;
    e.seq = seq;
    return e;
}

// The tuning `tuning(…)` asks for: a built-in one, or tunings/<file>.scl.
// The root is the key that sounds as written (C by default).
export function makeTuning(c: CheckedCommand, song: Song, d: Diagnostics): Tuning? {
    let root = 60;
    if (c.has("root")) {
        let r = c.get("root");
        root = r.hasOctave ? <i32>r.num : 60 + <i32>r.num;
    }
    if (c.has("file")) {
        let name = c.str("file", "");
        let path = `tunings/${name}.scl`;
        let v = c.get("file");
        if (!song.files.has(path)) {
            d.error(c.line, v.col, v.endCol, "missing-file", `there is no ${path}`);
            return null;
        }
        let t = parseScala(song.text(path), root);
        if (t.error.length > 0) {
            d.error(c.line, v.col, v.endCol, "tuning", `${path}: ${t.error}`);
            return null;
        }
        return t;
    }
    return builtinTuning(c.str("v", "equal"), <i32>c.num("steps", 12), root);
}

// A parameter event of the master (its volume or its effects).
function masterParam(seq: i32, param: i32, value: f64, curve: i32, row: i32, played: i32): ScoreEvent {
    let e = eventFor(EventKind.Param, seq);
    e.channel = MASTER_CHANNEL;
    e.param = param;
    e.value = value;
    e.curve = curve;
    e.row = row;
    e.played = played;
    return e;
}

export function buildPlayback(song: Song, grid: Grid, options: PlaybackOptions, rowCount: i32, diagnostics: Map<string, Diagnostics>): Playback {
    let pb = new Playback();
    let config = song.config;
    let conductor = song.conductor;
    let d = diagnosticsFor(diagnostics, conductor.path);
    let bpm = config.bpm;
    let rpb = config.rowsPerBeat;
    let sigNum = config.sigNum;
    let sigDen = config.sigDen;
    let swing = config.swing;
    let keyRoot = 0; // C major until the conductor says otherwise
    let keyMode = 0;
    let tuning = 0;
    let ramp: TempoRamp? = null;
    let pending = new Array<PendingRamp>();
    let counters = new Map<i32, i32>();
    let lastVisit = new Map<i32, i32>();
    let reported = new Map<i32, bool>();
    let seq = 0;
    let masterFx = 0; // effects on the master chain so far
    let t = 0.0;
    let startRow = min<i32>(max<i32>(options.startRow, 0), rowCount);
    // Rows before the start are played once each, in source order.
    pb.firstAudible = startRow;
    let r = 0;

    let initial = eventFor(EventKind.Param, seq++);
    initial.channel = MASTER_CHANNEL;
    initial.param = ParamId.Master;
    initial.value = config.masterVolume;
    pb.events.push(initial);

    while (r < rowCount) {
        let p = pb.source.length;
        let inPrefix = p < startRow;
        if (p >= MAX_PLAYED_ROWS) {
            d.error(1, 1, 1, "limit", `the arrangement plays more than ${MAX_PLAYED_ROWS} rows; check for jumps that never end`);
            break;
        }
        let cmds: Array<CheckedCommand> = r < conductor.rowCount ? conductor.rows[r] : [];
        let jump: CheckedCommand? = null;
        let end = false;
        let pos = <f64>p;
        for (let i = 0; i < cmds.length; i++) {
            let c = cmds[i];
            let n = c.name;
            if (n == "bpm") {
                bpm = c.num("v", bpm);
                ramp = null;
            } else if (n == "sig") {
                let v = c.get("v");
                sigNum = <i32>v.num;
                sigDen = <i32>v.num2;
            } else if (n == "rpb") {
                rpb = <i32>c.num("v", <f64>rpb);
            } else if (n == "swing") {
                swing = c.num("v", swing);
            } else if (n == "master") {
                if (c.has("vol")) {
                    let e = eventFor(EventKind.Param, seq++);
                    e.channel = MASTER_CHANNEL;
                    e.param = ParamId.Master;
                    e.value = c.num("vol", 1);
                    e.row = r;
                    e.played = p;
                    pb.events.push(e);
                }
            } else if (n == "tuning") {
                let made = makeTuning(c, song, d);
                if (made != null) {
                    pb.tunings.push(made);
                    tuning = pb.tunings.length - 1;
                }
            } else if (n == "key") {
                let root = c.get("root");
                keyRoot = (((<i32>root.num) % 12) + 12) % 12;
                keyMode = max<i32>(MODES.indexOf(c.str("mode", "major")), 0);
            } else if (n == "fx") {
                // An effect on the master chain, and its starting values.
                let type = c.str("type", "");
                let e = eventFor(EventKind.Fx, seq++);
                e.channel = MASTER_CHANNEL;
                e.note = masterFx++;
                e.inst = fxTypeId(type);
                e.param = -1;
                e.curve = max<i32>(FILTER_MODES.indexOf(c.str("mode", "lowpass")), 0);
                if (c.has("sidechain")) {
                    let key = c.str("sidechain", "");
                    for (let k = 0; k < song.channels.length; k++) if (song.channels[k].name == key) e.param = k;
                    if (e.param < 0) {
                        let v = c.get("sidechain");
                        d.error(c.line, v.col, v.endCol, "unknown-track", `there is no track named '${key}' to key the compressor`);
                    }
                }
                e.row = r;
                e.played = p;
                pb.events.push(e);
                let all = fxParams();
                for (let k = 0; k < all.length; k++) {
                    let f = all[k];
                    if (f.type != type) continue;
                    let value = c.has(f.arg) ? c.num(f.arg, f.defaultValue) : f.defaultValue;
                    if (type == "filter" && f.arg == "cutoff" && !c.has("cutoff") && e.curve == 1) value = 20;
                    pb.events.push(masterParam(seq++, FX_BASE + k, value, Curve.Linear, r, p));
                }
            } else if (n == "set") {
                for (let k = 0; k < c.params.length; k++) {
                    let pa = c.params[k];
                    if (pa.name == "bpm") {
                        bpm = pa.value.num;
                        ramp = null;
                    } else if (pa.name == "master") {
                        pb.events.push(masterParam(seq++, ParamId.Master, pa.value.num, Curve.Linear, r, p));
                    } else if (pa.info != null && pa.info!.id >= FX_BASE) {
                        pb.events.push(masterParam(seq++, pa.info!.id, pa.value.num, Curve.Linear, r, p));
                    }
                }
            } else if (n == "ramp") {
                let over = c.get("over");
                let curve = curveFromName(c.str("curve", "linear"));
                for (let k = 0; k < c.params.length; k++) {
                    let pa = c.params[k];
                    if (pa.name == "bpm") {
                        let current = ramp != null ? ramp.bpmAt(pos) : bpm;
                        let rows = over.unit == DurUnit.Seconds
                            ? over.num / rowSeconds(pos, current, rpb, null)
                            : durationRows(over, rpb, sigNum, sigDen);
                        ramp = new TempoRamp(pos, rows, current, pa.value.num, curve);
                        bpm = pa.value.num;
                    } else if (pa.name == "master" || (pa.info != null && pa.info!.id >= FX_BASE)) {
                        let e = masterParam(seq++, pa.name == "master" ? ParamId.Master : pa.info!.id, pa.value.num, curve, r, p);
                        pb.events.push(e);
                        pending.push(new PendingRamp(p, e, over));
                    }
                }
            } else if (n == "jump") {
                jump = c;
            } else if (n == "end") {
                end = true;
            }
        }
        let tempo = ramp != null && pos < ramp.end ? ramp.bpmAt(pos) : bpm;
        let dur = rowSeconds(pos, bpm, rpb, ramp);
        if (ramp != null && pos + 1 >= ramp.end) ramp = null;
        let g = grid.row(r);
        pb.source.push(r);
        pb.start.push(t);
        pb.dur.push(dur);
        pb.swing.push(g.rowInBeat % 2 == 1 ? swing * dur * 0.5 : 0);
        pb.bpm.push(tempo);
        pb.rpb.push(rpb);
        pb.sigNum.push(sigNum);
        pb.sigDen.push(sigDen);
        pb.keyRoot.push(keyRoot);
        pb.tuningAt.push(tuning);
        pb.keyMode.push(keyMode);
        lastVisit.set(r, p);
        t += dur;

        if (inPrefix) {
            // Rows before the start set state only and play in source order.
            r++;
            continue;
        }
        if (end) {
            pb.ended = true;
            break;
        }
        let j = jump;
        if (j != null) {
            let to = j.str("to", "");
            if (!grid.marks.has(to)) {
                if (!reported.has(j.line)) {
                    let v = j.get("to");
                    d.error(j.line, v.col, v.endCol, "unknown-mark", `there is no mark named '${to}'`);
                    reported.set(j.line, true);
                }
            } else {
                let target = grid.marks.get(to);
                let count = counters.has(r) ? counters.get(r) : 0;
                let endless = !j.has("times");
                let times = endless ? options.loops : <i32>j.num("times", 0);
                if (count < times) {
                    counters.set(r, count + 1);
                    r = target;
                    continue;
                }
                counters.set(r, 0);
                if (endless && pb.loopStart < 0 && target <= r && lastVisit.has(target)) {
                    pb.loopStart = lastVisit.get(target);
                    pb.loopEnd = p + 1;
                }
            }
        }
        r++;
    }
    // Rows before the start play at negative times, so the start is at 0.
    if (pb.firstAudible > 0) {
        let shift = pb.firstAudible < pb.source.length ? pb.start[pb.firstAudible] : t;
        for (let i = 0; i < pb.start.length; i++) pb.start[i] -= shift;
    }
    for (let i = 0; i < pending.length; i++) {
        let pr = pending[i];
        pr.event.seconds = pb.secondsOf(pr.duration, <f64>pr.played);
    }
    for (let i = 0; i < pb.events.length; i++) {
        let e = pb.events[i];
        e.time = e.seq == 0 ? (pb.count > 0 ? pb.start[0] : 0) : pb.rowTime(e.played);
    }
    return pb;
}
