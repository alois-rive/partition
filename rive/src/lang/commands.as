// The command registry (docs/spec.md §5 and §7.1): every command, where it
// may appear and the arguments it takes.

import { ArgType } from "./types";
import { FILTER_MODES, FX_TYPES, fxParams } from "./fx";
import { ParamKind } from "./paramkind";
import { MOD_DESTS, MOD_SOURCES, TUNINGS } from "./sound";

export const SCOPE_CHANNEL: i32 = 1; // channels/*.ch and patterns/*.pat
export const SCOPE_CONDUCTOR: i32 = 2; // conductor.ch
export const SCOPE_INSTRUMENT: i32 = 4; // instruments/*.inst

export const CURVES: Array<string> = ["linear", "exp", "log", "smooth"];
export const LFO_SHAPES: Array<string> = ["sine", "tri", "saw", "square", "random"];
export const WAVES: Array<string> = ["sine", "tri", "saw", "square", "pulse", "noise", "table"];
export const FILTER_TYPES: Array<string> = ["lowpass", "highpass", "bandpass", "notch", "off"];
// Keys (§5.6), in the order lang/scales.as gives their intervals.
export const MODES: Array<string> = [
    "major", "minor", "dorian", "phrygian", "lydian", "mixolydian", "locrian",
    "harmonic_minor", "melodic_minor", "pentatonic", "minor_pentatonic", "blues", "chromatic",
];
export const CHORD_TYPES: Array<string> = [
    "maj", "min", "dim", "aug", "sus2", "sus4", "maj7", "min7", "dom7", "m7b5",
    "dim7", "maj9", "min9", "dom9", "min11", "add9", "maj6", "m6",
];

// Semitones above the root for each entry of CHORD_TYPES.
export function chordIntervals(type: string): Array<i32> {
    if (type == "maj") return [0, 4, 7];
    if (type == "min") return [0, 3, 7];
    if (type == "dim") return [0, 3, 6];
    if (type == "aug") return [0, 4, 8];
    if (type == "sus2") return [0, 2, 7];
    if (type == "sus4") return [0, 5, 7];
    if (type == "maj7") return [0, 4, 7, 11];
    if (type == "min7") return [0, 3, 7, 10];
    if (type == "dom7") return [0, 4, 7, 10];
    if (type == "m7b5") return [0, 3, 6, 10];
    if (type == "dim7") return [0, 3, 6, 9];
    if (type == "maj9") return [0, 4, 7, 11, 14];
    if (type == "min9") return [0, 3, 7, 10, 14];
    if (type == "dom9") return [0, 4, 7, 10, 14];
    if (type == "min11") return [0, 3, 7, 10, 14, 17];
    if (type == "add9") return [0, 4, 7, 14];
    if (type == "maj6") return [0, 4, 7, 9];
    if (type == "m6") return [0, 3, 7, 9];
    return [0];
}

export class ArgSpec {
    choices: Array<string> = [];
    integer: bool = false;

    constructor(
        public name: string,
        public type: ArgType,
        public required: bool,
        public min: f64,
        public max: f64,
    ) {}
}

export class CommandSpec {
    args: Array<ArgSpec> = [];
    // `set` and `ramp` also take any parameter name as an argument.
    open: bool = false;
    // `pattern` and `args` also take any name: a pattern variable (§8.1).
    vars: bool = false;

    constructor(
        public name: string,
        public scopes: i32,
        public summary: string,
    ) {}

    arg(name: string): ArgSpec? {
        for (let i = 0; i < this.args.length; i++) {
            if (this.args[i].name == name) return this.args[i];
        }
        return null;
    }

    argNames(): Array<string> {
        let out = new Array<string>();
        for (let i = 0; i < this.args.length; i++) out.push(this.args[i].name);
        return out;
    }

    // The signature shown in the editor's hint line: `note(p: pitch, len?: duration, ...)`.
    // Leaves out on, except and if, which every track command takes (§8.2).
    signature(): string {
        let out = this.name + "(";
        let shown = 0;
        for (let i = 0; i < this.args.length; i++) {
            let a = this.args[i];
            if (a.name == "on" || a.name == "except" || a.name == "if" || a.name == "prob") continue;
            if (shown++ > 0) out += ", ";
            out += a.name + (a.required ? "" : "?");
        }
        if (this.open) out += (shown > 0 ? ", " : "") + "<param>: value, …";
        if (this.vars) out += (shown > 0 ? ", " : "") + "<variable>: value, …";
        return out + ")";
    }
}

class Builder {
    specs: Map<string, CommandSpec> = new Map<string, CommandSpec>();
    names: Array<string> = [];
    current: CommandSpec? = null;

