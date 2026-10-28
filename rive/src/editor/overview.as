// The overview of a collapsed column (docs/spec.md §10.6): every command as a
// mark on the channel's own time grid, so a whole song reads at a glance.
//
// The marks come from the checked source in source order, with patterns
// expanded where they are called. Notes are vertical lines placed by pitch,
// automation has shapes of its own, and each mark carries an icon kind for its
// first row. Everything here is data; the view draws it.

import { CheckedCommand, CheckedFile } from "../lang/check";
import { ParamKind, paramByName } from "../lang/params";
import { Song } from "../lang/song";
import { DurUnit, Typed } from "../lang/types";
import { chordIntervals, MODES } from "../lang/commands";
import { degreeSemitones, parseNumeral, progressionTokens } from "../lang/scales";
import { Grid, durationRows } from "../score/timeline";

export enum Mark {
    Note = 0,
    Chord,
    Pattern,
    Ramp,
    Lfo,
    Glide,
    Inst,
    Cut,
    Set,
    Stop,
    Flag, // conductor: mark
    Jump,
    End,
    Tempo, // bpm, ramp(bpm:)
    Meter, // sig, rpb, swing
    Master,
}

// Which strip of the 64 px column a mark lives in.
export enum Lane {
    Patterns = 0, // left edge
    Automation = 1,
    Notes = 2, // the pitch area
    Across = 3, // full width (cuts, conductor events)
}

export const MAX_MARKS: i32 = 6000;
export const MAX_DEPTH: i32 = 4;

export class OverviewMark {
    kind: Mark = Mark.Note;
    lane: Lane = Lane.Notes;
    row: f64 = 0; // fractional source row where it starts
    length: f64 = 0; // rows it spans (0: a tick)
    pitch: f64 = 0; // notes and glides: MIDI pitch (glide: start)
    pitchTo: f64 = 0; // glides: target
    weight: f64 = 0.8; // velocity, or how strong
    from: f64 = 0; // ramps: normalised start value (0..1)
    to: f64 = 0; // ramps: normalised end value (0..1)
    color: u32 = 0xFFD8DEE9;
    tail: f64 = 0; // rows of echo after a note (delay and reverb sends)
    fromPattern: bool = false;
    label: string = "";
    line: i32 = 0; // 1-based source line in the column's file (0 inside patterns)
}

export class Overview {
    marks: Array<OverviewMark> = [];
    minPitch: f64 = 127;
    maxPitch: f64 = 0;
    revision: i32 = -1; // the song revision it was built from

    get hasNotes(): bool {
        return this.maxPitch >= this.minPitch;
    }

    // 0..1 across the notes area.
    pitchPos(pitch: f64): f64 {
        if (this.maxPitch <= this.minPitch) return 0.5;
        return (pitch - this.minPitch) / (this.maxPitch - this.minPitch);
    }
}

// Colours that tell instruments, patterns and parameters apart.
const PALETTE: StaticArray<u32> = [
    0xFF88C0D0, 0xFFA3BE8C, 0xFFEBCB8B, 0xFFD08770, 0xFFB48EAD,
    0xFF81A1C1, 0xFF8FBCBB, 0xFFBF616A, 0xFFE5C07B, 0xFF98C379,
];

export function hashColor(name: string): u32 {
    let h: u32 = 2166136261;
    for (let i = 0; i < name.length; i++) {
        h ^= <u32>name.charCodeAt(i);
        h *= 16777619;
    }
    return PALETTE[<i32>(h % <u32>PALETTE.length)];
}

export function paramColor(name: string): u32 {
    if (name == "vol" || name == "master") return 0xFFA3BE8C;
    if (name == "pan") return 0xFFB48EAD;
    if (name == "cutoff" || name == "res" || name == "env") return 0xFFD08770;
    if (name == "delay" || name == "reverb") return 0xFF81A1C1;
    if (name == "bpm") return 0xFFE5E9F0;
    return 0xFF8FBCBB;
}

// A parameter value as 0..1 of its range (frequencies on a log scale).
export function normalise(name: string, value: f64): f64 {
    let info = paramByName(name);
    if (info == null) return Math.min(Math.max(value, 0), 1);
    let lo = info.min;
    let hi = info.max;
    if (info.kind == ParamKind.Freq) {
        let l = Math.log(Math.max(lo, 1));
        let h = Math.log(Math.max(hi, 2));
        return Math.min(Math.max((Math.log(Math.max(value, 1)) - l) / (h - l), 0), 1);
    }
    if (hi <= lo) return 0.5;
    return Math.min(Math.max((value - lo) / (hi - lo), 0), 1);
}

