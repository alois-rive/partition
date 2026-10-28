// Instrument definitions flattened into numbers, so they cross into the audio
// lane as one block and the engine reads them without objects.

import { InstrumentDef } from "../score/instrument";

export const MAX_INSTRUMENTS: i32 = 96;
export const MAX_OSC: i32 = 4;
export const OSC_STRIDE: i32 = 14;

// Field offsets within one instrument's record.
export const I_OSC_COUNT: i32 = 0;
export const I_OSC: i32 = 1; // MAX_OSC records of OSC_STRIDE
export const O_WAVE: i32 = 0;
export const O_LEVEL: i32 = 1;
export const O_OCT: i32 = 2;
export const O_SEMI: i32 = 3;
export const O_DETUNE: i32 = 4;
export const O_PW: i32 = 5;
export const O_UNISON: i32 = 6;
export const O_SPREAD: i32 = 7;
export const O_FM: i32 = 8;
export const O_RATIO: i32 = 9;
export const O_PHASE: i32 = 10;
export const O_TABLE: i32 = 11; // built-in wavetable id, or -1 (§7.6)
export const O_TSAMPLE: i32 = 12; // the sample a wavetable is made of, or -1
export const O_POS: i32 = 13;
export const I_AMP: i32 = I_OSC + MAX_OSC * OSC_STRIDE; // a d s r curve burst burstGap
export const I_PITCH_AMOUNT: i32 = I_AMP + 7;
export const I_PITCH_DECAY: i32 = I_PITCH_AMOUNT + 1;
export const I_FILTER_TYPE: i32 = I_PITCH_DECAY + 1;
export const I_CUTOFF: i32 = I_FILTER_TYPE + 1;
export const I_RES: i32 = I_CUTOFF + 1;
export const I_FENV_AMOUNT: i32 = I_RES + 1;
export const I_KEYTRACK: i32 = I_FENV_AMOUNT + 1;
export const I_SLOPE: i32 = I_KEYTRACK + 1;
export const I_FENV: i32 = I_SLOPE + 1; // a d s r
export const I_DRIVE: i32 = I_FENV + 4;
export const I_POLY: i32 = I_DRIVE + 1;
export const I_MONO: i32 = I_POLY + 1;
export const I_GLIDE: i32 = I_MONO + 1;
export const I_RETRIGGER: i32 = I_GLIDE + 1;
export const I_FIXED: i32 = I_RETRIGGER + 1;
export const I_ZONE_COUNT: i32 = I_FIXED + 1;
export const I_ZONE: i32 = I_ZONE_COUNT + 1; // MAX_ZONES records of ZONE_STRIDE
export const MAX_ZONE: i32 = 16;
export const Z_SAMPLE: i32 = 0;
export const Z_ROOT: i32 = 1;
export const Z_LO: i32 = 2;
export const Z_HI: i32 = 3;
export const Z_GAIN: i32 = 4;
export const Z_TUNE: i32 = 5;
export const Z_START: i32 = 6;
export const Z_END: i32 = 7;
export const Z_LOOP: i32 = 8;
export const Z_LOOP_START: i32 = 9;
export const Z_LOOP_END: i32 = 10;
export const Z_SLICES: i32 = 11;
export const Z_ONESHOT: i32 = 12;
export const Z_REVERSE: i32 = 13;
export const Z_CHOKE: i32 = 14;
export const ZONE_STRIDE: i32 = 15;
// Sound design (§7.6): width, the mod matrix, env2, the voice LFOs.
export const I_WIDTH: i32 = I_ZONE + MAX_ZONE * ZONE_STRIDE;
export const I_MOD_COUNT: i32 = I_WIDTH + 1;
export const I_MOD: i32 = I_MOD_COUNT + 1; // MAX_MOD records of MOD_STRIDE: src, dst, amt, via
export const MAX_MOD: i32 = 8;
export const MOD_STRIDE: i32 = 4;
export const I_MENV: i32 = I_MOD + MAX_MOD * MOD_STRIDE; // a d s r
export const I_VLFO: i32 = I_MENV + 4; // 2 × rate shape delay
export const INST_STRIDE: i32 = I_VLFO + 6;

export const WAVE_SINE: i32 = 0;
export const WAVE_TRI: i32 = 1;
export const WAVE_SAW: i32 = 2;
export const WAVE_SQUARE: i32 = 3;
export const WAVE_PULSE: i32 = 4;
export const WAVE_NOISE: i32 = 5;
export const WAVE_TABLE: i32 = 6;

export const FILTER_OFF: i32 = -1;

export function waveId(name: string): i32 {
    if (name == "tri") return WAVE_TRI;
    if (name == "saw") return WAVE_SAW;
    if (name == "square") return WAVE_SQUARE;
    if (name == "pulse") return WAVE_PULSE;
    if (name == "noise") return WAVE_NOISE;
    if (name == "table") return WAVE_TABLE;
    return WAVE_SINE;
}

export function filterId(name: string): i32 {
    if (name == "lowpass") return 0;
    if (name == "highpass") return 1;
    if (name == "bandpass") return 2;
    if (name == "notch") return 3;
    return FILTER_OFF;
}