    cmd(name: string, scopes: i32, summary: string): Builder {
        let spec = new CommandSpec(name, scopes, summary);
        this.specs.set(name, spec);
        this.names.push(name);
        this.current = spec;
        return this;
    }

    open(): Builder {
        this.current!.open = true;
        return this;
    }

    variables(): Builder {
        this.current!.vars = true;
        return this;
    }

    req(name: string, type: ArgType, lo: f64 = -Infinity, hi: f64 = Infinity): Builder {
        this.current!.args.push(new ArgSpec(name, type, true, lo, hi));
        return this;
    }

    opt(name: string, type: ArgType, lo: f64 = -Infinity, hi: f64 = Infinity): Builder {
        this.current!.args.push(new ArgSpec(name, type, false, lo, hi));
        return this;
    }

    // Restricts the last argument to `choices`.
    oneOf(choices: Array<string>): Builder {
        let args = this.current!.args;
        args[args.length - 1].choices = choices;
        return this;
    }

    // Requires the last argument to be a whole number.
    int(): Builder {
        let args = this.current!.args;
        args[args.length - 1].integer = true;
        return this;
    }
}

export class Registry {
    constructor(public specs: Map<string, CommandSpec>, public names: Array<string>) {}

    get(name: string): CommandSpec? {
        if (!this.specs.has(name)) return null;
        return this.specs.get(name);
    }

    namesIn(scope: i32): Array<string> {
        let out = new Array<string>();
        for (let i = 0; i < this.names.length; i++) {
            if ((this.specs.get(this.names[i]).scopes & scope) != 0) out.push(this.names[i]);
        }
        return out;
    }
}

let REGISTRY: Registry? = null;

