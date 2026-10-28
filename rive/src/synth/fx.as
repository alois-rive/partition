// Send effects and the master stage (docs/spec.md §9.2). Every buffer is made
// in the constructor; `process` never allocates.

import { onePole, sane } from "./dsp";

// A stereo delay whose time follows the tempo (a dotted eighth), with a
// feedback path darkened by a one-pole low-pass.
export class Delay {
    size: i32;
    mask: i32;
    left: Float64Array;
    right: Float64Array;
    write: i32 = 0;
    delayFrames: f64 = 0;
    targetFrames: f64 = 0;
    feedback: f64 = 0.38;
    lpL: f64 = 0;
    lpR: f64 = 0;
    damp: f64;
    outL: f64 = 0;
    outR: f64 = 0;

    constructor(public sampleRate: f64) {
        let size = 1;
        while (<f64>size < sampleRate * 2.5) size <<= 1;
        this.size = size;
        this.mask = size - 1;
        this.left = new Float64Array(size);
        this.right = new Float64Array(size);
        this.damp = onePole(1 / (2 * Math.PI * 3500), sampleRate);
        this.setTempo(120);
        this.delayFrames = this.targetFrames;
    }

    setTempo(bpm: f64): void {
        let seconds = 60 / Math.max(bpm, 20) * 0.75;
        this.targetFrames = Math.min(seconds * this.sampleRate, <f64>(this.size - 4));
    }

    reset(): void {
        this.left.fill(0);
        this.right.fill(0);
        this.lpL = 0;
        this.lpR = 0;
    }

    @inline
    read(buffer: Float64Array, pos: f64): f64 {
        let i = Math.floor(pos);
        let frac = pos - i;
        let a = <i32>i & this.mask;
        let b = (a + 1) & this.mask;
        return buffer[a] + (buffer[b] - buffer[a]) * frac;
    }

    // Takes one input frame; the output is in outL/outR.
    @inline
    process(inL: f64, inR: f64): void {
        this.delayFrames += (this.targetFrames - this.delayFrames) * 0.0005;
        let pos = <f64>this.write - this.delayFrames + <f64>this.size;
        let dl = this.read(this.left, pos);
        let dr = this.read(this.right, pos);
        this.lpL += (dl - this.lpL) * this.damp;
        this.lpR += (dr - this.lpR) * this.damp;
        // Ping-pong: each side feeds the other.
        this.left[this.write] = sane(inL + this.lpR * this.feedback);
        this.right[this.write] = sane(inR + this.lpL * this.feedback);
        this.write = (this.write + 1) & this.mask;
        this.outL = dl;
        this.outR = dr;
    }

    get energy(): f64 {
        return Math.abs(this.lpL) + Math.abs(this.lpR) + Math.abs(this.outL) + Math.abs(this.outR);
    }
}

// An 8-line feedback delay network with a Hadamard mix and damped feedback.
export class Reverb {
    static readonly LINES: i32 = 8;
    lines: Array<Float64Array> = [];
    lengths: Int32Array = new Int32Array(8);
    gains: Float64Array = new Float64Array(8);
    lp: Float64Array = new Float64Array(8);
    taps: Float64Array = new Float64Array(8);
    write: i32 = 0;
    mask: i32;
    damp: f64;
    outL: f64 = 0;
    outR: f64 = 0;
    preDelay: Float64Array;
    preMask: i32;
    preWrite: i32 = 0;
    preFrames: i32;

    constructor(public sampleRate: f64, seconds: f64 = 2.6) {
        let base: StaticArray<i32> = [1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116];
        let scale = sampleRate / 48000 * 1.6;
        let size = 1;
        while (<f64>size < 1700 * scale + 4) size <<= 1;
        this.mask = size - 1;
        for (let i = 0; i < Reverb.LINES; i++) {
            this.lines.push(new Float64Array(size));
            let len = <i32>(<f64>base[i] * scale);
            this.lengths[i] = len;
            this.gains[i] = Math.pow(10, -3 * <f64>len / (seconds * sampleRate));
        }
        this.damp = onePole(1 / (2 * Math.PI * 5000), sampleRate);
        let pre = 1;
        while (<f64>pre < sampleRate * 0.03) pre <<= 1;
        this.preDelay = new Float64Array(pre);
        this.preMask = pre - 1;
        this.preFrames = <i32>(sampleRate * 0.02);
    }

    reset(): void {
        for (let i = 0; i < Reverb.LINES; i++) this.lines[i].fill(0);
        this.lp.fill(0);
        this.preDelay.fill(0);
    }

    @inline
    process(input: f64): void {
        this.preDelay[this.preWrite] = input;
        let x = this.preDelay[(this.preWrite - this.preFrames) & this.preMask];
        this.preWrite = (this.preWrite + 1) & this.preMask;
        let t = this.taps;
        for (let i = 0; i < Reverb.LINES; i++) {
            let v = this.lines[i][(this.write - this.lengths[i]) & this.mask];
            this.lp[i] += (v - this.lp[i]) * this.damp;
            t[i] = this.lp[i] * this.gains[i];
        }
        // Fast Walsh–Hadamard transform, normalised.
        for (let h = 1; h < Reverb.LINES; h <<= 1) {
            for (let i = 0; i < Reverb.LINES; i += h << 1) {
                for (let j = i; j < i + h; j++) {
                    let a = t[j];
                    let b = t[j + h];
                    t[j] = a + b;
                    t[j + h] = a - b;
                }
            }
        }
        let norm = 0.35355339059327373; // 1 / sqrt(8)
        let l = 0.0;
        let r = 0.0;
        for (let i = 0; i < Reverb.LINES; i++) {
            let fb = t[i] * norm;
            this.lines[i][this.write] = sane(fb + x);
            if ((i & 1) == 0) l += this.lp[i];
            else r += this.lp[i];
        }
        this.write = (this.write + 1) & this.mask;
        this.outL = l * 0.25;
        this.outR = r * 0.25;
    }

    get energy(): f64 {
        let e = 0.0;
        for (let i = 0; i < Reverb.LINES; i++) e += Math.abs(this.lp[i]);
        return e;
    }
}

// A peak limiter: instant attack and smooth release, with a hard clamp as the
// last guard. The ceiling is -0.3 dBFS.
export class Limiter {
    gain: f64 = 1;
    release: f64;
    ceiling: f64 = 0.9660508789898133;
    outL: f64 = 0;
    outR: f64 = 0;

    constructor(sampleRate: f64) {
        this.release = onePole(0.12, sampleRate);
    }

    @inline
    process(l: f64, r: f64): void {
        let peak = Math.max(Math.abs(l), Math.abs(r));
        let target = peak > this.ceiling ? this.ceiling / peak : 1.0;
        if (target < this.gain) this.gain = target;
        else this.gain += (target - this.gain) * this.release;
        let gl = l * this.gain;
        let gr = r * this.gain;
        this.outL = Math.min(Math.max(gl, -1.0), 1.0);
        this.outR = Math.min(Math.max(gr, -1.0), 1.0);
    }
}
