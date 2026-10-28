// The synth engine (docs/spec.md §9.2): plays a compiled score sample by
// sample. Pure code with no host access, shared by the real-time processor
// and offline renders, so both produce the same samples.
//
// Output never depends on the host's block size. The engine renders fixed
// blocks of BLOCK frames aligned to the start of the song, splits them only at
// event frames, and hands out whatever each call asks for from that buffer.
// Everything is made in the constructor; `render` never allocates.

import { ParamId, OSC_FIELDS } from "../lang/params";
import { curveValue } from "../score/curves";
import { EventKind, FIELDS } from "../score/events";
import { Blob, SharedRegion } from "rive/shared";
import { HEADER_BYTES, H_EVENTS, H_INSTRUMENT_FLOATS, loadF64 } from "../audio/scoreregion";
import { midiToHz, Noise, polyBlep, sane, sinTurn, softClip, Svf, TWO_PI, wrap01 } from "./dsp";
import { Delay, Limiter, Reverb } from "./fx";
import {
    FILTER_OFF, I_AMP, I_CUTOFF, I_DRIVE, I_FENV, I_FENV_AMOUNT, I_FILTER_TYPE, I_FIXED, I_GLIDE,
    I_KEYTRACK, I_MONO, I_OSC, I_OSC_COUNT, I_PITCH_AMOUNT, I_PITCH_DECAY, I_POLY, I_RES,
    I_RETRIGGER, I_SLOPE, INST_STRIDE, MAX_INSTRUMENTS, MAX_OSC, O_DETUNE, O_FM, O_LEVEL, O_OCT,
    O_PHASE, O_PW, O_RATIO, O_SEMI, O_SPREAD, O_UNISON, O_WAVE, OSC_STRIDE, WAVE_NOISE, WAVE_PULSE,
    WAVE_SAW, WAVE_SINE, WAVE_SQUARE, WAVE_TRI, I_ZONE, I_ZONE_COUNT, ZONE_STRIDE, Z_CHOKE, Z_END, Z_GAIN,
    Z_HI, Z_LO, Z_LOOP, Z_LOOP_END, Z_LOOP_START, Z_ONESHOT, Z_REVERSE, Z_ROOT, Z_SAMPLE, Z_SLICES, Z_START, Z_TUNE,
} from "./insttable";
import { BANK_HEADER, BANK_RECORD, B_FRAMES, B_OFFSET, B_RATE, MAX_SAMPLES } from "./samples";
import { FxState, Loudness } from "./mixer";
import { ParamKind } from "../lang/paramkind";
import {
    FX_BASE, FX_CHORUS, FX_COMP, FX_DIST, FX_EQ, FX_FILTER, FX_PARAM_COUNT, FX_PHASER, fxParams, MAX_BUSES, MAX_FX,
    P_CHORUS_DEPTH, P_CHORUS_MIX, P_CHORUS_RATE, P_COMP_ATTACK, P_COMP_MAKEUP, P_COMP_MIX, P_COMP_RATIO, P_COMP_RELEASE,
    P_COMP_THRESHOLD, P_DIST_DRIVE, P_DIST_MIX, P_DIST_TONE, P_EQ_HIGH, P_EQ_HIGH_FREQ, P_EQ_LOW, P_EQ_LOW_FREQ, P_EQ_MID,
    P_EQ_MID_FREQ, P_FILTER_CUTOFF, P_FILTER_RES, P_PHASER_DEPTH, P_PHASER_FEEDBACK, P_PHASER_MIX, P_PHASER_RATE, SEND_BASE,
} from "../lang/fx";

// Frames a sample fades over where it stops without a loop, so it never clicks.
const SAMPLE_FADE: f64 = 64;
// The fastest a sample is read: 16 frames of the file per output frame.
const MAX_SAMPLE_STEP: f64 = 16;

export const BLOCK: i32 = 32;
export const MAX_VOICES: i32 = 64;
export const MAX_CHANNELS: i32 = 16;
export const MAX_SLOTS: i32 = 256;
export const SLOT_INSTS: i32 = 4; // instruments whose parameters one owner overrides
export const SLOT_LFOS: i32 = 4;
export const MAX_UNISON: i32 = 7;
export const STRIP_PARAMS: i32 = 4; // vol, pan, delay, reverb
export const EVENT_WINDOW: i32 = 256;
export const MAX_CHASE: i32 = 64; // held notes a seek restarts
// Mixer strips (§7.5): the tracks, then the buses (channel MAX_CHANNELS + b), then the master.
export const STRIP_MASTER: i32 = 16 + 4; // MAX_CHANNELS + MAX_BUSES
export const STRIPS: i32 = STRIP_MASTER + 1;

// A parameter's value over time: a target and the ramp towards it.
class Param {
    set: bool = false;
    value: f64 = 0;
    from: f64 = NaN;
    start: f64 = 0;
    seconds: f64 = 0;
    curve: i32 = 0;

    @inline
    at(t: f64): f64 {
        if (this.seconds <= 0 || t >= this.start + this.seconds || isNaN(this.from)) return this.value;
        return curveValue(this.from, this.value, (t - this.start) / this.seconds, this.curve);
    }

    assign(t: f64, value: f64, from: f64, seconds: f64, curve: i32): void {
        // A ramp without a known start begins where the parameter is now.
        let start = isNaN(from) && seconds > 0 && this.set ? this.at(t) : from;
        this.set = true;
        this.value = value;
        this.from = start;
        this.start = t;
        this.seconds = seconds;
        this.curve = curve;
    }

    copy(o: Param): void {
        this.set = o.set;
        this.value = o.value;
        this.from = o.from;
        this.start = o.start;
        this.seconds = o.seconds;
        this.curve = o.curve;
    }
}

class Lfo {
    active: bool = false;
    inst: i32 = -1;
    param: i32 = 0;
    id: i32 = 0;
    rate: f64 = 1;
    depth: f64 = 0;
    shape: i32 = 0;
    start: f64 = 0;

    // -1..1 at song time `t`.
    value(t: f64): f64 {
        let x = (t - this.start) * this.rate;
        let ph = wrap01(x);
        let s = this.shape;
        if (s == 1) return 1 - 4 * Math.abs(ph - 0.5);
        if (s == 2) return 2 * ph - 1;
        if (s == 3) return ph < 0.5 ? 1 : -1;
        if (s == 4) {
            // Sample and hold, the same value for a whole cycle.
            let cycle = <u32>(<i64>Math.floor(x) & 0x7fffffff);
            let h = cycle * 2654435761 + <u32>this.id;
            h ^= h >> 15;
            h *= 2246822519;
            h ^= h >> 13;
            return <f64>(h & 0xffff) / 32767.5 - 1;
        }
        return sinTurn(ph);
    }

    copy(o: Lfo): void {
        this.active = o.active;
        this.inst = o.inst;
        this.param = o.param;
        this.id = o.id;
        this.rate = o.rate;
        this.depth = o.depth;
        this.shape = o.shape;
        this.start = o.start;
    }
}

class InstParams {
    inst: i32 = -1;
    params: Array<Param> = [];

    constructor() {
        for (let i = 0; i < ParamId.Count; i++) this.params.push(new Param());
    }

    copy(o: InstParams): void {
        this.inst = o.inst;
        for (let i = 0; i < ParamId.Count; i++) this.params[i].copy(o.params[i]);
    }

    clear(): void {
        this.inst = -1;
        for (let i = 0; i < ParamId.Count; i++) this.params[i].set = false;
    }
}

// The parameters of one owner (a channel's own rows, or one pattern repetition).
class Slot {
    used: bool = false;
    mapped: bool = false;
    channel: i32 = 0;
    owner: i32 = 0;
    refs: i32 = 0; // voices playing through it
    touched: f64 = 0;
    strip: Array<Param> = [];
    insts: Array<InstParams> = [];
    lfos: Array<Lfo> = [];

    constructor() {
        for (let i = 0; i < STRIP_PARAMS; i++) this.strip.push(new Param());
        for (let i = 0; i < SLOT_INSTS; i++) this.insts.push(new InstParams());
        for (let i = 0; i < SLOT_LFOS; i++) this.lfos.push(new Lfo());
    }

    reset(channel: i32, owner: i32): void {
        this.used = true;
        this.mapped = true;
        this.channel = channel;
        this.owner = owner;
        for (let i = 0; i < STRIP_PARAMS; i++) this.strip[i].set = false;
        for (let i = 0; i < SLOT_INSTS; i++) this.insts[i].clear();
        for (let i = 0; i < SLOT_LFOS; i++) this.lfos[i].active = false;
    }

    copyParams(o: Slot): void {
        for (let i = 0; i < STRIP_PARAMS; i++) this.strip[i].copy(o.strip[i]);
        for (let i = 0; i < SLOT_INSTS; i++) this.insts[i].copy(o.insts[i]);
        for (let i = 0; i < SLOT_LFOS; i++) this.lfos[i].copy(o.lfos[i]);
    }

