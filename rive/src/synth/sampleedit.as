// Edits of a sample's frames (docs/spec.md §10.11): each takes mono frames
// and a range [a, b) (the whole sample when b <= a) and returns new frames.

export const EDIT_GAIN_DB: f64 = 3;

export function editFrames(data: Float32Array, op: string, a: i32, b: i32): Float32Array {
    let n = data.length;
    if (b <= a) {
        a = 0;
        b = n;
    }
    a = min<i32>(max<i32>(a, 0), n);
    b = min<i32>(max<i32>(b, a), n);
    if (op == "trim") return data.slice(a, b);
    if (op == "cut") {
        let out = new Float32Array(n - (b - a));
        for (let i = 0; i < a; i++) out[i] = data[i];
        for (let i = b; i < n; i++) out[i - (b - a)] = data[i];
        return out;
    }
    let out = data.slice(0);
    let len = b - a;
    if (op == "reverse") {
        for (let i = 0; i < len; i++) out[a + i] = data[b - 1 - i];
    } else if (op == "normalize") {
        let peak = 0.0;
        for (let i = a; i < b; i++) peak = Math.max(peak, Math.abs(<f64>data[i]));
        if (peak > 1e-6) {
            let g = 0.98 / peak;
            for (let i = a; i < b; i++) out[i] = <f32>(<f64>data[i] * g);
        }
    } else if (op == "fadein" || op == "fadeout") {
        for (let i = 0; i < len; i++) {
            let u = len > 1 ? <f64>i / <f64>(len - 1) : 1;
            let g = op == "fadein" ? u : 1 - u;
            out[a + i] = <f32>(<f64>data[a + i] * g);
        }
    } else if (op == "gain-" || op == "gain+") {
        let g = Math.pow(10, (op == "gain+" ? EDIT_GAIN_DB : -EDIT_GAIN_DB) / 20);
        for (let i = a; i < b; i++) out[i] = <f32>Math.min(Math.max(<f64>data[i] * g, -1), 1);
    }
    return out;
}
