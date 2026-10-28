// The mixer's DSP (docs/spec.md §7.5): the effects a track, bus or the master
// runs, block by block, and the loudness meter on the output. Everything is
// allocated up front; processing allocates nothing.

import { Svf } from "./dsp";
import { FILTER_MODES } from "../lang/fx";

const CHORUS_SIZE: i32 = 4096; // ~85 ms at 48 kHz
const PHASER_STAGES: i32 = 6;

// A second-order section (RBJ cookbook), transposed direct form II.
export class Biquad {
    b0: f64 = 1;
    b1: f64 = 0;
    b2: f64 = 0;
    a1: f64 = 0;
    a2: f64 = 0;
    z1: f64 = 0;
    z2: f64 = 0;

    reset(): void {
        this.z1 = 0;
        this.z2 = 0;
    }

    coeffs(b0: f64, b1: f64, b2: f64, a0: f64, a1: f64, a2: f64): void {
        this.b0 = b0 / a0;
        this.b1 = b1 / a0;
        this.b2 = b2 / a0;
        this.a1 = a1 / a0;
        this.a2 = a2 / a0;
    }

    // `gain` is linear; shelves use a slope of 1.
    lowShelf(f: f64, gain: f64, sr: f64): void {
        let a = Math.sqrt(Math.max(gain, 1e-6));
        let w = 2 * Math.PI * Math.min(f, sr * 0.45) / sr;
        let c = Math.cos(w);
        let alpha = Math.sin(w) / 2 * Math.SQRT2;
        let sa = 2 * Math.sqrt(a) * alpha;
        this.coeffs(a * ((a + 1) - (a - 1) * c + sa), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - sa),
            (a + 1) + (a - 1) * c + sa, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - sa);
    }

    highShelf(f: f64, gain: f64, sr: f64): void {
        let a = Math.sqrt(Math.max(gain, 1e-6));
        let w = 2 * Math.PI * Math.min(f, sr * 0.45) / sr;
        let c = Math.cos(w);
        let alpha = Math.sin(w) / 2 * Math.SQRT2;
        let sa = 2 * Math.sqrt(a) * alpha;
        this.coeffs(a * ((a + 1) + (a - 1) * c + sa), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - sa),
            (a + 1) - (a - 1) * c + sa, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - sa);
    }

    peak(f: f64, gain: f64, q: f64, sr: f64): void {
        let a = Math.sqrt(Math.max(gain, 1e-6));
        let w = 2 * Math.PI * Math.min(f, sr * 0.45) / sr;
        let c = Math.cos(w);
        let alpha = Math.sin(w) / (2 * q);
        this.coeffs(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a);
    }

    highPass(f: f64, q: f64, sr: f64): void {
        let w = 2 * Math.PI * Math.min(f, sr * 0.45) / sr;
        let c = Math.cos(w);
        let alpha = Math.sin(w) / (2 * q);
        this.coeffs((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha);
    }

    @inline
    process(x: f64): f64 {
        let y = this.b0 * x + this.z1;
        this.z1 = this.b1 * x - this.a1 * y + this.z2;
        this.z2 = this.b2 * x - this.a2 * y;
        return y;
    }
}

// One strip's effect state: every effect type's, so a chain can use any of them.
export class FxState {
    // EQ: low shelf, mid peak, high shelf, per channel.
    eqL: Array<Biquad> = [new Biquad(), new Biquad(), new Biquad()];
    eqR: Array<Biquad> = [new Biquad(), new Biquad(), new Biquad()];
    eqKey: Float64Array = new Float64Array(6); // the settings the coefficients are for
    // Compressor: the detector's envelope, and the gain it applied last (for meters).
    env: f64 = 0;
    reduction: f64 = 1;
    // Distortion: the tone filter.
    toneL: f64 = 0;
    toneR: f64 = 0;
    // Chorus: a delay line per channel.
    chorusL: Float64Array = new Float64Array(CHORUS_SIZE);
    chorusR: Float64Array = new Float64Array(CHORUS_SIZE);
    chorusPos: i32 = 0;
    chorusPhase: f64 = 0;
    // Phaser: all-pass stages per channel, and their feedback.
    apL: Float64Array = new Float64Array(PHASER_STAGES);
    apR: Float64Array = new Float64Array(PHASER_STAGES);
    phaserPhase: f64 = 0;
    fbL: f64 = 0;
    fbR: f64 = 0;
    // Filter.
    svfL: Svf = new Svf();
    svfR: Svf = new Svf();

