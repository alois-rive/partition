// Wavetables (docs/spec.md §7.6): single cycles in frames that an oscillator
// sweeps through with `pos`. The built-in tables are additive, so each is
// made at a few harmonic limits (mip levels) and a note uses the richest one
// that stays under the Nyquist frequency.

export const TABLE_COUNT: i32 = 4; // basic, harmonic, formant, pwm (lang/sound.as)
export const TABLE_FRAMES: i32 = 8;
export const TABLE_SIZE: i32 = 1024;
export const MIP_COUNT: i32 = 4;
const MIP_HARMONICS: StaticArray<i32> = [128, 40, 12, 4];
const MAX_HARMONICS: i32 = 128;
// A sample used as a table holds cycles of this many frames (the common
// wavetable WAV layout).
export const SAMPLE_CYCLE: i32 = 2048;

// The harmonic amplitudes (sine and cosine) of frame `f` of table `t`.
function spectrum(t: i32, f: i32, sinAmp: Float64Array, cosAmp: Float64Array): void {
    sinAmp.fill(0);
    cosAmp.fill(0);
    let u = <f64>f / <f64>(TABLE_FRAMES - 1);
    if (t == 0) {
        // basic: sine, triangle, saw, square, morphing in turn.
        let x = u * 3;
        let seg = min<i32>(<i32>x, 2);
        let w = x - <f64>seg;
        for (let k = 1; k <= MAX_HARMONICS; k++) {
            let kf = <f64>k;
            let sine = k == 1 ? 1.0 : 0.0;
            let tri = k % 2 == 1 ? (8 / (Math.PI * Math.PI)) / (kf * kf) * ((k / 2) % 2 == 0 ? 1 : -1) : 0;
            let saw = (2 / Math.PI) / kf * (k % 2 == 1 ? 1 : -1);
            let sq = k % 2 == 1 ? (4 / Math.PI) / kf : 0;
            let a = seg == 0 ? sine : seg == 1 ? tri : saw;
            let b = seg == 0 ? tri : seg == 1 ? saw : sq;
            sinAmp[k] = a + (b - a) * w;
        }
    } else if (t == 1) {
        // harmonic: more partials at every step, each a little softer.
        let partials = <i32>Math.pow(2, 1 + u * 6);
        for (let k = 1; k <= min<i32>(partials, MAX_HARMONICS); k++) sinAmp[k] = 1 / Math.pow(<f64>k, 0.8);
    } else if (t == 2) {
        // formant: a vowel-like peak climbing the harmonics over a soft body.
        let centre = 2 + u * 14;
        for (let k = 1; k <= MAX_HARMONICS; k++) {
            let d = (<f64>k - centre) / (1.5 + u * 2);
            sinAmp[k] = Math.exp(-d * d) + 0.25 / <f64>k;
        }
    } else {
        // pwm: a pulse narrowing from square to a thin spike.
        let width = 0.5 - u * 0.45;
        for (let k = 1; k <= MAX_HARMONICS; k++) cosAmp[k] = (2 / (Math.PI * <f64>k)) * Math.sin(Math.PI * <f64>k * width);
    }
}

export class Wavetables {
    // [table][frame][mip][sample]
    data: Float32Array = new Float32Array(TABLE_COUNT * TABLE_FRAMES * MIP_COUNT * TABLE_SIZE);

    constructor() {
        let sinAmp = new Float64Array(MAX_HARMONICS + 1);
        let cosAmp = new Float64Array(MAX_HARMONICS + 1);
        let cycle = new Float64Array(TABLE_SIZE);
        for (let t = 0; t < TABLE_COUNT; t++) {
            for (let f = 0; f < TABLE_FRAMES; f++) {
                spectrum(t, f, sinAmp, cosAmp);
                for (let m = 0; m < MIP_COUNT; m++) {
                    cycle.fill(0);
                    let limit = MIP_HARMONICS[m];
                    for (let k = 1; k <= limit; k++) {
                        let s = sinAmp[k];
                        let c = cosAmp[k];
                        if (s == 0 && c == 0) continue;
                        // A rotating phasor: no sine call per sample.
                        let step = 2 * Math.PI * <f64>k / <f64>TABLE_SIZE;
                        let cr = Math.cos(step);
                        let ci = Math.sin(step);
                        let re = 1.0;
                        let im = 0.0;
                        for (let i = 0; i < TABLE_SIZE; i++) {
                            cycle[i] += s * im + c * re;
                            let nr = re * cr - im * ci;
                            im = re * ci + im * cr;
                            re = nr;
                        }
                    }
                    let peak = 0.0;
                    for (let i = 0; i < TABLE_SIZE; i++) peak = Math.max(peak, Math.abs(cycle[i]));
                    let g = peak > 0 ? 1 / peak : 0;
                    let base = this.offset(t, f, m);
                    for (let i = 0; i < TABLE_SIZE; i++) this.data[base + i] = <f32>(cycle[i] * g);
                }
            }
        }
    }

    @inline
    offset(t: i32, f: i32, m: i32): i32 {
        return ((t * TABLE_FRAMES + f) * MIP_COUNT + m) * TABLE_SIZE;
    }

    // The richest mip level whose harmonics stay under Nyquist at `inc`
    // cycles per sample.
    mipFor(inc: f64): i32 {
        let allowed = 0.5 / Math.max(inc, 1e-9);
        for (let m = 0; m < MIP_COUNT; m++) if (<f64>MIP_HARMONICS[m] <= allowed) return m;
        return MIP_COUNT - 1;
    }

    // Table `t` at `phase` (0..1): frames `fa` and `fb` mixed by `w`, at mip `m`.
    @inline
    read(t: i32, fa: i32, fb: i32, w: f64, m: i32, phase: f64): f64 {
        let x = phase * <f64>TABLE_SIZE;
        let i = <i32>x;
        let fr = x - <f64>i;
        let j = (i + 1) & (TABLE_SIZE - 1);
        i = i & (TABLE_SIZE - 1);
        let a = this.offset(t, fa, m);
        let b = this.offset(t, fb, m);
        let d = this.data;
        let va = <f64>unchecked(d[a + i]) + (<f64>unchecked(d[a + j]) - <f64>unchecked(d[a + i])) * fr;
        let vb = <f64>unchecked(d[b + i]) + (<f64>unchecked(d[b + j]) - <f64>unchecked(d[b + i])) * fr;
        return va + (vb - va) * w;
    }
}

let SHARED: Wavetables? = null;

// The built-in tables, made once per lane.
export function wavetables(): Wavetables {
    let w = SHARED;
    if (w != null) return w;
    let made = new Wavetables();
    SHARED = made;
    return made;
}