    // The override set for `inst`, made on demand (the oldest one is reused).
    instParams(inst: i32, create: bool): InstParams? {
        for (let i = 0; i < SLOT_INSTS; i++) if (this.insts[i].inst == inst) return this.insts[i];
        if (!create) return null;
        for (let i = 0; i < SLOT_INSTS; i++) {
            if (this.insts[i].inst < 0) {
                this.insts[i].inst = inst;
                return this.insts[i];
            }
        }
        let p = this.insts[SLOT_INSTS - 1];
        p.clear();
        p.inst = inst;
        return p;
    }
}

class Env {
    stage: i32 = 0; // 0 idle, 1 attack, 2 decay, 3 sustain, 4 release
    level: f64 = 0;
    attackStep: f64 = 1;
    decayCoef: f64 = 0;
    releaseCoef: f64 = 0;
    sustain: f64 = 1;
    bursts: i32 = 0; // extra hits left
    burstFrames: i32 = 0;
    burstCounter: i32 = 0;
    burstCoef: f64 = 0;

    configure(a: f64, d: f64, s: f64, r: f64, sr: f64): void {
        this.attackStep = a > 0 ? 1 / (a * sr) : 1;
        // Exponential segments that fall by 60 dB over their time.
        this.decayCoef = d > 0 ? Math.exp(-6.907755 / (d * sr)) : 0;
        this.releaseCoef = r > 0 ? Math.exp(-6.907755 / (r * sr)) : 0;
        this.sustain = s;
    }

    trigger(bursts: i32, gapFrames: i32, sr: f64): void {
        this.stage = 1;
        this.bursts = max<i32>(bursts - 1, 0);
        this.burstFrames = max<i32>(gapFrames, 1);
        this.burstCounter = 0;
        this.burstCoef = Math.exp(-6.907755 / (<f64>this.burstFrames * 0.7));
    }

    release(): void {
        if (this.stage != 0) this.stage = 4;
    }

    @inline
    next(): f64 {
        let st = this.stage;
        if (st == 1) {
            this.level += this.attackStep;
            if (this.level >= 1) {
                this.level = 1;
                this.stage = 2;
            }
        } else if (st == 2) {
            if (this.bursts > 0) {
                // A clap: each hit falls quickly, then the next one starts.
                this.level *= this.burstCoef;
                this.burstCounter++;
                if (this.burstCounter >= this.burstFrames) {
                    this.bursts--;
                    this.burstCounter = 0;
                    this.stage = 1;
                }
            } else {
                this.level = this.sustain + (this.level - this.sustain) * this.decayCoef;
                if (Math.abs(this.level - this.sustain) < 1e-5) {
                    this.level = this.sustain;
                    this.stage = this.sustain <= 1e-5 ? 0 : 3;
                }
            }
        } else if (st == 4) {
            this.level *= this.releaseCoef;
            if (this.level < 1e-5) {
                this.level = 0;
                this.stage = 0;
            }
        }
        return this.level;
    }
}

class Voice {
    active: bool = false;
    releasing: bool = false;
    channel: i32 = 0;
    slot: i32 = 0;
    note: i32 = 0;
    inst: i32 = 0;
    base: i32 = 0; // offset of the instrument in the table
    pitch: f64 = 60;
    glideFrom: f64 = 60;
    glideStart: f64 = 0;
    glideSeconds: f64 = 0;
    vel: f64 = 0.8;
    start: f64 = 0; // song time of the note-on
    end: f64 = 0; // song time the note releases at
    order: i32 = 0; // allocation order, for stealing
    phases: Float64Array = new Float64Array(MAX_OSC * MAX_UNISON);
    incs: Float64Array = new Float64Array(MAX_OSC * MAX_UNISON);
    incSteps: Float64Array = new Float64Array(MAX_OSC * MAX_UNISON);
    amp: Env = new Env();
    fenv: Env = new Env();
    svf1: Svf = new Svf();
    svf2: Svf = new Svf();
    noise: Noise = new Noise();
    gainL: f64 = 0;
    gainR: f64 = 0;
    fastRelease: bool = false;
    // Sample playback (§7.4): the zone it plays, or -1.
    zone: i32 = -1;
    choke: i32 = 0;
    sPos: f64 = 0; // read position in bank frames
    sStart: f64 = 0; // the playable range in bank frames [sStart, sEnd)
    sEnd: f64 = 0;
    sLoop: bool = false;
    sLoopStart: f64 = 0;
    sLoopEnd: f64 = 0;
    sReverse: bool = false;
    sOneshot: bool = false;
    sRate: f64 = 48000; // the file's sample rate
    sRoot: f64 = 60; // NaN for slices, which keep their pitch
    sTune: f64 = 0;
    sGain: f64 = 1;
    sDone: bool = false;

    // The pitch the voice plays at song time `t`, glide included.
    pitchAt(t: f64): f64 {
        if (this.glideSeconds <= 0) return this.pitch;
        let u = (t - this.glideStart) / this.glideSeconds;
        if (u >= 1) return this.pitch;
        if (u <= 0) return this.glideFrom;
        return this.glideFrom + (this.pitch - this.glideFrom) * u;
    }
}

// A track's, bus's or the master's effects, sends and route (§7.5).
class Strip {
    fxCount: i32 = 0;
    fxType: Int32Array = new Int32Array(MAX_FX);
    fxKey: Int32Array = new Int32Array(MAX_FX); // a compressor's sidechain track, or -1
    fxMode: Int32Array = new Int32Array(MAX_FX); // a filter's mode
    params: Array<Param> = [];
    sends: Array<Param> = [];
    state: FxState = new FxState();
    route: i32 = -1; // the bus a track plays into, or -1 for the master

    constructor() {
        for (let i = 0; i < FX_PARAM_COUNT; i++) this.params.push(new Param());
        for (let i = 0; i < MAX_BUSES; i++) this.sends.push(new Param());
        this.fxType.fill(0);
    }

    // Before a score's events set it up again: no effects, no sends, the
    // master. Effect state stays, so an unchanged chain plays on seamlessly.
    resetConfig(defaults: Float64Array): void {
        this.fxCount = 0;
        this.route = -1;
        for (let i = 0; i < FX_PARAM_COUNT; i++) this.params[i].assign(0, defaults[i], NaN, 0, 0);
        for (let i = 0; i < MAX_BUSES; i++) this.sends[i].assign(0, 0, NaN, 0, 0);
    }
}

// Reads a score's packed events through a small window, from a blob (renders)
// or a shared region (the processor), so a lane never copies the whole score.
class EventReader {
    blob: Blob? = null;
    region: SharedRegion? = null;
    regionBase: u32 = 0;
    count: i32 = 0;
    window: Float64Array = new Float64Array(EVENT_WINDOW * FIELDS);
    windowStart: i32 = 0;
    windowCount: i32 = 0;

    attach(blob: Blob?): void {
        this.blob = blob;
        this.region = null;
        this.count = blob == null ? 0 : <i32>(blob.byteLength / <u32>(FIELDS * 8));
        this.windowStart = 0;
        this.windowCount = 0;
    }

    attachRegion(region: SharedRegion, base: u32, count: i32): void {
        this.blob = null;
        this.region = region;
        this.regionBase = base;
        this.count = count;
        this.windowStart = 0;
        this.windowCount = 0;
    }

    // The window offset of event `i` (loading it if needed).
    @inline
    at(i: i32): i32 {
        if (i < this.windowStart || i >= this.windowStart + this.windowCount) {
            let n = min<i32>(EVENT_WINDOW, this.count - i);
            let region = this.region;
            if (region != null) {
                let at = this.regionBase + <u32>(i * FIELDS * 8);
                for (let k = 0; k < n * FIELDS; k++) this.window[k] = loadF64(region, at + <u32>(k * 8));
            } else {
                this.blob!.readInto(<u32>(i * FIELDS * 8), this.window, 0, n * FIELDS);
            }
            this.windowStart = i;
            this.windowCount = n;
        }
        return (i - this.windowStart) * FIELDS;
    }

    time(i: i32): f64 {
        return this.window[this.at(i)];
    }
}

export class EngineStatus {
    time: f64 = 0;
    row: f64 = 0;
    bpm: f64 = 120;
    playing: f64 = 0;
    ended: f64 = 0;
    voices: f64 = 0;
    peakL: f64 = 0;
    peakR: f64 = 0;
    lufsM: f64 = -Infinity; // loudness: momentary (400 ms), short-term (3 s), integrated
    lufsS: f64 = -Infinity;
    lufsI: f64 = -Infinity;
    channelPeaks: StaticArray<f64> = new StaticArray<f64>(MAX_CHANNELS);
}

export class Engine {
    sampleRate: f64;
    outChannels: i32;
    events: EventReader = new EventReader();
    instruments: Float64Array = new Float64Array(MAX_INSTRUMENTS * INST_STRIDE);
    instrumentCount: i32 = 0;
    voices: Array<Voice> = [];
    slots: Array<Slot> = [];
    slotMap: Int32Array = new Int32Array(MAX_SLOTS * 2); // open addressing: key → slot
    slotKeys: Float64Array = new Float64Array(MAX_SLOTS * 2);
    master: Param = new Param();
    delay: Delay;
    reverb: Reverb;
    limiter: Limiter;

