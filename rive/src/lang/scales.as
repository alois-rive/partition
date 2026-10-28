// Keys, scale degrees and Roman-numeral chords (docs/spec.md §5.6).

import { CHORD_TYPES } from "./commands";

export { MODES } from "./commands";

// Semitones above the root of each degree of mode `index`.
export function modeIntervals(index: i32): Array<i32> {
    switch (index) {
        case 1: return [0, 2, 3, 5, 7, 8, 10];
        case 2: return [0, 2, 3, 5, 7, 9, 10];
        case 3: return [0, 1, 3, 5, 7, 8, 10];
        case 4: return [0, 2, 4, 6, 7, 9, 11];
        case 5: return [0, 2, 4, 5, 7, 9, 10];
        case 6: return [0, 1, 3, 5, 6, 8, 10];
        case 7: return [0, 2, 3, 5, 7, 8, 11];
        case 8: return [0, 2, 3, 5, 7, 9, 11];
        case 9: return [0, 2, 4, 7, 9];
        case 10: return [0, 3, 5, 7, 10];
        case 11: return [0, 3, 5, 6, 7, 10];
        case 12: return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
        default: return [0, 2, 4, 5, 7, 9, 11];
    }
}

// Semitones from the root to `degree` (1 is the root; 8 an octave up in a
// seven-note mode; 0 and below go down).
export function degreeSemitones(mode: i32, degree: i32): i32 {
    let iv = modeIntervals(mode);
    let n = iv.length;
    let i = degree - 1;
    let octave = i >= 0 ? i / n : -((-i + n - 1) / n);
    let index = i - octave * n;
    return iv[index] + 12 * octave;
}

// One chord of a progression: semitones of its root above the key's root and
// its type, or a hold ("-") or a rest (".").
export class Numeral {
    hold: bool = false;
    rest: bool = false;
    root: i32 = 0;
    type: string = "maj";
    error: string = "";
}

const ROMANS: Array<string> = ["vii", "vi", "v", "iv", "iii", "ii", "i"];
const ROMAN_DEGREES: Array<i32> = [7, 6, 5, 4, 3, 2, 1];

// Reads "ii", "V7", "bVII", "Imaj7", "vi9", "viidim", "IVsus2"… in a mode.
// Seven-note modes place the numerals on their own degrees; others on major's.
export function parseNumeral(token: string, mode: i32): Numeral {
    let out = new Numeral();
    if (token == "-") {
        out.hold = true;
        return out;
    }
    if (token == "." || token == "_") {
        out.rest = true;
        return out;
    }
    let s = token;
    let shift = 0;
    while (s.startsWith("b") && s.length > 1 && (s.charAt(1) == "I" || s.charAt(1) == "V" || s.charAt(1) == "i" || s.charAt(1) == "v" || s.charAt(1) == "b")) {
        shift--;
        s = s.substring(1);
    }
    while (s.startsWith("#")) {
        shift++;
        s = s.substring(1);
    }
    let degree = 0;
    let numeralLength = 0;
    let lower = s.toLowerCase();
    for (let i = 0; i < ROMANS.length; i++) {
        if (lower.startsWith(ROMANS[i])) {
            degree = ROMAN_DEGREES[i];
            numeralLength = ROMANS[i].length;
            break;
        }
    }
    if (degree == 0) {
        out.error = `'${token}' is not a chord numeral (I to VII, lowercase for minor, then 7, maj7, 9, 6, dim, aug, sus2, sus4…)`;
        return out;
    }
    let numeral = s.substring(0, numeralLength);
    let upper = numeral == numeral.toUpperCase();
    let suffix = s.substring(numeralLength);
    let type = "";
    if (suffix == "") type = upper ? "maj" : "min";
    else if (suffix == "7") type = upper ? "dom7" : "min7";
    else if (suffix == "9") type = upper ? "dom9" : "min9";
    else if (suffix == "6") type = upper ? "maj6" : "m6";
    else if (suffix == "11") type = "min11";
    else if (suffix == "+") type = "aug";
    else if (suffix == "o" || suffix == "dim") type = "dim";
    else if (suffix == "o7") type = "dim7";
    else type = suffix;
    if (!CHORD_TYPES.includes(type)) {
        out.error = `'${token}': unknown chord ending '${suffix}' (7, maj7, 9, maj9, 6, dim, dim7, m7b5, aug, sus2, sus4, add9, 11)`;
        return out;
    }
    let scale = modeIntervals(mode).length == 7 ? mode : 0;
    out.root = degreeSemitones(scale, degree) + shift;
    out.type = type;
    return out;
}

// The tokens of a progression: chords, holds and rests, separated by spaces.
export function progressionTokens(text: string): Array<string> {
    let out = new Array<string>();
    let parts = text.split(" ");
    for (let i = 0; i < parts.length; i++) {
        let p = parts[i].trim();
        if (p.length > 0) out.push(p);
    }
    return out;
}