    // Clears the state of effect `type` (it just joined a chain).
    reset(type: i32): void {
        if (type == 1) {
            for (let i = 0; i < 3; i++) {
                this.eqL[i].reset();
                this.eqR[i].reset();
            }
            this.eqKey.fill(-1);
        } else if (type == 2) {
            this.env = 0;
            this.reduction = 1;
        } else if (type == 3) {
            this.toneL = 0;
            this.toneR = 0;
        } else if (type == 4) {
            this.chorusL.fill(0);
            this.chorusR.fill(0);
            this.chorusPhase = 0;
        } else if (type == 5) {
            this.apL.fill(0);
            this.apR.fill(0);
            this.fbL = 0;
            this.fbR = 0;
            this.phaserPhase = 0;
        } else if (type == 6) {
            this.svfL.reset();
            this.svfR.reset();
        }
    }

    eq(l: Float64Array, r: Float64Array, off: i32, n: i32, low: f64, mid: f64, high: f64, lowF: f64, midF: f64, highF: f64, sr: f64): void {
        let k = this.eqKey;
        if (k[0] != low || k[1] != mid || k[2] != high || k[3] != lowF || k[4] != midF || k[5] != highF) {
            k[0] = low;
            k[1] = mid;
            k[2] = high;
            k[3] = lowF;
            k[4] = midF;
            k[5] = highF;
            this.eqL[0].lowShelf(lowF, low, sr);
            this.eqL[1].peak(midF, mid, 0.9, sr);
            this.eqL[2].highShelf(highF, high, sr);
            for (let i = 0; i < 3; i++) {
                let a = this.eqL[i];
                let b = this.eqR[i];
                b.b0 = a.b0;
                b.b1 = a.b1;
                b.b2 = a.b2;
                b.a1 = a.a1;
                b.a2 = a.a2;
            }
        }
        let l0 = this.eqL[0], l1 = this.eqL[1], l2 = this.eqL[2];
        let r0 = this.eqR[0], r1 = this.eqR[1], r2 = this.eqR[2];
        for (let i = off; i < off + n; i++) {
            l[i] = l2.process(l1.process(l0.process(l[i])));
            r[i] = r2.process(r1.process(r0.process(r[i])));
        }
    }

    // A feed-forward compressor; `key` is the detector's input (its own
    // signal, or a sidechain's), as a level per frame.
    comp(l: Float64Array, r: Float64Array, off: i32, key: Float64Array, keyOff: i32, n: i32,
        threshold: f64, ratio: f64, attack: f64, release: f64, makeup: f64, mix: f64, sr: f64): void {
        let att = Math.exp(-1 / (Math.max(attack, 0.0001) * sr));
        let rel = Math.exp(-1 / (Math.max(release, 0.001) * sr));
        let thr = Math.max(threshold, 1e-6);
        let slope = 1 - 1 / Math.max(ratio, 1);
        let env = this.env;
        let g = 1.0;
        for (let i = 0; i < n; i++) {
            let x = key[keyOff + i];
            env = x > env ? att * env + (1 - att) * x : rel * env + (1 - rel) * x;
            g = 1.0;
            if (env > thr) g = Math.pow(env / thr, -slope); // the dB reduction, in gain
            let wet = g * makeup;
            let gain = mix * wet + (1 - mix);
            l[off + i] *= gain;
            r[off + i] *= gain;
        }
        this.env = env;
        this.reduction = g;
    }

    dist(l: Float64Array, r: Float64Array, off: i32, n: i32, drive: f64, tone: f64, mix: f64, sr: f64): void {
        let pre = 1 + drive * 24;
        let norm = 1 / Math.tanh(pre);
        let a = Math.exp(-2 * Math.PI * Math.min(tone, sr * 0.45) / sr);
        let tl = this.toneL;
        let tr = this.toneR;
        for (let i = off; i < off + n; i++) {
            let dl = Math.tanh(l[i] * pre) * norm;
            let dr = Math.tanh(r[i] * pre) * norm;
            tl = (1 - a) * dl + a * tl;
            tr = (1 - a) * dr + a * tr;
            l[i] = l[i] * (1 - mix) + tl * mix;
            r[i] = r[i] * (1 - mix) + tr * mix;
        }
        this.toneL = tl;
        this.toneR = tr;
    }