function defaultFor(name: string): f64 {
    let info = paramByName(name);
    if (info == null || isNaN(info.defaultValue)) return 0.5;
    return normalise(name, info.defaultValue);
}

class State {
    inst: string = "sine";
    oct: f64 = 4;
    transpose: f64 = 0;
    vel: f64 = 0.8;
    len: Typed = Typed.duration(DurUnit.Rows, 1);
    params: Map<string, f64> = new Map<string, f64>(); // normalised
    delay: f64 = 0; // send levels, for the echo tail
    reverb: f64 = 0;
    lastPitch: f64 = 60;
    keyRoot: i32 = 0; // the file's own key, for scale degrees (C major until it sets one)
    keyMode: i32 = 0;

    get sends(): f64 {
        return Math.min(this.delay + this.reverb, 1.5);
    }

    clone(): State {
        let s = new State();
        s.inst = this.inst;
        s.oct = this.oct;
        s.transpose = this.transpose;
        s.vel = this.vel;
        s.keyRoot = this.keyRoot;
        s.keyMode = this.keyMode;
        s.len = this.len;
        let keys = this.params.keys();
        for (let i = 0; i < keys.length; i++) s.params.set(keys[i], this.params.get(keys[i]));
        s.delay = this.delay;
        s.reverb = this.reverb;
        s.lastPitch = this.lastPitch;
        return s;
    }

    param(name: string): f64 {
        return this.params.has(name) ? this.params.get(name) : defaultFor(name);
    }
}

class Builder {
    overview: Overview = new Overview();
    lfos: Map<string, OverviewMark> = new Map<string, OverviewMark>();

    constructor(public song: Song, public grid: Grid, public bpmByRow: Array<f64>, public endRow: f64) {}

    full(): bool {
        return this.overview.marks.length >= MAX_MARKS;
    }

    add(kind: Mark, lane: Lane, row: f64, length: f64, color: u32, c: CheckedCommand, depth: i32): OverviewMark {
        let m = new OverviewMark();
        m.kind = kind;
        m.lane = lane;
        m.row = row;
        m.length = Math.max(length, 0);
        m.color = color;
        m.fromPattern = depth > 0;
        m.line = depth > 0 ? 0 : c.line;
        this.overview.marks.push(m);
        return m;
    }

    // Rows a duration spans from `row` (absolute times through the tempo there).
    rows(d: Typed, row: f64): f64 {
        let r = <i32>Math.max(Math.floor(row), 0);
        let g = this.grid.row(r);
        let n = durationRows(d, g.rpb, g.sigNum, g.sigDen);
        if (!isNaN(n)) return n;
        let bpm = r < this.bpmByRow.length ? this.bpmByRow[r] : (this.bpmByRow.length > 0 ? this.bpmByRow[this.bpmByRow.length - 1] : 120);
        return d.num * bpm * <f64>g.rpb / 60;
    }

    pitchOf(v: Typed, s: State): f64 {
        let midi = v.hasOctave ? v.num : (s.oct + 1) * 12 + v.num;
        return midi + s.transpose;
    }

    note(c: CheckedCommand, row: f64, s: State, pitches: Array<f64>, kind: Mark, depth: i32): void {
        let at = c.has("at") ? Math.min(this.rows(c.get("at"), row), 0.99) : 0;
        let len = this.rows(c.has("len") ? c.get("len") : s.len, row);
        let vel = c.num("vel", s.vel);
        let inst = c.has("inst") ? c.str("inst", s.inst) : s.inst;
        let color = hashColor(inst);
        let strum = c.has("strum") ? this.rows(c.get("strum"), row) : 0;
        for (let i = 0; i < pitches.length; i++) {
            let m = this.add(kind, Lane.Notes, row + at + strum * <f64>i, len, color, c, depth);
            m.pitch = pitches[i];
            m.weight = vel;
            m.tail = s.sends * 6;
            m.label = inst;
            let ov = this.overview;
            if (pitches[i] < ov.minPitch) ov.minPitch = pitches[i];
            if (pitches[i] > ov.maxPitch) ov.maxPitch = pitches[i];
        }
        if (pitches.length > 0) s.lastPitch = pitches[pitches.length - 1];
    }