    // Transport
    playing: bool = false;
    ended: bool = false;
    songFrame: f64 = 0; // frames since song time 0, at the start of the next block
    blockStartFrame: f64 = 0; // song frame of the block being handed out
    cursor: i32 = 0; // next event to fire
    loopStart: f64 = -1;
    loopEnd: f64 = -1;
    stopAt: f64 = -1; // song time to stop at (auditions), -1 for none
    row: i32 = 0;
    bpm: f64 = 120;
    nextOrder: i32 = 0;
    muteMask: i32 = 0;
    soloMask: i32 = 0;

    // Block buffers
    blockL: Float64Array = new Float64Array(BLOCK);
    blockR: Float64Array = new Float64Array(BLOCK);
    blockPos: i32 = BLOCK; // frames of the current block already handed out
    chL: Float64Array = new Float64Array(MAX_CHANNELS * BLOCK);
    chR: Float64Array = new Float64Array(MAX_CHANNELS * BLOCK);
    sendDL: Float64Array = new Float64Array(BLOCK);
    sendDR: Float64Array = new Float64Array(BLOCK);
    sendRv: Float64Array = new Float64Array(BLOCK);
    oscBuf: Float64Array = new Float64Array(BLOCK);
    rawBuf: Float64Array = new Float64Array(BLOCK);
    voiceBuf: Float64Array = new Float64Array(BLOCK);
    status: EngineStatus = new EngineStatus();
    peakDecay: f64;
    chaseBuf: Float64Array = new Float64Array(MAX_CHASE * FIELDS);
    // The mixer (§7.5).
    strips: Array<Strip> = [];
    fxDefaults: Float64Array = new Float64Array(FX_PARAM_COUNT);
    fxMin: Float64Array = new Float64Array(FX_PARAM_COUNT);
    fxMax: Float64Array = new Float64Array(FX_PARAM_COUNT);
    fxFreq: Int32Array = new Int32Array(FX_PARAM_COUNT); // LFOs move these in octaves
    busL: Float64Array = new Float64Array(MAX_BUSES * BLOCK);
    busR: Float64Array = new Float64Array(MAX_BUSES * BLOCK);
    masterL: Float64Array = new Float64Array(BLOCK);
    masterR: Float64Array = new Float64Array(BLOCK);
    keys: Float64Array = new Float64Array(MAX_CHANNELS * BLOCK); // each track's level, for sidechains
    ownKey: Float64Array = new Float64Array(BLOCK);
    loudness: Loudness;
    // The sample bank (synth/samples.as), copied into this lane once.
    bank: Float32Array = new Float32Array(0);
    bankCount: i32 = 0;
    bankOffset: Float64Array = new Float64Array(MAX_SAMPLES); // first frame, in `bank`
    bankFrames: Float64Array = new Float64Array(MAX_SAMPLES);
    bankRate: Float64Array = new Float64Array(MAX_SAMPLES);

    constructor(sampleRate: f64, outChannels: i32) {
        this.sampleRate = sampleRate;
        this.outChannels = max<i32>(outChannels, 1);
        for (let i = 0; i < MAX_VOICES; i++) this.voices.push(new Voice());
        for (let i = 0; i < MAX_SLOTS; i++) this.slots.push(new Slot());
        this.delay = new Delay(sampleRate);
        this.reverb = new Reverb(sampleRate);
        this.limiter = new Limiter(sampleRate);
        this.loudness = new Loudness(sampleRate);
        let fx = fxParams();
        for (let i = 0; i < FX_PARAM_COUNT; i++) {
            this.fxDefaults[i] = fx[i].defaultValue;
            this.fxMin[i] = fx[i].min;
            this.fxMax[i] = fx[i].max;
            this.fxFreq[i] = fx[i].kind == ParamKind.Freq ? 1 : 0;
        }
        for (let i = 0; i < STRIPS; i++) {
            let strip = new Strip();
            strip.resetConfig(this.fxDefaults);
            this.strips.push(strip);
        }
        this.peakDecay = Math.exp(-1 / (0.3 * sampleRate / <f64>BLOCK));
        this.master.assign(0, 1, NaN, 0, 0);
        this.clearSlotMap();
    }

    // --- Samples ----------------------------------------------------------

    // Takes the song's sample bank. It allocates, so it runs before playback
    // (a processor's init, a render's start), never in `render`.
    attachSamples(blob: Blob?): void {
        this.bankCount = 0;
        if (blob == null || blob.byteLength < <u32>(BANK_HEADER * 4)) return;
        let data = new Float32Array(<i32>(blob.byteLength / 4));
        blob.readInto(0, data);
        let count = min<i32>(<i32>data[0], MAX_SAMPLES);
        for (let i = 0; i < count; i++) {
            let r = 1 + i * BANK_RECORD;
            this.bankOffset[i] = <f64>BANK_HEADER + <f64>data[r + B_OFFSET];
            this.bankFrames[i] = <f64>data[r + B_FRAMES];
            this.bankRate[i] = <f64>data[r + B_RATE];
        }
        this.bank = data;
        this.bankCount = count;
    }

    // The zone of instrument `base` that plays `key`, or -1.
    zoneFor(base: i32, key: f64): i32 {
        let table = this.instruments;
        let count = <i32>table[base + I_ZONE_COUNT];
        for (let z = 0; z < count; z++) {
            let zb = base + I_ZONE + z * ZONE_STRIDE;
            let sample = <i32>table[zb + Z_SAMPLE];
            if (sample < 0 || sample >= this.bankCount || this.bankFrames[sample] < 2) continue;
            if (key >= table[zb + Z_LO] && key <= table[zb + Z_HI]) return z;
        }
        return -1;
    }

    // Points voice `v` at zone `zone` for note `key`.
    startSample(v: Voice, base: i32, zone: i32, key: f64): void {
        let table = this.instruments;
        let zb = base + I_ZONE + zone * ZONE_STRIDE;
        let sample = <i32>table[zb + Z_SAMPLE];
        let rate = this.bankRate[sample];
        let frames = this.bankFrames[sample];
        let first = this.bankOffset[sample];
        let a = Math.min(Math.max(Math.round(table[zb + Z_START] * rate), 0), frames - 1);
        let endAt = table[zb + Z_END];
        let e = endAt > 0 ? Math.min(Math.max(Math.round(endAt * rate), a + 1), frames) : frames;
        let slices = <i32>table[zb + Z_SLICES];
        let root = table[zb + Z_ROOT];
        if (slices > 0) {
            // One equal slice per note, from the root up; slices keep their pitch.
            let k = Math.min(Math.max(key - root, 0), <f64>(slices - 1));
            let len = (e - a) / <f64>slices;
            let s0 = Math.floor(a + k * len);
            e = Math.max(Math.floor(a + (k + 1) * len), s0 + 1);
            a = s0;
            root = NaN;
        }
        v.zone = zone;
        v.choke = <i32>table[zb + Z_CHOKE];
        v.sStart = first + a;
        v.sEnd = first + e;
        v.sOneshot = table[zb + Z_ONESHOT] > 0;
        v.sReverse = table[zb + Z_REVERSE] > 0;
        v.sLoop = table[zb + Z_LOOP] > 0 && slices == 0 && !v.sOneshot;
        if (v.sLoop) {
            let ls = Math.min(Math.max(Math.round(table[zb + Z_LOOP_START] * rate), a), e - 1);
            let leAt = table[zb + Z_LOOP_END];
            let le = leAt > 0 ? Math.min(Math.max(Math.round(leAt * rate), ls + 1), e) : e;
            v.sLoopStart = first + ls;
            v.sLoopEnd = first + le;
            if (le - ls < 8) v.sLoop = false;
        }
        v.sPos = v.sReverse ? v.sEnd - 1 : v.sStart;
        v.sRate = rate;
        v.sRoot = root;
        v.sTune = table[zb + Z_TUNE];
        v.sGain = table[zb + Z_GAIN];
        v.sDone = false;
    }

    // The bank frame at `i`, kept inside the voice's range.
    @inline
    frameAt(v: Voice, i: f64): f64 {
        let j = i < v.sStart ? v.sStart : i >= v.sEnd ? v.sEnd - 1 : i;
        return <f64>unchecked(this.bank[<i32>j]);
    }

