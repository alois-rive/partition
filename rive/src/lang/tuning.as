// Tunings (docs/spec.md §7.6): how written pitches map to sounding ones.
// A tuning is a scale of steps within a period (an octave, unless a Scala
// file says otherwise), laid on the keyboard from a root note: each key is
// the next step. Twelve-step tunings retune the keys; others are microtonal.

export class Tuning {
    root: i32 = 60; // the key that sounds as written
    cents: Array<f64> = [0]; // each step above the root, from 0
    period: f64 = 1200;
    error: string = "";

    get steps(): i32 {
        return this.cents.length;
    }

    // The sounding pitch (MIDI, fractional) of written pitch `pitch`.
    tune(pitch: f64): f64 {
        let n = Math.round(pitch);
        let frac = pitch - n;
        let steps = <i32>n - this.root;
        let count = this.cents.length;
        let octave = steps >= 0 ? steps / count : -((-steps + count - 1) / count);
        let degree = steps - octave * count;
        return <f64>this.root + (<f64>octave * this.period + this.cents[degree]) / 100 + frac;
    }
}

function ratioCents(num: f64, den: f64): f64 {
    return 1200 * Math.log2(num / den);
}

function fromRatios(ratios: Array<f64>): Array<f64> {
    let out = new Array<f64>();
    for (let i = 0; i < ratios.length; i += 2) out.push(ratioCents(ratios[i], ratios[i + 1]));
    return out;
}

// A built-in tuning: equal, just, pythagorean, meantone, or edo (`steps` equal steps).
export function builtinTuning(name: string, steps: i32, root: i32): Tuning {
    let t = new Tuning();
    t.root = root;
    if (name == "just") {
        t.cents = fromRatios([1, 1, 16, 15, 9, 8, 6, 5, 5, 4, 4, 3, 45, 32, 3, 2, 8, 5, 5, 3, 9, 5, 15, 8]);
    } else if (name == "pythagorean") {
        t.cents = fromRatios([1, 1, 256, 243, 9, 8, 32, 27, 81, 64, 4, 3, 729, 512, 3, 2, 128, 81, 27, 16, 16, 9, 243, 128]);
    } else if (name == "meantone") {
        t.cents = [0, 76.0, 193.2, 310.3, 386.3, 503.4, 579.5, 696.6, 772.6, 889.7, 1006.8, 1082.9];
    } else {
        let n = name == "edo" ? max<i32>(steps, 1) : 12;
        t.cents = [];
        for (let i = 0; i < n; i++) t.cents.push(1200 * <f64>i / <f64>n);
    }
    return t;
}

// A Scala .scl file: a description line, the number of notes, then one
// pitch per line, in cents (with a '.') or as a ratio; the last is the period.
// Lines starting with '!' are comments.
export function parseScala(text: string, root: i32): Tuning {
    let t = new Tuning();
    t.root = root;
    let lines = text.split("\n");
    let values = new Array<string>();
    for (let i = 0; i < lines.length; i++) {
        let line = lines[i].trim();
        if (line.startsWith("!")) continue;
        if (line.length == 0 && values.length > 0) continue; // only the description may be empty
        values.push(line);
    }
    // values[0] is the description (it may be empty).
    if (values.length < 2) {
        t.error = "a Scala file needs a description line, then the number of notes";
        return t;
    }
    let parsed = parseFloat(values[1].split(" ")[0]);
    if (!(parsed >= 1 && parsed <= 1024)) {
        t.error = `'${values[1]}' is not a number of notes`;
        return t;
    }
    let count = <i32>parsed;
    let cents: Array<f64> = [0];
    for (let i = 0; i < count; i++) {
        if (2 + i >= values.length) {
            t.error = `the file lists ${i} of its ${count} notes`;
            return t;
        }
        let word = values[2 + i].split(" ")[0];
        let c = 0.0;
        if (word.includes(".")) {
            c = parseFloat(word);
        } else {
            let slash = word.indexOf("/");
            let num = parseFloat(slash < 0 ? word : word.substring(0, slash));
            let den = slash < 0 ? 1.0 : parseFloat(word.substring(slash + 1));
            if (!(num > 0) || !(den > 0)) {
                t.error = `'${word}' is not a pitch (cents with a '.', or a ratio)`;
                return t;
            }
            c = ratioCents(num, den);
        }
        if (isNaN(c)) {
            t.error = `'${word}' is not a pitch`;
            return t;
        }
        cents.push(c);
    }
    t.period = cents.pop();
    if (!(t.period > 0)) {
        t.error = "the last pitch (the period) must be above the root";
        return t;
    }
    t.cents = cents;
    return t;
}