    degree(d: i32, s: State): f64 {
        return <f64>((<i32>s.oct + 1) * 12 + s.keyRoot + degreeSemitones(s.keyMode, d)) + s.transpose;
    }

    command(c: CheckedCommand, row: f64, s: State, depth: i32): void {
        if (this.full()) return;
        // Commands that wait for a pattern's variables have no values to draw.
        if (c.deferred.length > 0) return;
        let n = c.name;
        if (n == "note") {
            let pitches = new Array<f64>();
            if (c.has("d")) {
                let d = c.get("d");
                if (d.items.length == 0) pitches.push(this.degree(<i32>d.num, s));
                for (let i = 0; i < d.items.length; i++) pitches.push(this.degree(<i32>d.items[i].num, s));
            } else {
                let items = c.get("p").items;
                for (let i = 0; i < items.length; i++) pitches.push(this.pitchOf(items[i], s));
            }
            this.note(c, row, s, pitches, pitches.length > 1 ? Mark.Chord : Mark.Note, depth);
        } else if (n == "key") {
            s.keyRoot = (((<i32>c.get("root").num) % 12) + 12) % 12;
            s.keyMode = max<i32>(MODES.indexOf(c.str("mode", "major")), 0);
        } else if (n == "prog") {
            let tokens = progressionTokens(c.str("chords", ""));
            let step = c.has("every") ? this.rows(c.get("every"), row) : this.rows(Typed.duration(DurUnit.Bars, 1), row);
            for (let i = 0; i < tokens.length; i++) {
                let num = parseNumeral(tokens[i], s.keyMode);
                if (num.hold || num.rest || num.error.length > 0) continue;
                let iv = chordIntervals(num.type);
                let pitches = new Array<f64>();
                for (let k = 0; k < iv.length; k++) pitches.push(<f64>((<i32>s.oct + 1) * 12 + s.keyRoot + num.root + iv[k]) + s.transpose);
                this.note(c, row + <f64>i * step, s, pitches, Mark.Chord, depth);
            }
        } else if (n == "chord") {
            let pitches = new Array<f64>();
            if (c.has("d") && !c.has("type")) {
                let d = <i32>c.num("d", 1);
                let size = <i32>c.num("size", 3);
                for (let k = 0; k < size; k++) pitches.push(this.degree(d + 2 * k, s));
            } else {
                let root = c.has("d") ? this.degree(<i32>c.num("d", 1), s) : this.pitchOf(c.get("root"), s);
                let iv = chordIntervals(c.str("type", "maj"));
                for (let i = 0; i < iv.length; i++) pitches.push(root + <f64>iv[i]);
            }
            let inv = <i32>c.num("inv", 0);
            for (let k = 0; k < inv; k++) pitches.push(pitches.shift() + 12);
            let spread = c.num("spread", 0);
            for (let k = 1; k < pitches.length; k += 2) pitches[k] += 12 * spread;
            this.note(c, row, s, pitches, Mark.Chord, depth);
        } else if (n == "inst") {
            s.inst = c.str("name", s.inst);
            let m = this.add(Mark.Inst, Lane.Automation, row, 0, hashColor(s.inst), c, depth);
            m.label = s.inst;
        } else if (n == "oct") {
            s.oct = c.num("v", s.oct);
        } else if (n == "transpose") {
            s.transpose = c.num("v", 0);
        } else if (n == "vel") {
            s.vel = c.num("v", s.vel);
        } else if (n == "len") {
            s.len = c.get("v");
        } else if (n == "vol" || n == "pan") {
            let v = normalise(n, c.num("v", 0));
            s.params.set(n, v);
            let m = this.add(Mark.Set, Lane.Automation, row, 0, paramColor(n), c, depth);
            m.from = v;
            m.to = v;
            m.label = n;
        } else if (n == "set" || n == "ramp") {
            let over = n == "ramp" ? this.rows(c.get("over"), row) : 0;
            for (let i = 0; i < c.params.length; i++) {
                let pa = c.params[i];
                let to = normalise(pa.name, pa.value.num);
                let from = s.param(pa.name);
                s.params.set(pa.name, to);
                if (pa.name == "delay") s.delay = pa.value.num;
                if (pa.name == "reverb") s.reverb = pa.value.num;
                let m = this.add(n == "ramp" ? Mark.Ramp : Mark.Set, Lane.Automation, row, over, paramColor(pa.name), c, depth);
                m.from = n == "ramp" ? from : to;
                m.to = to;
                m.label = pa.name;
            }
        } else if (n == "lfo" || n == "lfo_off") {
            let param = c.str("param", "");
            let key = param + "/" + c.str("id", "");
            if (this.lfos.has(key)) {
                let open = this.lfos.get(key);
                open.length = Math.max(row - open.row, 0);
                this.lfos.delete(key);
            }
            if (n == "lfo") {
                let m = this.add(Mark.Lfo, Lane.Automation, row, this.endRow - row, paramColor(param), c, depth);
                m.weight = Math.min(Math.abs(c.num("depth", 0.5)), 1);
                let rate = c.get("rate");
                // Cycles per row, so the wave can be drawn at its real speed.
                m.from = rate.unit == DurUnit.Hz ? rate.num * 60 / (120 * 4) : 1 / Math.max(this.rows(rate, row), 0.25);
                m.label = param;
                this.lfos.set(key, m);
            }
        } else if (n == "glide") {
            let to = this.pitchOf(c.get("to"), s);
            let m = this.add(Mark.Glide, Lane.Notes, row, this.rows(c.get("over"), row), 0xFFE5E9F0, c, depth);
            m.pitch = s.lastPitch;
            m.pitchTo = to;
            s.lastPitch = to;
        } else if (n == "cut") {
            this.add(Mark.Cut, Lane.Across, row, 0, 0xFFBF616A, c, depth);
        } else if (n == "stop") {
            this.add(Mark.Stop, Lane.Patterns, row, 0, 0xFFBF616A, c, depth);
        } else if (n == "pattern") {
            this.pattern(c, row, s, depth);
        } else if (n == "mark") {
            let m = this.add(Mark.Flag, Lane.Across, row, 0, 0xFFEBCB8B, c, depth);
            m.label = c.str("name", "");
        } else if (n == "jump") {
            let m = this.add(Mark.Jump, Lane.Across, row, 0, 0xFF88C0D0, c, depth);
            let to = c.str("to", "");
            m.label = to;
            m.from = this.grid.marks.has(to) ? <f64>this.grid.marks.get(to) : row;
        } else if (n == "end") {
            this.add(Mark.End, Lane.Across, row, 0, 0xFFBF616A, c, depth);
        } else if (n == "bpm") {
            let m = this.add(Mark.Tempo, Lane.Automation, row, 0, paramColor("bpm"), c, depth);
            let v = normalise("bpm", c.num("v", 120));
            m.from = v;
            m.to = v;
            s.params.set("bpm", v);
        } else if (n == "sig" || n == "rpb" || n == "swing") {
            let m = this.add(Mark.Meter, Lane.Automation, row, 0, 0xFFB48EAD, c, depth);
            m.label = n;
        } else if (n == "master") {
            let m = this.add(Mark.Master, Lane.Automation, row, 0, paramColor("master"), c, depth);
            let v = normalise("master", c.num("vol", 1));
            m.from = v;
            m.to = v;
            s.params.set("master", v);
        }
    }