    chorus(l: Float64Array, r: Float64Array, off: i32, n: i32, rate: f64, depth: f64, mix: f64, sr: f64): void {
        let base = 0.012 * sr;
        let swing = depth * 0.006 * sr;
        let inc = rate / sr;
        let pos = this.chorusPos;
        let phase = this.chorusPhase;
        let bl = this.chorusL;
        let br = this.chorusR;
        for (let i = off; i < off + n; i++) {
            bl[pos] = l[i];
            br[pos] = r[i];
            // The two sides sweep a quarter turn apart.
            let dl = base + swing * Math.sin(2 * Math.PI * phase);
            let dr = base + swing * Math.sin(2 * Math.PI * (phase + 0.25));
            let wl = readDelay(bl, pos, dl);
            let wr = readDelay(br, pos, dr);
            l[i] = l[i] * (1 - mix * 0.5) + wl * mix;
            r[i] = r[i] * (1 - mix * 0.5) + wr * mix;
            pos = (pos + 1) & (CHORUS_SIZE - 1);
            phase += inc;
            if (phase >= 1) phase -= 1;
        }
        this.chorusPos = pos;
        this.chorusPhase = phase;
    }

    phaser(l: Float64Array, r: Float64Array, off: i32, n: i32, rate: f64, depth: f64, feedback: f64, mix: f64, sr: f64): void {
        let phase = this.phaserPhase;
        let inc = rate / sr;
        let fbl = this.fbL;
        let fbr = this.fbR;
        for (let i = off; i < off + n; i++) {
            // The notches sweep between 200 Hz and 200 Hz × 2^(depth·4).
            let sweep = 0.5 - 0.5 * Math.cos(2 * Math.PI * phase);
            let f = 200 * Math.pow(2, depth * 4 * sweep);
            let t = Math.tan(Math.PI * Math.min(f, sr * 0.45) / sr);
            let c = (t - 1) / (t + 1);
            let xl = l[i] + fbl * feedback;
            let xr = r[i] + fbr * feedback;
            for (let s = 0; s < PHASER_STAGES; s++) {
                let yl = c * xl + this.apL[s];
                this.apL[s] = xl - c * yl;
                xl = yl;
                let yr = c * xr + this.apR[s];
                this.apR[s] = xr - c * yr;
                xr = yr;
            }
            fbl = xl;
            fbr = xr;
            // The dry signal plus its phase-shifted copy makes the notches.
            l[i] = l[i] * (1 - mix) + (l[i] + xl) * 0.5 * mix;
            r[i] = r[i] * (1 - mix) + (r[i] + xr) * 0.5 * mix;
            phase += inc;
            if (phase >= 1) phase -= 1;
        }
        this.phaserPhase = phase;
        this.fbL = fbl;
        this.fbR = fbr;
    }

    filter(l: Float64Array, r: Float64Array, off: i32, n: i32, mode: i32, cutoff: f64, res: f64, sr: f64): void {
        this.svfL.mode = mode;
        this.svfR.mode = mode;
        this.svfL.set(cutoff, res, sr);
        this.svfR.set(cutoff, res, sr);
        for (let i = off; i < off + n; i++) {
            l[i] = this.svfL.process(l[i]);
            r[i] = this.svfR.process(r[i]);
        }
    }
}

// The delay line `d` frames back from `pos`, interpolated.
@inline
function readDelay(buf: Float64Array, pos: i32, d: f64): f64 {
    let back = <f64>pos - d;
    while (back < 0) back += <f64>CHORUS_SIZE;
    let i = <i32>back;
    let f = back - <f64>i;
    let a = buf[i & (CHORUS_SIZE - 1)];
    let b = buf[(i + 1) & (CHORUS_SIZE - 1)];
    return a + (b - a) * f;
}

export function filterModeName(mode: i32): string {
    return mode >= 0 && mode < FILTER_MODES.length ? FILTER_MODES[mode] : "lowpass";
}

// --- Loudness (ITU-R BS.1770 / EBU R128) -------------------------------------------

