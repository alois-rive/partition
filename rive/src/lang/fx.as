// The mixer's effects (docs/spec.md §7.5): the effect types `fx(…)` puts on a
// track, a bus or the master, and their parameters. A parameter is named
// `<type>.<arg>` in set, ramp and lfo (`comp.ratio`, `filter.cutoff`), and
// `<arg>` in fx itself. Parameter ids start at FX_BASE; a track's send to bus
// b is SEND_BASE + b, named `send.<bus>`.

import { ParamKind } from "./paramkind";

export const FX_BASE: i32 = 64;
export const SEND_BASE: i32 = 96;
export const MAX_BUSES: i32 = 4;
export const MAX_FX: i32 = 6; // effects per track, bus or master (one of each type)
// Events of bus b use channel BUS_CHANNEL + b, after the tracks (the engine's MAX_CHANNELS).
export const BUS_CHANNEL: i32 = 16;

export const FX_TYPES: Array<string> = ["eq", "comp", "dist", "chorus", "phaser", "filter"];
export const FX_EQ: i32 = 1;
export const FX_COMP: i32 = 2;
export const FX_DIST: i32 = 3;
export const FX_CHORUS: i32 = 4;
export const FX_PHASER: i32 = 5;
export const FX_FILTER: i32 = 6;
export const FILTER_MODES: Array<string> = ["lowpass", "highpass", "bandpass"];

// Parameter indices (id = FX_BASE + index), in FX_PARAMS order.
export const P_EQ_LOW: i32 = 0;
export const P_EQ_MID: i32 = 1;
export const P_EQ_HIGH: i32 = 2;
export const P_EQ_LOW_FREQ: i32 = 3;
export const P_EQ_MID_FREQ: i32 = 4;
export const P_EQ_HIGH_FREQ: i32 = 5;
export const P_COMP_THRESHOLD: i32 = 6;
export const P_COMP_RATIO: i32 = 7;
export const P_COMP_ATTACK: i32 = 8;
export const P_COMP_RELEASE: i32 = 9;
export const P_COMP_MAKEUP: i32 = 10;
export const P_COMP_MIX: i32 = 11;
export const P_DIST_DRIVE: i32 = 12;
export const P_DIST_TONE: i32 = 13;
export const P_DIST_MIX: i32 = 14;
export const P_CHORUS_RATE: i32 = 15;
export const P_CHORUS_DEPTH: i32 = 16;
export const P_CHORUS_MIX: i32 = 17;
export const P_PHASER_RATE: i32 = 18;
export const P_PHASER_DEPTH: i32 = 19;
export const P_PHASER_FEEDBACK: i32 = 20;
export const P_PHASER_MIX: i32 = 21;
export const P_FILTER_CUTOFF: i32 = 22;
export const P_FILTER_RES: i32 = 23;
export const FX_PARAM_COUNT: i32 = 24;

export class FxParam {
    constructor(
        public type: string,
        public arg: string,
        public kind: ParamKind,
        public min: f64,
        public max: f64,
        public defaultValue: f64,
    ) {}

    get name(): string {
        return `${this.type}.${this.arg}`;
    }
}

let PARAMS: Array<FxParam>? = null;

export function fxParams(): Array<FxParam> {
    let p = PARAMS;
    if (p != null) return p;
    let G = ParamKind.Gain;
    let F = ParamKind.Freq;
    let T = ParamKind.Time;
    let N = ParamKind.Number;
    let made: Array<FxParam> = [
        new FxParam("eq", "low", G, 0.0625, 16, 1),
        new FxParam("eq", "mid", G, 0.0625, 16, 1),
        new FxParam("eq", "high", G, 0.0625, 16, 1),
        new FxParam("eq", "low_freq", F, 20, 1000, 120),
        new FxParam("eq", "mid_freq", F, 100, 10000, 1000),
        new FxParam("eq", "high_freq", F, 1000, 18000, 8000),
        new FxParam("comp", "threshold", G, 0.001, 1, 0.25),
        new FxParam("comp", "ratio", N, 1, 20, 4),
        new FxParam("comp", "attack", T, 0.0001, 0.5, 0.005),
        new FxParam("comp", "release", T, 0.01, 2, 0.15),
        new FxParam("comp", "makeup", G, 0, 8, 1),
        new FxParam("comp", "mix", N, 0, 1, 1),
        new FxParam("dist", "drive", N, 0, 1, 0.4),
        new FxParam("dist", "tone", F, 200, 20000, 8000),
        new FxParam("dist", "mix", N, 0, 1, 1),
        new FxParam("chorus", "rate", F, 0.01, 20, 0.8),
        new FxParam("chorus", "depth", N, 0, 1, 0.5),
        new FxParam("chorus", "mix", N, 0, 1, 0.5),
        new FxParam("phaser", "rate", F, 0.01, 20, 0.4),
        new FxParam("phaser", "depth", N, 0, 1, 0.7),
        new FxParam("phaser", "feedback", N, 0, 0.95, 0.5),
        new FxParam("phaser", "mix", N, 0, 1, 0.5),
        new FxParam("filter", "cutoff", F, 20, 20000, 20000),
        new FxParam("filter", "res", N, 0, 1, 0.1),
    ];
    PARAMS = made;
    return made;
}

// 1-based type id (FX_EQ…), 0 for an unknown name.
export function fxTypeId(name: string): i32 {
    return FX_TYPES.indexOf(name) + 1;
}

// The index of `type`.`arg` in fxParams(), or -1.
export function fxParamIndex(type: string, arg: string): i32 {
    let all = fxParams();
    for (let i = 0; i < all.length; i++) if (all[i].type == type && all[i].arg == arg) return i;
    return -1;
}

// The argument names `fx(type: …)` takes for a type.
export function fxArgs(type: string): Array<string> {
    let out = new Array<string>();
    let all = fxParams();
    for (let i = 0; i < all.length; i++) if (all[i].type == type) out.push(all[i].arg);
    if (type == "comp") out.push("sidechain");
    if (type == "filter") out.push("mode");
    return out;
}

// Default parameter values, by index (the engine's state before any event).
export function fxDefault(index: i32): f64 {
    return fxParams()[index].defaultValue;
}

export function isFreqParam(index: i32): bool {
    return fxParams()[index].kind == ParamKind.Freq;
}