    pattern(c: CheckedCommand, row: f64, s: State, depth: i32): void {
        let name = c.str("name", "");
        if (!this.song.patterns.has(name) || depth >= MAX_DEPTH) return;
        let file = this.song.patterns.get(name);
        let len = file.rowCount;
        if (len == 0) return;
        let times = <i32>c.num("times", 1);
        let m = this.add(Mark.Pattern, Lane.Patterns, row, <f64>(len * times), hashColor("pattern:" + name), c, depth);
        m.label = name;
        m.weight = <f64>times;
        for (let rep = 0; rep < times && !this.full(); rep++) {
            let state = s.clone();
            for (let k = 0; k < len; k++) {
                let cmds = file.rows[k];
                for (let i = 0; i < cmds.length; i++) this.command(cmds[i], row + <f64>(rep * len + k), state, depth + 1);
            }
        }
    }
}

// The overview of one column's file. `bpmByRow` gives the tempo of each
// source row (for durations in seconds).
export function buildOverview(file: CheckedFile, song: Song, grid: Grid, bpmByRow: Array<f64>): Overview {
    let endRow = <f64>max<i32>(file.rowCount, grid.rows.length);
    let b = new Builder(song, grid, bpmByRow, endRow);
    let s = new State();
    for (let r = 0; r < file.rows.length; r++) {
        let cmds = file.rows[r];
        for (let i = 0; i < cmds.length; i++) b.command(cmds[i], <f64>r, s, 0);
    }
    return b.overview;
}