export function registry(): Registry {
    let r = REGISTRY;
    if (r != null) return r;
    let b = new Builder();
    let CH = SCOPE_CHANNEL;
    let CO = SCOPE_CONDUCTOR;
    let IN = SCOPE_INSTRUMENT;
    let T = ArgType.Number;

    // Notes (§5.1)
    b.cmd("note", CH, "play one note, or several from a list, by pitch (p) or scale degree (d)")
        .opt("p", ArgType.Pitches).opt("d", ArgType.Degrees).opt("len", ArgType.Duration).opt("vel", ArgType.Gain, 0, 1)
        .opt("inst", ArgType.Name).opt("glide", ArgType.Duration).opt("at", ArgType.Duration)
        .opt("pick", T, 1, 32).int().opt("bend", ArgType.Interval, -24, 24).opt("press", T, 0, 1);
    b.cmd("chord", CH, "play a chord on a root, or on a scale degree (d)")
        .opt("root", ArgType.Pitch).opt("d", ArgType.Number, -28, 28).int().opt("size", ArgType.Number, 3, 5).int()
        .opt("type", ArgType.Ident).oneOf(CHORD_TYPES)
        .opt("inv", T, 0, 8).int().opt("spread", T, 0, 3).int()
        .opt("len", ArgType.Duration).opt("vel", ArgType.Gain, 0, 1).opt("strum", ArgType.Duration)
        .opt("at", ArgType.Duration).opt("bend", ArgType.Interval, -24, 24).opt("press", T, 0, 1);
    b.cmd("cut", CH, "release every sounding note").opt("fade", ArgType.Duration);
    b.cmd("prog", CH, "play a chord progression in the key, one chord per step")
        .req("chords", ArgType.Text).opt("every", ArgType.Duration).opt("len", ArgType.Duration)
        .opt("vel", ArgType.Gain, 0, 1).opt("inv", T, 0, 8).int().opt("spread", T, 0, 3).int().opt("strum", ArgType.Duration);

    // Randomness (§6.5), from the song's seed.
    b.cmd("humanize", CH, "shift each later note's start and velocity a little, at random")
        .opt("time", ArgType.Duration).opt("vel", T, 0, 1);
    b.cmd("euclid", CH, "spread hits evenly over steps (a Euclidean rhythm), from this row")
        .req("hits", T, 0, 64).int().req("steps", T, 1, 64).int().opt("rot", T, -64, 64).int()
        .opt("p", ArgType.Pitches).opt("d", ArgType.Degrees).opt("every", ArgType.Duration).opt("times", T, 1, 1000).int()
        .opt("len", ArgType.Duration).opt("vel", ArgType.Gain, 0, 1).opt("inst", ArgType.Name);
    b.cmd("pick", CH, "play one of several patterns, chosen at random on each pass")
        .req("from", ArgType.Names).opt("times", T, 1, 100000).int().variables();

    // Tunings (§7.6): the song's (in the conductor) or the track's.
    b.cmd("tuning", CH | CO, "tune the notes: a temperament, n equal steps, or a Scala file")
        .opt("v", ArgType.Ident).oneOf(TUNINGS).opt("steps", T, 5, 72).int().opt("file", ArgType.Name).opt("root", ArgType.Pitch);

    // Keys (§5.6): the track's, or (in the conductor) the song's.
    b.cmd("key", CH | CO, "set the key that scale degrees and progressions use")
        .req("root", ArgType.Pitch).opt("mode", ArgType.Ident).oneOf(MODES);

    // Modifiers (§5.2)
    b.cmd("inst", CH, "select an instrument").req("name", ArgType.Name);
    b.cmd("oct", CH, "octave for pitches written without one").req("v", T, -1, 9).int();
    b.cmd("transpose", CH, "shift every later note").req("v", ArgType.Interval, -48, 48);
    b.cmd("vel", CH, "default velocity").req("v", ArgType.Gain, 0, 1);
    b.cmd("len", CH, "default note length").req("v", ArgType.Duration);
    b.cmd("vol", CH, "channel volume").req("v", ArgType.Gain, 0, 4);
    b.cmd("pan", CH, "channel pan, -1..1").req("v", T, -1, 1);
    b.cmd("set", CH | CO, "set channel, instrument or effect parameters").open();

    // Automation (§5.3); `ramp` is also a conductor command for bpm and master.
    b.cmd("ramp", CH | CO, "move parameters to a target over time").open()
        .req("over", ArgType.Duration).opt("curve", ArgType.Ident).oneOf(CURVES);
    b.cmd("glide", CH, "slide the pitch of sounding notes")
        .req("to", ArgType.Pitch).req("over", ArgType.Duration);
    b.cmd("lfo", CH, "modulate a parameter")
        .req("param", ArgType.Ident).req("rate", ArgType.Rate).req("depth", T)
        .opt("shape", ArgType.Ident).oneOf(LFO_SHAPES).opt("id", ArgType.Ident);
    b.cmd("lfo_off", CH, "stop an LFO").req("param", ArgType.Ident).opt("id", ArgType.Ident);

    // Mixer (§7.5): an effect on the track, bus or (in the conductor) master.
    b.cmd("fx", CH | CO, "add an effect to the track, bus or master chain").req("type", ArgType.Ident).oneOf(FX_TYPES);
    let fx = fxParams();
    let seen = new Array<string>();
    for (let i = 0; i < fx.length; i++) {
        let f = fx[i];
        if (seen.includes(f.arg)) continue;
        seen.push(f.arg);
        let type = f.kind == ParamKind.Gain ? ArgType.Gain : f.kind == ParamKind.Freq ? ArgType.Freq : f.kind == ParamKind.Time ? ArgType.Time : ArgType.Number;
        b.opt(f.arg, type, f.min, f.max);
    }
    b.opt("sidechain", ArgType.Name).opt("mode", ArgType.Ident).oneOf(FILTER_MODES);

    // Patterns (§5.4)
    b.cmd("pattern", CH, "play a pattern from this row")
        .req("name", ArgType.Name).opt("times", T, 1, 100000).int().opt("id", ArgType.Ident).variables();
    b.cmd("args", CH, "a pattern's variables and their defaults").variables();
    b.cmd("stop", CH, "stop running patterns").opt("id", ArgType.Ident);

    // Conductor (§5.5)
    b.cmd("bpm", CO, "change the tempo").req("v", T, 20, 999);
    b.cmd("sig", CO, "change the time signature").req("v", ArgType.Fraction);
    b.cmd("rpb", CO, "change rows per beat").req("v", T, 1, 64).int();
    b.cmd("swing", CO, "swing amount").req("v", T, 0, 0.75);
    b.cmd("master", CO, "master volume").opt("vol", ArgType.Gain, 0, 4);
    b.cmd("mark", CO, "name this row").req("name", ArgType.Ident);
    b.cmd("jump", CO, "jump back to a mark").req("to", ArgType.Ident).opt("times", T, 0, 100000).int();
    b.cmd("end", CO, "end the song after this row");

    // Instruments (§7.1)
    b.cmd("base", IN, "start from a preset").req("preset", ArgType.Name);
    b.cmd("osc", IN, "add an oscillator")
        .req("wave", ArgType.Ident).oneOf(WAVES).opt("level", ArgType.Gain, 0, 4)
        .opt("oct", T, -4, 4).int().opt("semi", ArgType.Interval, -24, 24)
        .opt("detune", ArgType.Interval, -24, 24).opt("pw", T, 0.01, 0.99)
        .opt("unison", T, 1, 7).int().opt("spread", ArgType.Interval, 0, 12)
        .opt("fm", T, 0, 20).opt("ratio", T, 0.01, 32).opt("phase", ArgType.Phase, -1, 1)
        .opt("table", ArgType.Name).opt("pos", T, 0, 1);
    b.cmd("mod", IN, "route a modulation source to a destination (the modulation matrix)")
        .req("src", ArgType.Ident).oneOf(MOD_SOURCES).req("dst", ArgType.Ident).oneOf(MOD_DESTS)
        .req("amt", T, -48, 48).opt("via", ArgType.Ident).oneOf(MOD_SOURCES);
    b.cmd("mod_env", IN, "the second envelope, a modulation source (env2)")
        .opt("a", ArgType.Time, 0, 30).opt("d", ArgType.Time, 0, 30).opt("s", ArgType.Gain, 0, 1).opt("r", ArgType.Time, 0, 30);
    b.cmd("vlfo", IN, "a per-voice LFO, a modulation source (lfo1, lfo2)")
        .req("n", T, 1, 2).int().opt("rate", ArgType.Freq, 0.01, 40).opt("shape", ArgType.Ident).oneOf(LFO_SHAPES)
        .opt("delay", ArgType.Time, 0, 10);
    b.cmd("env", IN, "amplitude envelope")
        .opt("a", ArgType.Time, 0, 30).opt("d", ArgType.Time, 0, 30).opt("s", ArgType.Gain, 0, 1)
        .opt("r", ArgType.Time, 0, 30).opt("curve", T, -10, 10)
        .opt("burst", T, 1, 8).int().opt("burst_gap", ArgType.Time, 0, 1);
    b.cmd("pitch_env", IN, "pitch drop envelope")
        .req("amount", ArgType.Interval, -96, 96).req("decay", ArgType.Time, 0, 10);
    b.cmd("filter", IN, "filter")
        .opt("type", ArgType.Ident).oneOf(FILTER_TYPES).opt("cutoff", ArgType.Freq, 10, 22000)
        .opt("res", T, 0, 1).opt("env", T, -1, 1).opt("keytrack", T, 0, 1).opt("slope", T, 12, 24).int();
    b.cmd("filter_env", IN, "filter envelope")
        .opt("a", ArgType.Time, 0, 30).opt("d", ArgType.Time, 0, 30).opt("s", ArgType.Gain, 0, 1)
        .opt("r", ArgType.Time, 0, 30);
    b.cmd("drive", IN, "soft saturation").req("v", T, 0, 1);
    b.cmd("voice", IN, "voicing")
        .opt("poly", T, 1, 32).int().opt("mono", ArgType.Bool).opt("glide", ArgType.Time, 0, 10)
        .opt("retrigger", ArgType.Bool).opt("fixed", ArgType.Pitch).opt("width", T, 0, 1);
    b.cmd("defaults", IN, "channel values applied when first selected")
        .opt("vol", ArgType.Gain, 0, 4).opt("pan", T, -1, 1)
        .opt("delay", ArgType.Gain, 0, 1).opt("reverb", ArgType.Gain, 0, 1);
    b.cmd("sample", IN, "play a sample file, samples/<file>.wav, over a range of notes")
        .req("file", ArgType.Name).opt("root", ArgType.Pitch).opt("lo", ArgType.Pitch).opt("hi", ArgType.Pitch)
        .opt("key", ArgType.Pitch)
        .opt("gain", ArgType.Gain, 0, 8).opt("tune", ArgType.Interval, -48, 48)
        .opt("start", ArgType.Time, 0, 3600).opt("end", ArgType.Time, 0, 3600)
        .opt("loop", ArgType.Bool).opt("loop_start", ArgType.Time, 0, 3600).opt("loop_end", ArgType.Time, 0, 3600)
        .opt("slices", T, 1, 128).int().opt("oneshot", ArgType.Bool).opt("reverse", ArgType.Bool)
        .opt("choke", T, 0, 16).int();
    b.cmd("param", IN, "define a macro parameter")
        .req("name", ArgType.Ident).req("target", ArgType.Ident).opt("min", T).opt("max", T);

    // Every track and pattern command can play on some passes only (§8.2).
    for (let i = 0; i < b.names.length; i++) {
        let spec = b.specs.get(b.names[i]);
        if ((spec.scopes & CH) == 0) continue;
        spec.args.push(new ArgSpec("on", ArgType.Pass, false, -Infinity, Infinity));
        spec.args.push(new ArgSpec("except", ArgType.Pass, false, -Infinity, Infinity));
        spec.args.push(new ArgSpec("if", ArgType.Bool, false, -Infinity, Infinity));
        spec.args.push(new ArgSpec("prob", ArgType.Gain, false, 0, 1));
    }

    let made = new Registry(b.specs, b.names);
    REGISTRY = made;
    return made;
}
