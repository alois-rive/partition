// Typed argument values (docs/spec.md §4.4): what a raw ValueNode means once
// the argument it was given to is known.

import { ValueKind, ValueNode } from "./ast";

export enum ArgType {
    Number,
    Gain, // linear; accepts 80% and -6dB
    Freq, // Hz; accepts 440Hz and 2k
    Pitch,
    Pitches, // a pitch or a list of pitches
    Interval, // semitones; accepts 7st and 25c
    Duration, // rows, note value, beats, bars or seconds
    Time, // seconds only (instrument envelopes)
    Rate, // a duration (one LFO cycle) or a frequency
    Ident,
    Name, // a reference to an instrument, pattern or mark
    Text, // a string, or a bare word
    Bool,
    Fraction,
    Phase, // 0..1, or `random`
    Pass, // which passes: 3 (the third), 4/4 (the 4th of every 4)
    Degrees, // a scale degree, or a list of them (§5.6)
}

export enum DurUnit {
    Rows,
    Note, // fraction of a whole note
    Beats,
    Bars,
    Seconds,
    Hz, // only for Rate
}

export class Typed {
    type: ArgType = ArgType.Number;
    num: f64 = 0; // the value in canonical units (see ArgType)
    num2: f64 = 0; // a fraction's denominator
    unit: DurUnit = DurUnit.Rows;
    hasOctave: bool = true; // false: `num` is a pitch class to place with `oct`
    str: string = "";
    bool: bool = false;
    items: Array<Typed> = [];
    col: i32 = 0;
    endCol: i32 = 0;

    static number(type: ArgType, value: f64): Typed {
        let t = new Typed();
        t.type = type;
        t.num = value;
        return t;
    }

    static duration(unit: DurUnit, amount: f64): Typed {
        let t = new Typed();
        t.type = ArgType.Duration;
        t.unit = unit;
        t.num = amount;
        return t;
    }
}

// The outcome of typing one value: the value, or why it does not fit.
export class TypeResult {
    value: Typed? = null;
    error: string = "";

    static ok(v: Typed): TypeResult {
        let r = new TypeResult();
        r.value = v;
        return r;
    }

    static fail(message: string): TypeResult {
        let r = new TypeResult();
        r.error = message;
        return r;
    }
}

export function typeName(type: ArgType): string {
    switch (type) {
        case ArgType.Number: return "a number";
        case ArgType.Gain: return "a gain (0.8, 80%, -6dB)";
        case ArgType.Freq: return "a frequency (440, 440Hz, 2k)";
        case ArgType.Pitch: return "a pitch (C4, F#3, Bb2, 60)";
        case ArgType.Pitches: return "a pitch or a list of pitches ([C4, E4, G4])";
        case ArgType.Interval: return "an interval (7st, -12st, 25c)";
        case ArgType.Duration: return "a duration (2, 1/8, 1b, 2bar, 250ms)";
        case ArgType.Time: return "a time (250ms, 1.5s)";
        case ArgType.Rate: return "a rate (1bar, 1/4, 2Hz)";
        case ArgType.Ident: return "a name";
        case ArgType.Name: return "a name";
        case ArgType.Text: return "a string";
        case ArgType.Bool: return "true or false";
        case ArgType.Fraction: return "a fraction (3/4)";
        case ArgType.Phase: return "a phase (0..1 or random)";
        case ArgType.Pass: return "a pass (3, or 4/4 for the 4th of every 4)";
        case ArgType.Degrees: return "a scale degree or a list of them (5, [1, 3, 5])";
        default: return "a value";
    }
}

// Parses a pitch such as C4, F#3, Bb2, c-1 or C (no octave). Returns null if
// `text` is not one.
export function parsePitch(text: string): Typed? {
    let n = text.length;
    if (n == 0) return null;
    let c = text.charCodeAt(0) | 32; // lowercase
    let pcs: StaticArray<i32> = [9, 11, 0, 2, 4, 5, 7]; // a b c d e f g
    if (c < 97 || c > 103) return null;
    let pc = pcs[c - 97];
    let i = 1;
    if (i < n) {
        let a = text.charCodeAt(i);
        if (a == 35) {
            pc += 1;
            i++;
        } else if (a == 98) {
            pc -= 1;
            i++;
        }
    }
    let t = new Typed();
    t.type = ArgType.Pitch;
    if (i == n) {
        t.hasOctave = false;
        t.num = <f64>pc;
        return t;
    }
    let rest = text.substring(i);
    let octave: i32 = 0;
    if (rest == "-1") {
        octave = -1;
    } else if (rest.length == 1 && rest.charCodeAt(0) >= 48 && rest.charCodeAt(0) <= 57) {
        octave = rest.charCodeAt(0) - 48;
    } else {
        return null;
    }
    t.num = <f64>((octave + 1) * 12 + pc);
    return t;
}