    // Adds `n` frames of the voice's sample to `buf`, its pitch moving from
    // `semis0` to `semis1` semitones off the file's own.
    renderSample(v: Voice, buf: Float64Array, n: i32, semis0: f64, semis1: f64): void {
        let sr = this.sampleRate;
        let r0 = Math.min(v.sRate / sr * Math.pow(2, semis0 / 12), MAX_SAMPLE_STEP);
        let r1 = Math.min(v.sRate / sr * Math.pow(2, semis1 / 12), MAX_SAMPLE_STEP);
        let step = n > 0 ? (r1 - r0) / <f64>n : 0;
        let rate = r0;
        let dir = v.sReverse ? -1.0 : 1.0;
        let pos = v.sPos;
        let gain = v.sGain;
        let loopLen = v.sLoopEnd - v.sLoopStart;
        for (let i = 0; i < n; i++) {
            if (pos >= v.sEnd || pos < v.sStart) {
                v.sDone = true;
                break;
            }
            // 4-point Hermite interpolation.
            let ip = Math.floor(pos);
            let f = pos - ip;
            let xm1 = this.frameAt(v, ip - 1);
            let x0 = this.frameAt(v, ip);
            let x1 = this.frameAt(v, ip + 1);
            let x2 = this.frameAt(v, ip + 2);
            let c1 = 0.5 * (x1 - xm1);
            let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2;
            let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
            let y = ((c3 * f + c2) * f + c1) * f + x0;
            if (!v.sLoop) {
                let left = dir > 0 ? v.sEnd - pos : pos - v.sStart + 1;
                if (left < SAMPLE_FADE) y *= left / SAMPLE_FADE;
            }
            buf[i] += y * gain;
            pos += dir * rate;
            rate += step;
            if (v.sLoop) {
                if (dir > 0 && pos >= v.sLoopEnd) pos -= loopLen;
                else if (dir < 0 && pos < v.sLoopStart) pos += loopLen;
            }
        }
        v.sPos = pos;
    }

    // --- Mixer (§7.5) --------------------------------------------------------

    // An Fx event: effect `type` takes place `w[o+5]` of strip `s`'s chain.
    configureFx(s: i32, w: Float64Array, o: i32): void {
        if (s < 0 || s >= STRIPS) return;
        let strip = this.strips[s];
        let at = <i32>w[o + 5];
        let type = <i32>w[o + 6];
        if (at < 0 || at >= MAX_FX) return;
        if (strip.fxType[at] != type) strip.state.reset(type);
        strip.fxType[at] = type;
        strip.fxKey[at] = <i32>w[o + 7];
        strip.fxMode[at] = <i32>w[o + 14];
        strip.fxCount = max<i32>(strip.fxCount, at + 1);
    }

    // Effect parameter `i` of strip `s` at time `t`, with the LFOs of its
    // file's own rows (owner 0), within its range.
    fxValue(strip: Strip, slot: i32, i: i32, t: f64): f64 {
        let v = strip.params[i].at(t);
        if (slot >= 0) {
            let sl = this.slots[slot];
            for (let k = 0; k < SLOT_LFOS; k++) {
                let l = sl.lfos[k];
                if (!l.active || l.param != FX_BASE + i || l.inst >= 0) continue;
                let m = l.value(t) * l.depth;
                if (this.fxFreq[i] != 0) v *= Math.pow(2, m);
                else v += m;
            }
        }
        return Math.min(Math.max(v, this.fxMin[i]), this.fxMax[i]);
    }

    sendValue(strip: Strip, slot: i32, b: i32, t: f64): f64 {
        let v = strip.sends[b].at(t);
        if (slot >= 0) v = this.modulate(this.slots[slot], -1, SEND_BASE + b, v, t);
        return Math.min(Math.max(v, 0), 1);
    }

    // Runs strip `s`'s chain over BLOCK frames of `l`/`r` from `off`.
    runStrip(s: i32, l: Float64Array, r: Float64Array, off: i32, t: f64): void {
        let strip = this.strips[s];
        if (strip.fxCount == 0) return;
        let sr = this.sampleRate;
        let slot = s < STRIP_MASTER ? this.findSlot(s, 0) : -1;
        let st = strip.state;
        for (let k = 0; k < strip.fxCount; k++) {
            let type = strip.fxType[k];
            if (type == FX_EQ) {
                st.eq(l, r, off, BLOCK, this.fxValue(strip, slot, P_EQ_LOW, t), this.fxValue(strip, slot, P_EQ_MID, t), this.fxValue(strip, slot, P_EQ_HIGH, t),
                    this.fxValue(strip, slot, P_EQ_LOW_FREQ, t), this.fxValue(strip, slot, P_EQ_MID_FREQ, t), this.fxValue(strip, slot, P_EQ_HIGH_FREQ, t), sr);
            } else if (type == FX_COMP) {
                let key = strip.fxKey[k];
                let keys = this.keys;
                let keyOff = key * BLOCK;
                if (key < 0 || key >= MAX_CHANNELS) {
                    // Its own level.
                    keys = this.ownKey;
                    keyOff = 0;
                    for (let i = 0; i < BLOCK; i++) keys[i] = Math.max(Math.abs(l[off + i]), Math.abs(r[off + i]));
                }
                st.comp(l, r, off, keys, keyOff, BLOCK, this.fxValue(strip, slot, P_COMP_THRESHOLD, t), this.fxValue(strip, slot, P_COMP_RATIO, t),
                    this.fxValue(strip, slot, P_COMP_ATTACK, t), this.fxValue(strip, slot, P_COMP_RELEASE, t),
                    this.fxValue(strip, slot, P_COMP_MAKEUP, t), this.fxValue(strip, slot, P_COMP_MIX, t), sr);
            } else if (type == FX_DIST) {
                st.dist(l, r, off, BLOCK, this.fxValue(strip, slot, P_DIST_DRIVE, t), this.fxValue(strip, slot, P_DIST_TONE, t), this.fxValue(strip, slot, P_DIST_MIX, t), sr);
            } else if (type == FX_CHORUS) {
                st.chorus(l, r, off, BLOCK, this.fxValue(strip, slot, P_CHORUS_RATE, t), this.fxValue(strip, slot, P_CHORUS_DEPTH, t), this.fxValue(strip, slot, P_CHORUS_MIX, t), sr);
            } else if (type == FX_PHASER) {
                st.phaser(l, r, off, BLOCK, this.fxValue(strip, slot, P_PHASER_RATE, t), this.fxValue(strip, slot, P_PHASER_DEPTH, t),
                    this.fxValue(strip, slot, P_PHASER_FEEDBACK, t), this.fxValue(strip, slot, P_PHASER_MIX, t), sr);
            } else if (type == FX_FILTER) {
                st.filter(l, r, off, BLOCK, strip.fxMode[k], this.fxValue(strip, slot, P_FILTER_CUTOFF, t), this.fxValue(strip, slot, P_FILTER_RES, t), sr);
            }
        }
    }

    // --- Score ------------------------------------------------------------

    // Replaces the score. The new one starts at `time` with the state its
    // earlier events set; voices already sounding finish on their own.
    load(events: Blob?, instruments: Blob?, time: f64, chase: bool = true): void {
        if (instruments != null) {
            let n = min<i32>(<i32>(instruments.byteLength / 8), MAX_INSTRUMENTS * INST_STRIDE);
            instruments.readInto(0, this.instruments, 0, n);
            this.instrumentCount = n / INST_STRIDE;
        }
        this.events.attach(events);
        this.seek(time, chase);
    }

    // The same from a score in a shared region (see audio/scoreregion.as).
    loadRegion(region: SharedRegion, time: f64, chase: bool): void {
        let floats = min<i32>(<i32>region.atomicLoad(H_INSTRUMENT_FLOATS), MAX_INSTRUMENTS * INST_STRIDE);
        for (let i = 0; i < floats; i++) this.instruments[i] = loadF64(region, HEADER_BYTES + <u32>(i * 8));
        this.instrumentCount = floats / INST_STRIDE;
        let all = <i32>region.atomicLoad(H_INSTRUMENT_FLOATS);
        let count = <i32>region.atomicLoad(H_EVENTS);
        this.events.attachRegion(region, HEADER_BYTES + <u32>(all * 8), count);
        this.seek(time, chase);
    }

    // Moves to song time `t`: applies the state of every earlier event and
    // fires the rest from there. With `chase`, notes that started earlier and
    // are still held at `t` start sounding at `t` too.
    seek(t: f64, chase: bool = true): void {
        this.seekState(t, chase);
        this.songFrame = Math.round(t * this.sampleRate);
        this.blockStartFrame = this.songFrame;
        this.blockPos = BLOCK;
    }

    // The state half of `seek`: parameters, owners, the event cursor, and the
    // held notes to chase.
    seekState(t: f64, chase: bool): void {
        let chased = 0;
        this.clearSlotMap();
        for (let i = 0; i < MAX_SLOTS; i++) this.slots[i].mapped = false;
        this.master.assign(0, 1, NaN, 0, 0);
        for (let s = 0; s < STRIPS; s++) this.strips[s].resetConfig(this.fxDefaults);
        this.ended = false;
        let r = this.events;
        let i = 0;
        while (i < r.count) {
            let o = r.at(i);
            let w = r.window;
            if (w[o] >= t) break;
            let kind = <i32>w[o + 1];
            if (kind == EventKind.Fork || kind == EventKind.Param || kind == EventKind.Lfo || kind == EventKind.LfoOff || kind == EventKind.RowMark || kind == EventKind.Fx || kind == EventKind.Route) {
                this.apply(w, o);
            } else if (chase && kind == EventKind.NoteOn && w[o] + w[o + 12] > t) {
                // Held across `t`: keep it to start once the state is in place.
                if (chased < MAX_CHASE) {
                    for (let k = 0; k < FIELDS; k++) this.chaseBuf[chased * FIELDS + k] = w[o + k];
                    chased++;
                }
            } else if (chase && kind == EventKind.Cut) {
                // A cut before `t` silences what was held before it.
                let ch = w[o + 2];
                for (let c = 0; c < chased; c++) {
                    if (this.chaseBuf[c * FIELDS + 2] == ch) this.chaseBuf[c * FIELDS + 12] = 0;
                }
            }
            i++;
        }
        this.cursor = i;
        let buf = this.chaseBuf;
        for (let c = 0; c < chased; c++) {
            let o = c * FIELDS;
            let start = buf[o];
            let end = start + buf[o + 12];
            if (end <= t) continue;
            this.noteOn(t, <i32>buf[o + 2], <i32>buf[o + 3], buf, o);
            // It still ends when the score said.
            for (let v = 0; v < MAX_VOICES; v++) {
                let voice = this.voices[v];
                if (voice.active && voice.note == <i32>buf[o + 5] && voice.channel == <i32>buf[o + 2]) voice.end = end;
            }
        }
    }

