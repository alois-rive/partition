// Parameters that `set`, `ramp` and `lfo` address (docs/spec.md §7.2).

export enum ParamKind {
    Number,
    Gain,
    Freq,
    Time, // seconds
    Interval, // semitones
}

export enum ParamScope {
    Channel, // the channel strip: vol, pan, sends
    Instrument, // the channel's current instrument
    Conductor, // song-wide: bpm, master
}

export enum ParamId {
    Vol = 0,
    Pan,
    Delay,
    Reverb,
    Cutoff,
    Res,
    Env,
    Keytrack,
    Drive,
    Glide,
    Attack,
    Decay,
    Sustain,
    Release,
    Pw,
    Detune,
    Bpm,
    Master,
    // oscN.level, oscN.detune, oscN.pw, oscN.fm for N = 1..4 follow, 4 per oscillator
    Osc = 32,
    Count = 48,
}

export const OSC_FIELDS: Array<string> = ["level", "detune", "pw", "fm"];
export const MAX_OSCS: i32 = 4;

export class ParamInfo {
    constructor(
        public id: i32,
        public name: string,
        public kind: ParamKind,
        public scope: ParamScope,
        public min: f64,
        public max: f64,
        public defaultValue: f64, // NaN: taken from the instrument
    ) {}
}

class ParamTable {
    list: Array<ParamInfo> = [];
    byName: Map<string, ParamInfo> = new Map<string, ParamInfo>();
    byId: Map<i32, ParamInfo> = new Map<i32, ParamInfo>();

    add(id: i32, name: string, kind: ParamKind, scope: ParamScope, lo: f64, hi: f64, def: f64): void {
        let info = new ParamInfo(id, name, kind, scope, lo, hi, def);
        this.list.push(info);
        this.byName.set(name, info);
        this.byId.set(id, info);
    }
}

let TABLE: ParamTable? = null;

function table(): ParamTable {
    let t = TABLE;
    if (t != null) return t;
    let made = new ParamTable();
    let C = ParamScope.Channel;
    let I = ParamScope.Instrument;
    made.add(ParamId.Vol, "vol", ParamKind.Gain, C, 0, 4, 0.8);
    made.add(ParamId.Pan, "pan", ParamKind.Number, C, -1, 1, 0);
    made.add(ParamId.Delay, "delay", ParamKind.Gain, C, 0, 1, 0);
    made.add(ParamId.Reverb, "reverb", ParamKind.Gain, C, 0, 1, 0);
    made.add(ParamId.Cutoff, "cutoff", ParamKind.Freq, I, 10, 22000, NaN);
    made.add(ParamId.Res, "res", ParamKind.Number, I, 0, 1, NaN);
    made.add(ParamId.Env, "env", ParamKind.Number, I, -1, 1, NaN);
    made.add(ParamId.Keytrack, "keytrack", ParamKind.Number, I, 0, 1, NaN);
    made.add(ParamId.Drive, "drive", ParamKind.Number, I, 0, 1, NaN);
    made.add(ParamId.Glide, "glide", ParamKind.Time, I, 0, 10, NaN);
    made.add(ParamId.Attack, "attack", ParamKind.Time, I, 0, 30, NaN);
    made.add(ParamId.Decay, "decay", ParamKind.Time, I, 0, 30, NaN);
    made.add(ParamId.Sustain, "sustain", ParamKind.Gain, I, 0, 1, NaN);
    made.add(ParamId.Release, "release", ParamKind.Time, I, 0, 30, NaN);
    made.add(ParamId.Pw, "pw", ParamKind.Number, I, 0.01, 0.99, NaN);
    made.add(ParamId.Detune, "detune", ParamKind.Interval, I, -24, 24, NaN);
    made.add(ParamId.Bpm, "bpm", ParamKind.Number, ParamScope.Conductor, 20, 999, 120);
    made.add(ParamId.Master, "master", ParamKind.Gain, ParamScope.Conductor, 0, 4, 1);
    for (let o = 0; o < MAX_OSCS; o++) {
        let base = ParamId.Osc + o * OSC_FIELDS.length;
        let prefix = `osc${o + 1}.`;
        made.add(base, prefix + "level", ParamKind.Gain, I, 0, 4, NaN);
        made.add(base + 1, prefix + "detune", ParamKind.Interval, I, -24, 24, NaN);
        made.add(base + 2, prefix + "pw", ParamKind.Number, I, 0.01, 0.99, NaN);
        made.add(base + 3, prefix + "fm", ParamKind.Number, I, 0, 20, NaN);
    }
    TABLE = made;
    return made;
}

export function paramByName(name: string): ParamInfo? {
    let t = table();
    if (!t.byName.has(name)) return null;
    return t.byName.get(name);
}

export function paramById(id: i32): ParamInfo? {
    let t = table();
    if (!t.byId.has(id)) return null;
    return t.byId.get(id);
}

// Names valid in a channel's `set`/`ramp`/`lfo` (channel strip and instrument).
export function channelParamNames(): Array<string> {
    let out = new Array<string>();
    let list = table().list;
    for (let i = 0; i < list.length; i++) {
        if (list[i].scope != ParamScope.Conductor) out.push(list[i].name);
    }
    return out;
}

export function conductorParamNames(): Array<string> {
    return ["bpm", "master"];
}