function unitless(v: ValueNode): bool {
    return v.kind == ValueKind.Number && v.unit.length == 0;
}

function plainNumber(v: ValueNode): f64 {
    // A fraction reads as its quotient where a plain number is expected.
    if (v.kind == ValueKind.Fraction) return v.num / v.den;
    if (v.unit == "k") return v.num * 1000;
    if (v.unit == "%") return v.num / 100;
    return v.num;
}

function isPlain(v: ValueNode): bool {
    return v.kind == ValueKind.Fraction || (v.kind == ValueKind.Number && (v.unit == "" || v.unit == "k" || v.unit == "%"));
}

function found(v: ValueNode, type: ArgType): TypeResult {
    let shown = v.kind == ValueKind.String ? `"${v.text}"` : v.text;
    return TypeResult.fail(`expected ${typeName(type)}, found '${shown}'`);
}

// Types `v` as `type`. Range checks are left to the caller.
export function typeValue(v: ValueNode, type: ArgType): TypeResult {
    let r = typeScalarOrList(v, type);
    let value = r.value;
    if (value != null) {
        value.col = v.col;
        value.endCol = v.endCol;
    }
    return r;
}

function typeScalarOrList(v: ValueNode, type: ArgType): TypeResult {
    if (v.kind == ValueKind.List && type == ArgType.Degrees) {
        let degrees = new Typed();
        degrees.type = ArgType.Degrees;
        for (let i = 0; i < v.items.length; i++) {
            let item = typeValue(v.items[i], ArgType.Degrees);
            let value = item.value;
            if (value == null) return item;
            degrees.items.push(value);
        }
        if (degrees.items.length == 0) return TypeResult.fail("a degree list cannot be empty");
        return TypeResult.ok(degrees);
    }
    if (v.kind == ValueKind.List) {
        if (type != ArgType.Pitches) return TypeResult.fail(`a list is not allowed here; expected ${typeName(type)}`);
        let list = new Typed();
        list.type = ArgType.Pitches;
        for (let i = 0; i < v.items.length; i++) {
            let item = typeValue(v.items[i], ArgType.Pitch);
            let value = item.value;
            if (value == null) return item;
            list.items.push(value);
        }
        if (list.items.length == 0) return TypeResult.fail("a pitch list cannot be empty");
        return TypeResult.ok(list);
    }
    switch (type) {
        case ArgType.Number: {
            if (isPlain(v)) return TypeResult.ok(Typed.number(type, plainNumber(v)));
            return found(v, type);
        }
        case ArgType.Gain: {
            if (v.kind == ValueKind.Number && v.unit == "dB") return TypeResult.ok(Typed.number(type, Math.pow(10, v.num / 20)));
            if (isPlain(v) && v.unit != "k") return TypeResult.ok(Typed.number(type, plainNumber(v)));
            return found(v, type);
        }
        case ArgType.Freq: {
            if (v.kind == ValueKind.Number && (v.unit == "" || v.unit == "Hz" || v.unit == "k")) return TypeResult.ok(Typed.number(type, plainNumber(v)));
            return found(v, type);
        }
        case ArgType.Pitch:
        case ArgType.Pitches: {
            if (v.kind == ValueKind.Word) {
                let p = parsePitch(v.text);
                if (p != null) {
                    if (type == ArgType.Pitches) {
                        let list = new Typed();
                        list.type = ArgType.Pitches;
                        p.col = v.col;
                        p.endCol = v.endCol;
                        list.items.push(p);
                        return TypeResult.ok(list);
                    }
                    return TypeResult.ok(p);
                }
            }
            if (unitless(v) && v.num == Math.floor(v.num) && v.num >= 0 && v.num <= 127) {
                let p = Typed.number(ArgType.Pitch, v.num);
                if (type == ArgType.Pitches) {
                    let list = new Typed();
                    list.type = ArgType.Pitches;
                    list.items.push(p);
                    return TypeResult.ok(list);
                }
                return TypeResult.ok(p);
            }
            return found(v, type);
        }
        case ArgType.Interval: {
            if (v.kind == ValueKind.Number && (v.unit == "" || v.unit == "st")) return TypeResult.ok(Typed.number(type, v.num));
            if (v.kind == ValueKind.Number && v.unit == "c") return TypeResult.ok(Typed.number(type, v.num / 100));
            return found(v, type);
        }
        case ArgType.Duration:
        case ArgType.Rate: {
            if (v.kind == ValueKind.Fraction) {
                let t = Typed.duration(DurUnit.Note, v.num / v.den);
                t.type = type;
                return TypeResult.ok(t);
            }
            if (v.kind == ValueKind.Number) {
                let unit = v.unit;
                let t: Typed? = null;
                if (unit == "") t = Typed.duration(DurUnit.Rows, v.num);
                else if (unit == "b") t = Typed.duration(DurUnit.Beats, v.num);
                else if (unit == "bar") t = Typed.duration(DurUnit.Bars, v.num);
                else if (unit == "ms") t = Typed.duration(DurUnit.Seconds, v.num / 1000);
                else if (unit == "s") t = Typed.duration(DurUnit.Seconds, v.num);
                else if (type == ArgType.Rate && unit == "Hz") t = Typed.duration(DurUnit.Hz, v.num);
                if (t != null) {
                    t.type = type;
                    if (t.num < 0) return TypeResult.fail(`a ${type == ArgType.Rate ? "rate" : "duration"} cannot be negative`);
                    return TypeResult.ok(t);
                }
            }
            return found(v, type);
        }
        case ArgType.Time: {
            if (v.kind == ValueKind.Number && (v.unit == "" || v.unit == "s")) return TypeResult.ok(Typed.number(type, v.num));
            if (v.kind == ValueKind.Number && v.unit == "ms") return TypeResult.ok(Typed.number(type, v.num / 1000));
            return found(v, type);
        }
        case ArgType.Ident:
        case ArgType.Name: {
            if (v.kind == ValueKind.Word && (isName(v.text) || (type == ArgType.Ident && isDottedName(v.text)))) {
                let t = new Typed();
                t.type = type;
                t.str = v.text;
                return TypeResult.ok(t);
            }
            return found(v, type);
        }
        case ArgType.Text: {
            if (v.kind == ValueKind.String || v.kind == ValueKind.Word) {
                let t = new Typed();
                t.type = type;
                t.str = v.text;
                return TypeResult.ok(t);
            }
            return found(v, type);
        }
        case ArgType.Bool: {
            if (v.kind == ValueKind.Word && (v.text == "true" || v.text == "false")) {
                let t = new Typed();
                t.type = type;
                t.bool = v.text == "true";
                t.num = t.bool ? 1 : 0;
                return TypeResult.ok(t);
            }
            return found(v, type);
        }
        case ArgType.Pass: {
            if (v.kind == ValueKind.Fraction) {
                if (v.num >= 1 && v.num <= v.den && v.num == Math.floor(v.num)) {
                    let t = Typed.number(type, v.num);
                    t.num2 = v.den;
                    return TypeResult.ok(t);
                }
            } else if (isPlain(v) && plainNumber(v) >= 1 && plainNumber(v) == Math.floor(plainNumber(v))) {
                let t = Typed.number(type, plainNumber(v));
                t.num2 = 0;
                return TypeResult.ok(t);
            }
            return TypeResult.fail(`expected ${typeName(type)}, a whole number from 1, or N/M with N from 1 to M`);
        }
        case ArgType.Degrees: {
            if (isPlain(v) && plainNumber(v) == Math.floor(plainNumber(v)) && Math.abs(plainNumber(v)) <= 40) {
                let t = Typed.number(type, plainNumber(v));
                return TypeResult.ok(t);
            }
            return TypeResult.fail(`expected ${typeName(type)}: whole numbers, 1 for the key's root`);
        }
        case ArgType.Fraction: {
            if (v.kind == ValueKind.Fraction) {
                let t = Typed.number(type, v.num);
                t.num2 = v.den;
                return TypeResult.ok(t);
            }
            return found(v, type);
        }
        case ArgType.Phase: {
            if (v.kind == ValueKind.Word && v.text == "random") return TypeResult.ok(Typed.number(type, -1));
            if (isPlain(v)) return TypeResult.ok(Typed.number(type, plainNumber(v)));
            return found(v, type);
        }
        default:
            return found(v, type);
    }
}

// Names of instruments, patterns, marks and enumerations: lowercase letters,
// digits and '_', starting with a letter or '_'.
export function isName(text: string): bool {
    if (text.length == 0) return false;
    for (let i = 0; i < text.length; i++) {
        let c = text.charCodeAt(i);
        let ok = (c >= 97 && c <= 122) || c == 95 || (i > 0 && c >= 48 && c <= 57);
        if (!ok) return false;
    }
    return true;
}

// A parameter name with a dot, such as osc2.fm.
export function isDottedName(text: string): bool {
    let dot = text.indexOf(".");
    if (dot <= 0 || dot == text.length - 1) return false;
    return isName(text.substring(0, dot)) && isName(text.substring(dot + 1));
}
