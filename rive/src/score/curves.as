// Ramp curves (docs/spec.md §5.3), shared by the compiler and the engine so
// both agree on every intermediate value.

export enum Curve {
    Linear = 0,
    Exp = 1, // geometric between positive values, as a cutoff or tempo sweep wants
    Log = 2, // fast start, slow end
    Smooth = 3, // smoothstep
}

export function curveFromName(name: string): Curve {
    if (name == "exp") return Curve.Exp;
    if (name == "log") return Curve.Log;
    if (name == "smooth") return Curve.Smooth;
    return Curve.Linear;
}

// The value `u` (0..1) of the way from `from` to `to`.
export function curveValue(from: f64, to: f64, u: f64, curve: i32): f64 {
    if (u <= 0) return from;
    if (u >= 1) return to;
    if (curve == Curve.Exp) {
        if (from > 0 && to > 0) return from * Math.pow(to / from, u);
        return from + (to - from) * u * u;
    }
    if (curve == Curve.Log) {
        let v = 1 - u;
        return from + (to - from) * (1 - v * v);
    }
    if (curve == Curve.Smooth) return from + (to - from) * u * u * (3 - 2 * u);
    return from + (to - from) * u;
}