    // Song time jumped back by `delta` seconds (a loop): sounding voices keep
    // what is left of their notes.
    shiftVoices(delta: f64): void {
        for (let i = 0; i < MAX_VOICES; i++) {
            let v = this.voices[i];
            if (!v.active) continue;
            v.start -= delta;
            v.end -= delta;
            v.glideStart -= delta;
        }
    }

    play(): void {
        this.playing = true;
    }

    // Stops firing events and releases every voice; effects ring out.
    stop(): void {
        this.playing = false;
        for (let i = 0; i < MAX_VOICES; i++) {
            let v = this.voices[i];
            if (v.active) this.releaseVoice(v, true);
        }
    }

    // The song time of the next frame handed out.
    get time(): f64 {
        if (this.blockPos >= BLOCK) return this.songFrame / this.sampleRate;
        return (this.blockStartFrame + <f64>this.blockPos) / this.sampleRate;
    }

    // --- Owners -----------------------------------------------------------

    clearSlotMap(): void {
        this.slotMap.fill(-1);
    }

    @inline
    hashKey(channel: i32, owner: i32): f64 {
        return <f64>channel * 1048576 + <f64>owner;
    }

    findSlot(channel: i32, owner: i32): i32 {
        let key = this.hashKey(channel, owner);
        let n = MAX_SLOTS * 2;
        let h = (<i32>((<u32>owner * 2654435761) ^ <u32>(channel * 40503)) & 0x7fffffff) % n;
        for (let k = 0; k < n; k++) {
            let j = (h + k) % n;
            let s = this.slotMap[j];
            if (s == -1) return -1;
            if (s >= 0 && this.slotKeys[j] == key) return s;
        }
        return -1;
    }

    mapSlot(channel: i32, owner: i32, slot: i32): void {
        let key = this.hashKey(channel, owner);
        let n = MAX_SLOTS * 2;
        let h = (<i32>((<u32>owner * 2654435761) ^ <u32>(channel * 40503)) & 0x7fffffff) % n;
        for (let k = 0; k < n; k++) {
            let j = (h + k) % n;
            if (this.slotMap[j] < 0 || this.slotKeys[j] == key) {
                // An empty entry or a tombstone (-2) takes the key.
                this.slotMap[j] = slot;
                this.slotKeys[j] = key;
                return;
            }
        }
    }

    // A fresh slot: an unused one, else the least recently touched one that no
    // voice plays through.
    newSlot(channel: i32, owner: i32, t: f64): i32 {
        let best = -1;
        let bestTouch = Infinity;
        for (let i = 0; i < MAX_SLOTS; i++) {
            let s = this.slots[i];
            if (!s.used) {
                best = i;
                break;
            }
            // A channel's own owner (0) holds its settings for the whole song.
            if (s.refs == 0 && !(s.mapped && s.owner == 0) && s.touched < bestTouch) {
                best = i;
                bestTouch = s.touched;
            }
        }
        if (best < 0) best = 0;
        let slot = this.slots[best];
        if (slot.mapped) {
            // Its old mapping must stop resolving to it.
            this.unmap(slot.channel, slot.owner);
        }
        slot.reset(channel, owner);
        slot.touched = t;
        this.mapSlot(channel, owner, best);
        return best;
    }

    unmap(channel: i32, owner: i32): void {
        let key = this.hashKey(channel, owner);
        let n = MAX_SLOTS * 2;
        for (let j = 0; j < n; j++) {
            if (this.slotMap[j] >= 0 && this.slotKeys[j] == key) this.slotMap[j] = -2; // tombstone
        }
    }

    slotFor(channel: i32, owner: i32, t: f64): i32 {
        let s = this.findSlot(channel, owner);
        if (s >= 0 && this.slots[s].mapped) {
            this.slots[s].touched = t;
            return s;
        }
        return this.newSlot(channel, owner, t);
    }

    // --- Events -----------------------------------------------------------

    apply(w: Float64Array, o: i32): void {
        let t = w[o];
        let kind = <i32>w[o + 1];
        let channel = <i32>w[o + 2];
        let owner = <i32>w[o + 3];
        if (kind == EventKind.RowMark) {
            this.row = <i32>w[o + 15];
            let bpm = w[o + 10];
            if (bpm > 0 && bpm != this.bpm) {
                this.bpm = bpm;
                this.delay.setTempo(bpm);
            }
            return;
        }
        if (kind == EventKind.End) {
            this.ended = true;
            this.playing = false;
            return;
        }
        if (kind == EventKind.Fx) {
            this.configureFx(channel < 0 ? STRIP_MASTER : channel, w, o);
            return;
        }
        if (kind == EventKind.Route) {
            if (channel >= 0 && channel < MAX_CHANNELS) this.strips[channel].route = <i32>w[o + 10];
            return;
        }
        if (kind == EventKind.Param && <i32>w[o + 7] >= FX_BASE) {
            // Effect parameters and sends belong to the strip, whichever owner sets them.
            let strip = channel < 0 ? STRIP_MASTER : channel;
            if (strip >= STRIPS) return;
            let param = <i32>w[o + 7];
            let p: Param? = null;
            if (param >= SEND_BASE && param < SEND_BASE + MAX_BUSES) p = this.strips[strip].sends[param - SEND_BASE];
            else if (param < FX_BASE + FX_PARAM_COUNT) p = this.strips[strip].params[param - FX_BASE];
            if (p != null) p.assign(t, w[o + 10], w[o + 11], w[o + 12], <i32>w[o + 14]);
            return;
        }
        if (channel < 0) {
            if (kind == EventKind.Param && <i32>w[o + 7] == ParamId.Master) this.master.assign(t, w[o + 10], w[o + 11], w[o + 12], <i32>w[o + 14]);
            return;
        }
        // Buses (channels from MAX_CHANNELS) take parameters and LFOs, not notes.
        if (channel >= STRIP_MASTER) return;
        if (channel >= MAX_CHANNELS && kind != EventKind.Param && kind != EventKind.Lfo && kind != EventKind.LfoOff && kind != EventKind.Fork) return;
        if (kind == EventKind.Fork) {
            let parent = this.slotFor(channel, <i32>w[o + 4], t);
            let s = this.newSlot(channel, owner, t);
            this.slots[s].copyParams(this.slots[parent]);
            return;
        }
        if (kind == EventKind.Param) {
            let slot = this.slots[this.slotFor(channel, owner, t)];
            let inst = <i32>w[o + 6];
            let param = <i32>w[o + 7];
            let p: Param? = null;
            if (inst < 0) {
                if (param >= 0 && param < STRIP_PARAMS) p = slot.strip[param];
            } else if (param >= 0 && param < ParamId.Count) {
                let ip = slot.instParams(inst, true);
                if (ip != null) p = ip.params[param];
            }
            if (p != null) p.assign(t, w[o + 10], w[o + 11], w[o + 12], <i32>w[o + 14]);
            return;
        }
        if (kind == EventKind.Lfo || kind == EventKind.LfoOff) {
            let slot = this.slots[this.slotFor(channel, owner, t)];
            let inst = <i32>w[o + 6];
            let param = <i32>w[o + 7];
            let id = <i32>w[o + 5];
            let free = -1;
            for (let i = 0; i < SLOT_LFOS; i++) {
                let l = slot.lfos[i];
                if (l.active && l.param == param && l.inst == inst && l.id == id) {
                    free = i;
                    break;
                }
                if (!l.active && free < 0) free = i;
            }
            if (kind == EventKind.LfoOff) {
                if (free >= 0 && slot.lfos[free].active && slot.lfos[free].param == param) slot.lfos[free].active = false;
                return;
            }
            if (free < 0) free = SLOT_LFOS - 1;
            let l = slot.lfos[free];
            l.active = true;
            l.inst = inst;
            l.param = param;
            l.id = id;
            l.rate = w[o + 13];
            l.depth = w[o + 10];
            l.shape = <i32>w[o + 14];
            l.start = t;
            return;
        }
        if (kind == EventKind.NoteOn) {
            this.noteOn(t, channel, owner, w, o);
            return;
        }
        if (kind == EventKind.NoteOff) {
            let note = <i32>w[o + 5];
            for (let i = 0; i < MAX_VOICES; i++) {
                let v = this.voices[i];
                // One-shot samples ignore the note's end and play to theirs.
                if (v.active && !v.releasing && v.note == note && v.channel == channel && !(v.zone >= 0 && v.sOneshot)) this.releaseVoice(v, false);
            }
            return;
        }
        if (kind == EventKind.Glide) {
            for (let i = 0; i < MAX_VOICES; i++) {
                let v = this.voices[i];
                if (v.active && v.channel == channel && !v.releasing) {
                    v.glideFrom = v.pitchAt(t);
                    v.glideStart = t;
                    v.glideSeconds = w[o + 12];
                    v.pitch = w[o + 8];
                }
            }
            return;
        }
        if (kind == EventKind.Cut) {
            let fade = w[o + 12];
            for (let i = 0; i < MAX_VOICES; i++) {
                let v = this.voices[i];
                if (v.active && v.channel == channel) {
                    v.amp.releaseCoef = fade > 0 ? Math.exp(-6.907755 / (fade * this.sampleRate)) : 0;
                    v.amp.release();
                    v.releasing = true;
                }
            }
        }
    }