export function packInstruments(defs: Array<InstrumentDef>): Float64Array {
    let n = min<i32>(defs.length, MAX_INSTRUMENTS);
    let out = new Float64Array(n * INST_STRIDE);
    for (let i = 0; i < n; i++) {
        let d = defs[i];
        let b = i * INST_STRIDE;
        let count = min<i32>(d.oscs.length, MAX_OSC);
        out[b + I_OSC_COUNT] = <f64>count;
        for (let o = 0; o < count; o++) {
            let osc = d.oscs[o];
            let ob = b + I_OSC + o * OSC_STRIDE;
            out[ob + O_WAVE] = <f64>waveId(osc.wave);
            out[ob + O_LEVEL] = osc.level;
            out[ob + O_OCT] = osc.oct;
            out[ob + O_SEMI] = osc.semi;
            out[ob + O_DETUNE] = osc.detune;
            out[ob + O_PW] = osc.wave == "pulse" && osc.pw == 0.5 ? 0.25 : osc.pw;
            out[ob + O_UNISON] = <f64>osc.unison;
            out[ob + O_SPREAD] = osc.spread;
            out[ob + O_FM] = osc.fm;
            out[ob + O_RATIO] = osc.ratio;
            out[ob + O_PHASE] = osc.phase;
            out[ob + O_TABLE] = osc.wave == "table" ? <f64>osc.tableId : -1;
            out[ob + O_TSAMPLE] = <f64>osc.tableSample;
            out[ob + O_POS] = osc.pos;
        }
        let a = d.amp;
        out[b + I_AMP] = a.a;
        out[b + I_AMP + 1] = a.d;
        out[b + I_AMP + 2] = a.s;
        out[b + I_AMP + 3] = a.r;
        out[b + I_AMP + 4] = a.curve;
        out[b + I_AMP + 5] = <f64>a.burst;
        out[b + I_AMP + 6] = a.burstGap;
        out[b + I_PITCH_AMOUNT] = d.pitchAmount;
        out[b + I_PITCH_DECAY] = d.pitchDecay;
        out[b + I_FILTER_TYPE] = <f64>filterId(d.filterType);
        out[b + I_CUTOFF] = d.cutoff;
        out[b + I_RES] = d.res;
        out[b + I_FENV_AMOUNT] = d.filterEnvAmount;
        out[b + I_KEYTRACK] = d.keytrack;
        out[b + I_SLOPE] = <f64>d.slope;
        let f = d.filterEnv;
        out[b + I_FENV] = f.a;
        out[b + I_FENV + 1] = f.d;
        out[b + I_FENV + 2] = f.s;
        out[b + I_FENV + 3] = f.r;
        out[b + I_DRIVE] = d.drive;
        out[b + I_POLY] = <f64>d.poly;
        out[b + I_MONO] = d.mono ? 1 : 0;
        out[b + I_GLIDE] = d.glide;
        out[b + I_RETRIGGER] = d.retrigger ? 1 : 0;
        out[b + I_FIXED] = d.fixedPitch;
        out[b + I_WIDTH] = d.width;
        let mods = min<i32>(d.mods.length, MAX_MOD);
        out[b + I_MOD_COUNT] = <f64>mods;
        for (let m = 0; m < mods; m++) {
            let mb = b + I_MOD + m * MOD_STRIDE;
            out[mb] = <f64>d.mods[m].src;
            out[mb + 1] = <f64>d.mods[m].dst;
            out[mb + 2] = d.mods[m].amt;
            out[mb + 3] = <f64>d.mods[m].via;
        }
        out[b + I_MENV] = d.modEnv.a;
        out[b + I_MENV + 1] = d.modEnv.d;
        out[b + I_MENV + 2] = d.modEnv.s;
        out[b + I_MENV + 3] = d.modEnv.r;
        for (let l = 0; l < 2; l++) {
            out[b + I_VLFO + l * 3] = d.lfos[l].rate;
            out[b + I_VLFO + l * 3 + 1] = <f64>d.lfos[l].shape;
            out[b + I_VLFO + l * 3 + 2] = d.lfos[l].delay;
        }
        let zones = min<i32>(d.zones.length, MAX_ZONE);
        out[b + I_ZONE_COUNT] = <f64>zones;
        for (let z = 0; z < zones; z++) {
            let zone = d.zones[z];
            let zb = b + I_ZONE + z * ZONE_STRIDE;
            out[zb + Z_SAMPLE] = <f64>zone.sampleIndex;
            out[zb + Z_ROOT] = zone.root;
            out[zb + Z_LO] = zone.lo;
            out[zb + Z_HI] = zone.hi;
            out[zb + Z_GAIN] = zone.gain;
            out[zb + Z_TUNE] = zone.tune;
            out[zb + Z_START] = zone.start;
            out[zb + Z_END] = zone.end;
            out[zb + Z_LOOP] = zone.loop ? 1 : 0;
            out[zb + Z_LOOP_START] = zone.loopStart;
            out[zb + Z_LOOP_END] = zone.loopEnd;
            out[zb + Z_SLICES] = <f64>zone.slices;
            out[zb + Z_ONESHOT] = zone.oneshot ? 1 : 0;
            out[zb + Z_REVERSE] = zone.reverse ? 1 : 0;
            out[zb + Z_CHOKE] = <f64>zone.choke;
        }
    }
    return out;
}
