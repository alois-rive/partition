// DSP building blocks shared by the real-time processor and offline renders.
// Pure code with no host access, so every lane can run it.

export const TWO_PI: f64 = 6.283185307179586;

// A sine of a phase in turns (1 = a whole cycle), within 7.4e-7 of Math.sin
// for about a quarter of its cost (from the Rive threading docs).
@inline
export function sinTurn(turns: f64): f64 {
    let x = turns - Math.floor(turns + 0.5);
    let a = Math.abs(x);
    let m = Math.min(a, 0.5 - a);
    x = x < 0 ? -m : m;
    let x2 = x * x;
    return x * (6.28316402 + x2 * (-41.3371429 + x2 * (81.3407669 + x2 * -70.9933929)));
}

// PolyBLEP correction for a discontinuity at phase 0, with `dt` the phase step.
@inline
export function polyBlep(t: f64, dt: f64): f64 {
    if (t < dt) {
        let x = t / dt;
        return x + x - x * x - 1;
    }
    if (t > 1 - dt) {
        let x = (t - 1) / dt;
        return x * x + x + x + 1;
    }
    return 0;
}

@inline
export function wrap01(x: f64): f64 {
    return x - Math.floor(x);
}

export function midiToHz(midi: f64): f64 {
    return 440 * Math.pow(2, (midi - 69) / 12);
}

export function dbToGain(db: f64): f64 {
    return Math.pow(10, db / 20);
}

// A soft saturation curve: linear near zero, approaching ±1.
@inline
export function softClip(x: f64): f64 {
    if (x > 3) return 1;
    if (x < -3) return -1;
    let x2 = x * x;
    return x * (27 + x2) / (27 + 9 * x2);
}

// A one-pole smoothing coefficient that covers 63 % of a step in `seconds`.
export function onePole(seconds: f64, sampleRate: f64): f64 {
    if (seconds <= 0) return 1;
    return 1 - Math.exp(-1 / (seconds * sampleRate));
}

// xorshift32 noise in -1..1, deterministic from its seed.
export class Noise {
    state: u32 = 0x9E3779B9;

    seed(s: u32): void {
        this.state = s == 0 ? 0x9E3779B9 : s;
    }

    @inline
    next(): f64 {
        let x = this.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        this.state = x;
        return <f64>x / 2147483648.0 - 1;
    }

    // Uniform in 0..1.
    @inline
    unit(): f64 {
        return (this.next() + 1) * 0.5;
    }
}

// Zavalishin's topology-preserving state-variable filter, 12 dB/octave.
export class Svf {
    ic1: f64 = 0;
    ic2: f64 = 0;
    a1: f64 = 0;
    a2: f64 = 0;
    a3: f64 = 0;
    k: f64 = 2;
    mode: i32 = 0; // 0 lowpass, 1 highpass, 2 bandpass, 3 notch

    reset(): void {
        this.ic1 = 0;
        this.ic2 = 0;
    }

    // `res` 0..1 maps to Q 0.5..~20.
    set(cutoff: f64, res: f64, sampleRate: f64): void {
        let fc = Math.min(Math.max(cutoff, 10), sampleRate * 0.45);
        let g = Math.tan(Math.PI * fc / sampleRate);
        let q = 0.5 + res * res * 19.5;
        let k = 1 / q;
        this.k = k;
        this.a1 = 1 / (1 + g * (g + k));
        this.a2 = g * this.a1;
        this.a3 = g * this.a2;
    }

    @inline
    process(v0: f64): f64 {
        let v3 = v0 - this.ic2;
        let v1 = this.a1 * this.ic1 + this.a2 * v3;
        let v2 = this.ic2 + this.a2 * this.ic1 + this.a3 * v3;
        this.ic1 = 2 * v1 - this.ic1;
        this.ic2 = 2 * v2 - this.ic2;
        let m = this.mode;
        if (m == 0) return v2;
        if (m == 2) return v1;
        let hp = v0 - this.k * v1 - v2;
        if (m == 1) return hp;
        return hp + v2;
    }
}

// Flushes denormals and non-finite values, which would otherwise poison a
// filter's state for good.
@inline
export function sane(x: f64): f64 {
    if (!(x > -1e6 && x < 1e6)) return 0;
    if (x > -1e-20 && x < 1e-20) return 0;
    return x;
}