    releaseVoice(v: Voice, fast: bool): void {
        v.releasing = true;
        if (fast) v.amp.releaseCoef = Math.exp(-6.907755 / (0.004 * this.sampleRate));
        v.amp.release();
        v.fenv.release();
    }

    // A voice for a new note: a free one, else the oldest releasing one, else the oldest.
    allocate(): Voice {
        let best: Voice? = null;
        for (let i = 0; i < MAX_VOICES; i++) {
            let v = this.voices[i];
            if (!v.active) return v;
        }
        for (let i = 0; i < MAX_VOICES; i++) {
            let v = this.voices[i];
            if (v.releasing && (best == null || v.order < best.order)) best = v;
        }
        if (best != null) return best;
        let oldest = this.voices[0];
        for (let i = 1; i < MAX_VOICES; i++) if (this.voices[i].order < oldest.order) oldest = this.voices[i];
        return oldest;
    }

    noteOn(t: f64, channel: i32, owner: i32, w: Float64Array, o: i32): void {
        if (channel < 0 || channel >= MAX_CHANNELS) return;
        let inst = <i32>w[o + 6];
        if (inst < 0 || inst >= this.instrumentCount) return;
        let table = this.instruments;
        let base = inst * INST_STRIDE;
        let slotIndex = this.slotFor(channel, owner, t);
        let pitch = w[o + 8];
        let fixed = table[base + I_FIXED];
        if (!isNaN(fixed)) pitch = fixed;
        let note = <i32>w[o + 5];
        let seconds = w[o + 12];
        let mono = table[base + I_MONO] > 0;
        // A sampled instrument plays the zone that covers the note, if any.
        let zone = -1;
        if (<i32>table[base + I_ZONE_COUNT] > 0) {
            zone = this.zoneFor(base, Math.round(pitch));
            if (zone < 0 && <i32>table[base + I_OSC_COUNT] == 0) return;
            if (zone >= 0) {
                let choke = <i32>table[base + I_ZONE + zone * ZONE_STRIDE + Z_CHOKE];
                if (choke > 0) {
                    for (let i = 0; i < MAX_VOICES; i++) {
                        let other = this.voices[i];
                        if (other.active && !other.releasing && other.channel == channel && other.inst == inst && other.zone >= 0 && other.choke == choke) {
                            this.releaseVoice(other, true);
                        }
                    }
                }
            }
        }

        // Mono instruments keep one voice per channel and owner, and glide.
        if (mono) {
            for (let i = 0; i < MAX_VOICES; i++) {
                let v = this.voices[i];
                if (v.active && !v.releasing && v.channel == channel && v.inst == inst && v.slot == slotIndex) {
                    let glide = this.instParam(v, ParamId.Glide, table[base + I_GLIDE], t);
                    v.glideFrom = v.pitchAt(t);
                    v.glideStart = t;
                    v.glideSeconds = glide;
                    v.pitch = pitch;
                    v.note = note;
                    v.vel = w[o + 9];
                    v.end = t + seconds;
                    if (table[base + I_RETRIGGER] > 0) {
                        v.amp.stage = 1;
                        v.fenv.stage = 1;
                        if (zone >= 0) this.startSample(v, base, zone, Math.round(pitch));
                    }
                    return;
                }
            }
        }

        // Poly limit per channel and instrument: release the oldest beyond it.
        let poly = max<i32>(<i32>table[base + I_POLY], 1);
        let count = 0;
        let oldest: Voice? = null;
        for (let i = 0; i < MAX_VOICES; i++) {
            let v = this.voices[i];
            if (v.active && !v.releasing && v.channel == channel && v.inst == inst) {
                count++;
                if (oldest == null || v.order < oldest.order) oldest = v;
            }
        }
        if (count >= poly && oldest != null) this.releaseVoice(oldest, true);

        let v = this.allocate();
        if (v.active) this.slots[v.slot].refs--;
        v.active = true;
        v.releasing = false;
        v.channel = channel;
        v.slot = slotIndex;
        this.slots[slotIndex].refs++;
        v.note = note;
        v.inst = inst;
        v.base = base;
        v.vel = w[o + 9];
        v.start = t;
        v.end = t + seconds;
        v.order = this.nextOrder++;
        v.pitch = pitch;
        let glideFrom = w[o + 11];
        let glideSeconds = w[o + 10];
        if (!isNaN(glideFrom) && glideSeconds > 0 && isNaN(fixed)) {
            v.glideFrom = glideFrom;
            v.glideStart = t;
            v.glideSeconds = glideSeconds;
        } else {
            v.glideSeconds = 0;
        }
        let sr = this.sampleRate;
        let a = this.instParam(v, ParamId.Attack, table[base + I_AMP], t);
        let d = this.instParam(v, ParamId.Decay, table[base + I_AMP + 1], t);
        let s = this.instParam(v, ParamId.Sustain, table[base + I_AMP + 2], t);
        let r = this.instParam(v, ParamId.Release, table[base + I_AMP + 3], t);
        v.amp.configure(a, d, s, r, sr);
        v.amp.level = 0;
        v.amp.trigger(<i32>table[base + I_AMP + 5], <i32>(table[base + I_AMP + 6] * sr), sr);
        v.fenv.configure(table[base + I_FENV], table[base + I_FENV + 1], table[base + I_FENV + 2], table[base + I_FENV + 3], sr);
        v.fenv.level = 0;
        v.fenv.trigger(1, 1, sr);
        v.svf1.reset();
        v.svf2.reset();
        v.noise.seed(<u32>(note * 747796405 + 2891336453));
        let oscCount = <i32>table[base + I_OSC_COUNT];
        for (let k = 0; k < oscCount; k++) {
            let ob = base + I_OSC + k * OSC_STRIDE;
            let unison = min<i32>(max<i32>(<i32>table[ob + O_UNISON], 1), MAX_UNISON);
            let phase = table[ob + O_PHASE];
            for (let u = 0; u < unison; u++) {
                v.phases[k * MAX_UNISON + u] = phase >= 0 ? phase : v.noise.unit();
            }
        }
        v.gainL = 0;
        v.gainR = 0;
        v.zone = -1;
        v.choke = 0;
        v.sOneshot = false;
        v.sDone = false;
        if (zone >= 0) this.startSample(v, base, zone, Math.round(pitch));
    }

    // --- Parameters -------------------------------------------------------

    // An instrument parameter for voice `v`: its owner's override, or the
    // instrument's own value, with LFOs applied.
    instParam(v: Voice, param: i32, fallback: f64, t: f64): f64 {
        let slot = this.slots[v.slot];
        let value = fallback;
        let ip = slot.instParams(v.inst, false);
        if (ip != null) {
            let p = ip.params[param];
            if (p.set) value = p.at(t);
        }
        return this.modulate(slot, v.inst, param, value, t);
    }

    stripParam(slot: Slot, param: i32, fallback: f64, t: f64): f64 {
        let p = slot.strip[param];
        let value = p.set ? p.at(t) : fallback;
        return this.modulate(slot, -1, param, value, t);
    }

    // LFO depth is in octaves for frequencies and in the parameter's own
    // units otherwise.
    modulate(slot: Slot, inst: i32, param: i32, value: f64, t: f64): f64 {
        for (let i = 0; i < SLOT_LFOS; i++) {
            let l = slot.lfos[i];
            if (!l.active || l.param != param || (l.inst >= 0 && inst >= 0 && l.inst != inst) || (l.inst < 0) != (inst < 0)) continue;
            let m = l.value(t) * l.depth;
            if (param == ParamId.Cutoff) value *= Math.pow(2, m);
            else value += m;
        }
        return value;
    }

    // --- Rendering --------------------------------------------------------

    // Writes `frames` interleaved frames of `outChannels` into `out` from
    // `offset` (in frames).
    render(out: StaticArray<f32>, frames: i32): void {
        this.renderInto(out, 0, frames);
    }