const SEGMENTS: i32 = 30; // 100 ms segments: 3 s of short-term history
const BINS: i32 = 800; // integrated loudness histogram: -70..+10 LUFS in 0.1 LU
const ABSOLUTE_GATE: f64 = -70;

function lufs(meanSquare: f64): f64 {
    return meanSquare > 1e-12 ? -0.691 + 10 * Math.log10(meanSquare) : -Infinity;
}

export class Loudness {
    sampleRate: f64;
    // K-weighting: a high shelf, then a high-pass, per channel.
    shelfL: Biquad = new Biquad();
    shelfR: Biquad = new Biquad();
    hpL: Biquad = new Biquad();
    hpR: Biquad = new Biquad();
    segmentFrames: i32;
    frames: i32 = 0; // into the current segment
    sum: f64 = 0; // its energy so far
    energies: Float64Array = new Float64Array(SEGMENTS); // mean square of each finished segment
    count: i32 = 0; // segments finished since the reset
    binCount: Float64Array = new Float64Array(BINS);
    binEnergy: Float64Array = new Float64Array(BINS);
    momentary: f64 = -Infinity;
    shortTerm: f64 = -Infinity;
    integrated: f64 = -Infinity;

    constructor(sampleRate: f64) {
        this.sampleRate = sampleRate;
        this.segmentFrames = max<i32>(<i32>(sampleRate * 0.1), 1);
        this.shelfL.highShelf(1681.97, Math.pow(10, 3.99984 / 20), sampleRate);
        this.shelfR.highShelf(1681.97, Math.pow(10, 3.99984 / 20), sampleRate);
        this.hpL.highPass(38.135, 0.5003, sampleRate);
        this.hpR.highPass(38.135, 0.5003, sampleRate);
    }

    reset(): void {
        this.shelfL.reset();
        this.shelfR.reset();
        this.hpL.reset();
        this.hpR.reset();
        this.frames = 0;
        this.sum = 0;
        this.energies.fill(0);
        this.count = 0;
        this.binCount.fill(0);
        this.binEnergy.fill(0);
        this.momentary = -Infinity;
        this.shortTerm = -Infinity;
        this.integrated = -Infinity;
    }

    @inline
    add(l: f64, r: f64): void {
        let kl = this.hpL.process(this.shelfL.process(l));
        let kr = this.hpR.process(this.shelfR.process(r));
        this.sum += kl * kl + kr * kr;
        this.frames++;
        if (this.frames >= this.segmentFrames) this.segment();
    }

    // A 100 ms segment is over: update momentary (400 ms), short-term (3 s)
    // and the gated integrated loudness.
    segment(): void {
        let e = this.sum / <f64>this.frames;
        this.sum = 0;
        this.frames = 0;
        this.energies[this.count % SEGMENTS] = e;
        this.count++;
        let m = 0.0;
        let mn = min<i32>(this.count, 4);
        for (let i = 0; i < mn; i++) m += this.energies[(this.count - 1 - i) % SEGMENTS];
        m /= <f64>mn;
        let s = 0.0;
        let sn = min<i32>(this.count, SEGMENTS);
        for (let i = 0; i < sn; i++) s += this.energies[(this.count - 1 - i) % SEGMENTS];
        s /= <f64>sn;
        this.momentary = lufs(m);
        this.shortTerm = lufs(s);
        if (this.count < 4) return;
        // Gating blocks are the 400 ms windows, every 100 ms.
        let l = this.momentary;
        if (l > ABSOLUTE_GATE) {
            let bin = min<i32>(max<i32>(<i32>((l - ABSOLUTE_GATE) * 10), 0), BINS - 1);
            this.binCount[bin] += 1;
            this.binEnergy[bin] += m;
        }
        // Relative gate: 10 LU under the absolute-gated mean.
        let total = 0.0;
        let n = 0.0;
        for (let i = 0; i < BINS; i++) {
            total += this.binEnergy[i];
            n += this.binCount[i];
        }
        if (n == 0) return;
        let gate = lufs(total / n) - 10;
        let from = max<i32>(<i32>Math.ceil((gate - ABSOLUTE_GATE) * 10), 0);
        let gt = 0.0;
        let gn = 0.0;
        for (let i = from; i < BINS; i++) {
            gt += this.binEnergy[i];
            gn += this.binCount[i];
        }
        this.integrated = gn > 0 ? lufs(gt / gn) : -Infinity;
    }
}