    renderInto(out: StaticArray<f32>, offsetFrames: i32, frames: i32): void {
        let ch = this.outChannels;
        let done = 0;
        while (done < frames) {
            if (this.blockPos >= BLOCK) this.renderBlock();
            let n = min<i32>(BLOCK - this.blockPos, frames - done);
            for (let i = 0; i < n; i++) {
                let l = <f32>this.blockL[this.blockPos + i];
                let r = <f32>this.blockR[this.blockPos + i];
                let o = (offsetFrames + done + i) * ch;
                if (ch == 1) {
                    out[o] = (l + r) * 0.5;
                } else {
                    out[o] = l;
                    out[o + 1] = r;
                    for (let c = 2; c < ch; c++) out[o + c] = 0;
                }
            }
            this.blockPos += n;
            done += n;
        }
    }

    // The same into a Float32Array (offline renders), stereo interleaved.
    renderStereo(out: Float32Array, offsetFrames: i32, frames: i32): void {
        let done = 0;
        while (done < frames) {
            if (this.blockPos >= BLOCK) this.renderBlock();
            let n = min<i32>(BLOCK - this.blockPos, frames - done);
            for (let i = 0; i < n; i++) {
                let o = (offsetFrames + done + i) * 2;
                out[o] = <f32>this.blockL[this.blockPos + i];
                out[o + 1] = <f32>this.blockR[this.blockPos + i];
            }
            this.blockPos += n;
            done += n;
        }
    }

    // True once nothing sounds: no voices and the effect tails below -90 dB.
    get silent(): bool {
        for (let i = 0; i < MAX_VOICES; i++) if (this.voices[i].active) return false;
        return this.delay.energy < 3e-5 && this.reverb.energy < 3e-5;
    }

    renderBlock(): void {
        let sr = this.sampleRate;
        let blockStart = this.songFrame;
        let wasPlaying = this.playing;
        this.chL.fill(0);
        this.chR.fill(0);
        this.sendDL.fill(0);
        this.sendDR.fill(0);
        this.sendRv.fill(0);
        let pos = 0;
        while (pos < BLOCK) {
            let frame = blockStart + <f64>pos;
            let next = BLOCK;
            if (this.playing) {
                // The loop seam comes before the events on it, so an End at the
                // loop's end never stops a loop.
                let loops = this.loopEnd > 0 && this.loopStart >= 0 && this.loopStart < this.loopEnd;
                if (loops && frame >= Math.round(this.loopEnd * sr)) {
                    // Back to the loop start; the rest of this block continues from there.
                    this.shiftVoices(this.loopEnd - this.loopStart);
                    this.seekState(this.loopStart, false);
                    blockStart = Math.round(this.loopStart * sr) - <f64>pos;
                    continue;
                }
                let r = this.events;
                while (this.cursor < r.count) {
                    let o = r.at(this.cursor);
                    let ef = Math.round(r.window[o] * sr);
                    if (ef > frame) {
                        next = <i32>Math.min(<f64>BLOCK, ef - blockStart);
                        break;
                    }
                    this.apply(r.window, o);
                    this.cursor++;
                    if (!this.playing) break;
                }
                if (loops) next = <i32>Math.min(<f64>next, Math.round(this.loopEnd * sr) - blockStart);
                if (this.stopAt >= 0) {
                    let sf = Math.round(this.stopAt * sr);
                    if (frame >= sf) {
                        this.stopAt = -1;
                        this.stop();
                    } else {
                        next = <i32>Math.min(<f64>next, sf - blockStart);
                    }
                }
            }
            if (next <= pos) next = pos + 1;
            this.renderVoices(pos, next, frame / sr);
            pos = next;
        }
        this.mixBlock();
        this.blockStartFrame = blockStart;
        // A stopped song stays where it is; one that stopped in this block
        // stays where it stopped.
        this.songFrame = wasPlaying ? blockStart + <f64>BLOCK : blockStart;
        this.blockPos = 0;
        this.publishStatus();
    }

    renderVoices(from: i32, to: i32, t: f64): void {
        let n = to - from;
        let sr = this.sampleRate;
        let table = this.instruments;
        let tEnd = t + <f64>n / sr;
        for (let vi = 0; vi < MAX_VOICES; vi++) {
            let v = this.voices[vi];
            if (!v.active) continue;
            if (!v.releasing && t >= v.end && !(v.zone >= 0 && v.sOneshot)) this.releaseVoice(v, false);
            let base = v.base;
            let slot = this.slots[v.slot];

            // Control rate: pitch, filter and gains for this segment.
            let pitch0 = v.pitchAt(t) + this.pitchEnv(v, t);
            let pitch1 = v.pitchAt(tEnd) + this.pitchEnv(v, tEnd);
            let detuneAll = this.instParam(v, ParamId.Detune, 0, t);
            let pwAll = this.instParam(v, ParamId.Pw, NaN, t);
            let oscCount = <i32>table[base + I_OSC_COUNT];
            let buf = this.voiceBuf;
            for (let i = 0; i < n; i++) buf[i] = 0;
            let prev = this.oscBuf; // the previous oscillator's raw output, for FM
            let raw = this.rawBuf;
            for (let i = 0; i < n; i++) prev[i] = 0;
            for (let k = 0; k < oscCount; k++) {
                let ob = base + I_OSC + k * OSC_STRIDE;
                let pField = ParamId.Osc + k * OSC_FIELDS.length;
                let wave = <i32>table[ob + O_WAVE];
                let level = this.instParam(v, pField, table[ob + O_LEVEL], t);
                let detune = this.instParam(v, pField + 1, table[ob + O_DETUNE], t) + detuneAll;
                let pw = this.instParam(v, pField + 2, isNaN(pwAll) ? table[ob + O_PW] : pwAll, t);
                let fm = this.instParam(v, pField + 3, table[ob + O_FM], t) / TWO_PI;
                let ratio = table[ob + O_RATIO];
                let unison = min<i32>(max<i32>(<i32>table[ob + O_UNISON], 1), MAX_UNISON);
                let spread = table[ob + O_SPREAD];
                let offset = table[ob + O_OCT] * 12 + table[ob + O_SEMI] + detune;
                let norm = 1 / Math.sqrt(<f64>unison);
                for (let i = 0; i < n; i++) raw[i] = 0;
                pw = Math.min(Math.max(pw, 0.01), 0.99);
                for (let u = 0; u < unison; u++) {
                    let spreadOffset = unison > 1 ? spread * (<f64>u / <f64>(unison - 1) * 2 - 1) : 0;
                    let f0 = midiToHz(pitch0 + offset + spreadOffset) * ratio;
                    let f1 = f0 * Math.pow(2, (pitch1 - pitch0) / 12);
                    let inc = Math.min(f0 / sr, 0.45);
                    let step = n > 0 ? (Math.min(f1 / sr, 0.45) - inc) / <f64>n : 0;
                    let pi = k * MAX_UNISON + u;
                    let phase = v.phases[pi];
                    for (let i = 0; i < n; i++) {
                        let s = 0.0;
                        if (wave == WAVE_SINE) {
                            s = sinTurn(phase + fm * prev[i]);
                        } else if (wave == WAVE_SAW) {
                            s = 2 * phase - 1 - polyBlep(phase, inc);
                        } else if (wave == WAVE_SQUARE || wave == WAVE_PULSE) {
                            let width = wave == WAVE_SQUARE ? 0.5 : pw;
                            s = (phase < width ? 1.0 : -1.0) + polyBlep(phase, inc) - polyBlep(wrap01(phase - width + 1), inc);
                        } else if (wave == WAVE_TRI) {
                            s = 1 - 4 * Math.abs(wrap01(phase + 0.25) - 0.5);
                        } else if (wave == WAVE_NOISE) {
                            s = v.noise.next();
                        }
                        raw[i] += s * norm;
                        phase += inc;
                        if (phase >= 1) phase -= 1;
                        inc += step;
                    }
                    v.phases[pi] = phase;
                }
                for (let i = 0; i < n; i++) {
                    buf[i] += raw[i] * level;
                    prev[i] = raw[i];
                }
            }
            if (v.zone >= 0 && !v.sDone) {
                // Slices (no root) keep their pitch; the rest follow the note.
                let semis0 = (isNaN(v.sRoot) ? this.pitchEnv(v, t) : pitch0 - v.sRoot) + v.sTune + detuneAll;
                let semis1 = (isNaN(v.sRoot) ? this.pitchEnv(v, tEnd) : pitch1 - v.sRoot) + v.sTune + detuneAll;
                this.renderSample(v, buf, n, semis0, semis1);
            }

            // Filter
            let ftype = <i32>table[base + I_FILTER_TYPE];
            let fenvAmount = this.instParam(v, ParamId.Env, table[base + I_FENV_AMOUNT], t);
            let cutoff = this.instParam(v, ParamId.Cutoff, table[base + I_CUTOFF], t);
            let res = Math.min(Math.max(this.instParam(v, ParamId.Res, table[base + I_RES], t), 0), 1);
            let keytrack = this.instParam(v, ParamId.Keytrack, table[base + I_KEYTRACK], t);
            let slope = <i32>table[base + I_SLOPE];
            let drive = Math.min(Math.max(this.instParam(v, ParamId.Drive, table[base + I_DRIVE], t), 0), 1);
            if (ftype != FILTER_OFF) {
                let fc = cutoff * Math.pow(2, keytrack * (pitch0 - 60) / 12 + fenvAmount * v.fenv.level * 6);
                v.svf1.mode = ftype;
                v.svf2.mode = ftype;
                v.svf1.set(fc, slope == 24 ? res * 0.6 : res, sr);
                if (slope == 24) v.svf2.set(fc, res * 0.6, sr);
            }

            // Gains: owner volume and constant-power pan, smoothed over the segment.
            let vol = Math.max(this.stripParam(slot, ParamId.Vol, 0.8, t), 0);
            let pan = Math.min(Math.max(this.stripParam(slot, ParamId.Pan, 0, t), -1), 1);
            let angle = (pan + 1) * Math.PI * 0.25;
            let targetL = vol * Math.cos(angle) * 1.4142135623730951;
            let targetR = vol * Math.sin(angle) * 1.4142135623730951;
            let dl = (targetL - v.gainL) / <f64>max<i32>(n, 1);
            let dr = (targetR - v.gainR) / <f64>max<i32>(n, 1);
            let sendD = Math.max(this.stripParam(slot, ParamId.Delay, 0, t), 0);
            let sendR = Math.max(this.stripParam(slot, ParamId.Reverb, 0, t), 0);
            let muted = this.isMuted(v.channel);
            let chOff = v.channel * BLOCK;
            let driveIn = 1 + drive * 6;
            let driveOut = drive > 0 ? 1 / (1 + drive * 1.5) : 1;
            let vel = v.vel;
            for (let i = 0; i < n; i++) {
                let x = buf[i];
                if (ftype != FILTER_OFF) {
                    x = v.svf1.process(x);
                    if (slope == 24) x = v.svf2.process(x);
                }
                if (drive > 0) x = softClip(x * driveIn) * driveOut;
                let env = v.amp.next();
                v.fenv.next();
                x = sane(x * env * vel);
                v.gainL += dl;
                v.gainR += dr;
                if (muted) continue;
                let l = x * v.gainL;
                let r = x * v.gainR;
                let j = from + i;
                this.chL[chOff + j] += l;
                this.chR[chOff + j] += r;
                this.sendDL[j] += l * sendD;
                this.sendDR[j] += r * sendD;
                this.sendRv[j] += (l + r) * 0.5 * sendR;
            }
            v.gainL = targetL;
            v.gainR = targetR;
            if (v.amp.stage == 0 || (v.zone >= 0 && v.sDone && oscCount == 0)) {
                v.active = false;
                slot.refs--;
            }
        }
    }

    pitchEnv(v: Voice, t: f64): f64 {
        let table = this.instruments;
        let amount = table[v.base + I_PITCH_AMOUNT];
        let decay = table[v.base + I_PITCH_DECAY];
        if (amount == 0 || decay <= 0) return 0;
        let age = t - v.start;
        return amount * Math.exp(-age / decay);
    }

    isMuted(channel: i32): bool {
        let bit = 1 << channel;
        if (this.soloMask != 0) return (this.soloMask & bit) == 0;
        return (this.muteMask & bit) != 0;
    }

    // Tracks' effects, buses, sends and returns, the master chain, then the
    // limiter and the meters.
    mixBlock(): void {
        let st = this.status;
        let t = this.songFrame / this.sampleRate;
        let masterGain = this.master.at(t);
        let decay = this.peakDecay;
        let chL = this.chL;
        let chR = this.chR;
        // Each track's level before its effects: what sidechains listen to.
        for (let i = 0; i < MAX_CHANNELS * BLOCK; i++) this.keys[i] = Math.max(Math.abs(chL[i]), Math.abs(chR[i]));
        for (let c = 0; c < MAX_CHANNELS; c++) this.runStrip(c, chL, chR, c * BLOCK, t);
        for (let c = 0; c < MAX_CHANNELS; c++) {
            let peak = 0.0;
            let off = c * BLOCK;
            for (let i = 0; i < BLOCK; i++) peak = Math.max(peak, Math.max(Math.abs(chL[off + i]), Math.abs(chR[off + i])));
            st.channelPeaks[c] = Math.max(peak, st.channelPeaks[c] * decay);
        }

        // Tracks into the master or their bus, and their sends to buses.
        let mL = this.masterL;
        let mR = this.masterR;
        let bL = this.busL;
        let bR = this.busR;
        mL.fill(0);
        mR.fill(0);
        bL.fill(0);
        bR.fill(0);
        for (let c = 0; c < MAX_CHANNELS; c++) {
            let strip = this.strips[c];
            let off = c * BLOCK;
            let route = strip.route;
            if (route >= 0 && route < MAX_BUSES) {
                let bo = route * BLOCK;
                for (let i = 0; i < BLOCK; i++) {
                    bL[bo + i] += chL[off + i];
                    bR[bo + i] += chR[off + i];
                }
            } else {
                for (let i = 0; i < BLOCK; i++) {
                    mL[i] += chL[off + i];
                    mR[i] += chR[off + i];
                }
            }
            // Sends: only tracks that set one (an LFO alone on a send does nothing).
            let sends = false;
            for (let b = 0; b < MAX_BUSES; b++) {
                let p = strip.sends[b];
                if (p.value > 0 || (p.seconds > 0 && p.from > 0)) sends = true;
            }
            if (!sends) continue;
            let slot = this.findSlot(c, 0);
            for (let b = 0; b < MAX_BUSES; b++) {
                let amount = this.sendValue(strip, slot, b, t);
                if (amount <= 0) continue;
                let bo = b * BLOCK;
                for (let i = 0; i < BLOCK; i++) {
                    bL[bo + i] += chL[off + i] * amount;
                    bR[bo + i] += chR[off + i] * amount;
                }
            }
        }

        // Buses: their effects, their volume and pan, their delay and reverb sends.
        for (let b = 0; b < MAX_BUSES; b++) {
            let s = MAX_CHANNELS + b;
            let bo = b * BLOCK;
            this.runStrip(s, bL, bR, bo, t);
            let slot = this.findSlot(s, 0);
            let vol = 1.0;
            let pan = 0.0;
            let sendD = 0.0;
            let sendR = 0.0;
            if (slot >= 0) {
                let sl = this.slots[slot];
                vol = Math.max(this.stripParam(sl, ParamId.Vol, 1, t), 0);
                pan = Math.min(Math.max(this.stripParam(sl, ParamId.Pan, 0, t), -1), 1);
                sendD = Math.max(this.stripParam(sl, ParamId.Delay, 0, t), 0);
                sendR = Math.max(this.stripParam(sl, ParamId.Reverb, 0, t), 0);
            }
            let angle = (pan + 1) * Math.PI * 0.25;
            let gl = vol * Math.cos(angle) * 1.4142135623730951;
            let gr = vol * Math.sin(angle) * 1.4142135623730951;
            for (let i = 0; i < BLOCK; i++) {
                let l = bL[bo + i] * gl;
                let r = bR[bo + i] * gr;
                mL[i] += l;
                mR[i] += r;
                this.sendDL[i] += l * sendD;
                this.sendDR[i] += r * sendD;
                this.sendRv[i] += (l + r) * 0.5 * sendR;
            }
        }

        // The delay and reverb returns, then the master chain.
        for (let i = 0; i < BLOCK; i++) {
            this.delay.process(this.sendDL[i], this.sendDR[i]);
            this.reverb.process(this.sendRv[i]);
            mL[i] += this.delay.outL + this.reverb.outL;
            mR[i] += this.delay.outR + this.reverb.outR;
        }
        this.runStrip(STRIP_MASTER, mL, mR, 0, t);

        let pl = 0.0;
        let pr = 0.0;
        let loud = this.loudness;
        for (let i = 0; i < BLOCK; i++) {
            this.limiter.process(mL[i] * masterGain, mR[i] * masterGain);
            let ol = this.limiter.outL;
            let or = this.limiter.outR;
            this.blockL[i] = ol;
            this.blockR[i] = or;
            pl = Math.max(pl, Math.abs(ol));
            pr = Math.max(pr, Math.abs(or));
            if (this.playing) loud.add(ol, or);
        }
        st.peakL = Math.max(pl, st.peakL * decay);
        st.peakR = Math.max(pr, st.peakR * decay);
        st.lufsM = loud.momentary;
        st.lufsS = loud.shortTerm;
        st.lufsI = loud.integrated;
    }

    publishStatus(): void {
        let st = this.status;
        st.time = this.songFrame / this.sampleRate;
        st.row = <f64>this.row;
        st.bpm = this.bpm;
        st.playing = this.playing ? 1 : 0;
        st.ended = this.ended ? 1 : 0;
        let n = 0;
        for (let i = 0; i < MAX_VOICES; i++) if (this.voices[i].active) n++;
        st.voices = <f64>n;
    }
}
