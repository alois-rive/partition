// Instrument definitions (docs/spec.md §7): what an .inst file or a preset
// describes, as plain data for the score and the engine.

import { CheckedCommand, CheckedFile, checkSource, CheckContext, FileKind } from "../lang/check";
import { Diagnostics } from "../lang/diagnostics";
import { MAX_OSCS, ParamInfo, paramByName, ParamScope } from "../lang/params";
import { Song } from "../lang/song";
import { presetSource } from "./presets";

export const DEFAULT_INSTRUMENT: string = "sine";

// Every built-in preset (§7.3).
export const PRESET_NAMES: Array<string> = [
    "sine", "tri", "saw", "square", "pulse", "noise",
    "sub_bass", "deep_bass", "organ_bass", "acid_bass",
    "stab", "pluck", "epiano", "organ", "bell",
    "pad", "strings", "supersaw", "lead",
    "kick", "kick_deep", "snare", "clap", "rim", "hat_closed", "hat_open", "shaker", "tom",
];

export class OscDef {
    wave: string = "sine";
    level: f64 = 1;
    oct: f64 = 0;
    semi: f64 = 0;
    detune: f64 = 0; // semitones
    pw: f64 = 0.5;
    unison: i32 = 1;
    spread: f64 = 0; // semitones
    fm: f64 = 0;
    ratio: f64 = 1;
    phase: f64 = -1; // -1: random

    clone(): OscDef {
        let o = new OscDef();
        o.wave = this.wave;
        o.level = this.level;
        o.oct = this.oct;
        o.semi = this.semi;
        o.detune = this.detune;
        o.pw = this.pw;
        o.unison = this.unison;
        o.spread = this.spread;
        o.fm = this.fm;
        o.ratio = this.ratio;
        o.phase = this.phase;
        return o;
    }
}

export class EnvDef {
    a: f64 = 0.005;
    d: f64 = 0.2;
    s: f64 = 0.8;
    r: f64 = 0.2;
    curve: f64 = 0;
    burst: i32 = 1;
    burstGap: f64 = 0.01;

    clone(): EnvDef {
        let e = new EnvDef();
        e.a = this.a;
        e.d = this.d;
        e.s = this.s;
        e.r = this.r;
        e.curve = this.curve;
        e.burst = this.burst;
        e.burstGap = this.burstGap;
        return e;
    }
}

// One sample zone (§7.4): a sample file played over a range of notes.
export class ZoneDef {
    sample: string = "";
    sampleIndex: i32 = -1; // in the song's sample bank
    root: f64 = 60; // the note that plays the file at its own pitch
    lo: f64 = 0;
    hi: f64 = 127;
    gain: f64 = 1;
    tune: f64 = 0; // semitones
    start: f64 = 0; // seconds into the file
    end: f64 = 0; // seconds into the file; 0 plays to its end
    loop: bool = false;
    loopStart: f64 = 0;
    loopEnd: f64 = 0; // 0: the zone's end
    slices: i32 = 0; // > 0: the zone is cut into equal slices, one per note from root up
    oneshot: bool = false; // plays to its end whatever the note's length
    reverse: bool = false;
    choke: i32 = 0; // > 0: a note in the group cuts the group's other notes on the track

    clone(): ZoneDef {
        let z = new ZoneDef();
        z.sample = this.sample;
        z.sampleIndex = this.sampleIndex;
        z.root = this.root;
        z.lo = this.lo;
        z.hi = this.hi;
        z.gain = this.gain;
        z.tune = this.tune;
        z.start = this.start;
        z.end = this.end;
        z.loop = this.loop;
        z.loopStart = this.loopStart;
        z.loopEnd = this.loopEnd;
        z.slices = this.slices;
        z.oneshot = this.oneshot;
        z.reverse = this.reverse;
        z.choke = this.choke;
        return z;
    }
}

export const MAX_ZONES: i32 = 16;

// A macro parameter: `set(<name>: v)` moves `target` to min + v × (max − min).
export class Macro {
    constructor(public name: string, public target: ParamInfo, public min: f64, public max: f64) {}

    map(v: f64): f64 {
        if (isNaN(this.min) || isNaN(this.max)) return v;
        return this.min + v * (this.max - this.min);
    }
}

export class InstrumentDef {
    name: string = "";
    oscs: Array<OscDef> = [];
    amp: EnvDef = new EnvDef();
    pitchAmount: f64 = 0; // semitones
    pitchDecay: f64 = 0;
    filterType: string = "off";
    cutoff: f64 = 20000;
    res: f64 = 0;
    filterEnvAmount: f64 = 0;
    keytrack: f64 = 0;
    slope: i32 = 12;
    filterEnv: EnvDef = new EnvDef();
    drive: f64 = 0;
    poly: i32 = 8;
    mono: bool = false;
    glide: f64 = 0;
    retrigger: bool = true;
    fixedPitch: f64 = NaN; // MIDI note every note plays at (drums); NaN plays the written pitch
    // Channel values applied when the instrument is first selected; NaN for none.
    defaultVol: f64 = NaN;
    defaultPan: f64 = NaN;
    defaultDelay: f64 = NaN;
    defaultReverb: f64 = NaN;
    macros: Array<Macro> = [];
    zones: Array<ZoneDef> = [];

    clone(): InstrumentDef {
        let d = new InstrumentDef();
        d.name = this.name;
        for (let i = 0; i < this.oscs.length; i++) d.oscs.push(this.oscs[i].clone());
        d.amp = this.amp.clone();
        d.pitchAmount = this.pitchAmount;
        d.pitchDecay = this.pitchDecay;
        d.filterType = this.filterType;
        d.cutoff = this.cutoff;
        d.res = this.res;
        d.filterEnvAmount = this.filterEnvAmount;
        d.keytrack = this.keytrack;
        d.slope = this.slope;
        d.filterEnv = this.filterEnv.clone();
        d.drive = this.drive;
        d.poly = this.poly;
        d.mono = this.mono;
        d.glide = this.glide;
        d.retrigger = this.retrigger;
        d.fixedPitch = this.fixedPitch;
        d.defaultVol = this.defaultVol;
        d.defaultPan = this.defaultPan;
        d.defaultDelay = this.defaultDelay;
        d.defaultReverb = this.defaultReverb;
        for (let i = 0; i < this.macros.length; i++) d.macros.push(this.macros[i]);
        for (let i = 0; i < this.zones.length; i++) d.zones.push(this.zones[i].clone());
        return d;
    }

    macro(name: string): Macro? {
        for (let i = 0; i < this.macros.length; i++) {
            if (this.macros[i].name == name) return this.macros[i];
        }
        return null;
    }
}

function applyEnv(env: EnvDef, c: CheckedCommand): void {
    env.a = c.num("a", env.a);
    env.d = c.num("d", env.d);
    env.s = c.num("s", env.s);
    env.r = c.num("r", env.r);
    env.curve = c.num("curve", env.curve);
    env.burst = <i32>c.num("burst", <f64>env.burst);
    env.burstGap = c.num("burst_gap", env.burstGap);
}

// Builds a definition from a checked .inst file. `resolve` supplies presets
// for `base`; unknown ones are reported in `diagnostics`.
// A pitch argument as a MIDI note: one written without an octave is in octave 4.
function pitchArg(c: CheckedCommand, name: string, fallback: f64): f64 {
    if (!c.has(name)) return fallback;
    let v = c.get(name);
    return v.hasOctave ? v.num : 60 + v.num;
}

export function buildInstrument(name: string, file: CheckedFile, library: InstrumentLibrary?, diagnostics: Diagnostics): InstrumentDef {
    let def = new InstrumentDef();
    def.name = name;
    let commands = file.commands();
    let ownOscs = new Array<OscDef>();
    let ownZones = new Array<ZoneDef>();
    let envSet = false;
    let based = false;
    for (let i = 0; i < commands.length; i++) {
        let c = commands[i];
        let n = c.name;
        if (n == "base") {
            let preset = c.str("preset", "");
            let base: InstrumentDef? = null;
            if (library != null) base = library.preset(preset);
            if (base == null) {
                let v = c.get("preset");
                diagnostics.error(c.line, v.col, v.endCol, "unknown-instrument", `'${preset}' is not a preset`);
                continue;
            }
            if (i > 0) diagnostics.warning(c.line, c.node.col, c.node.endCol, "order", "'base' replaces everything above it; put it first");
            def = base.clone();
            def.name = name;
            based = true;
        } else if (n == "osc") {
            if (ownOscs.length >= MAX_OSCS) {
                diagnostics.error(c.line, c.node.col, c.node.endCol, "range", `an instrument has at most ${MAX_OSCS} oscillators`);
                continue;
            }
            let o = new OscDef();
            o.wave = c.str("wave", o.wave);
            o.level = c.num("level", o.level);
            o.oct = c.num("oct", o.oct);
            o.semi = c.num("semi", o.semi);
            o.detune = c.num("detune", o.detune);
            o.pw = c.num("pw", o.pw);
            o.unison = <i32>c.num("unison", 1);
            o.spread = c.num("spread", o.spread);
            o.fm = c.num("fm", o.fm);
            o.ratio = c.num("ratio", o.ratio);
            o.phase = c.num("phase", o.phase);
            ownOscs.push(o);
        } else if (n == "env") {
            applyEnv(def.amp, c);
            envSet = true;
        } else if (n == "sample") {
            if (ownZones.length >= MAX_ZONES) {
                diagnostics.error(c.line, c.node.col, c.node.endCol, "range", `an instrument has at most ${MAX_ZONES} samples`);
                continue;
            }
            let z = new ZoneDef();
            z.sample = c.str("file", "");
            let names = library != null ? library.sampleNames : new Array<string>();
            z.sampleIndex = names.indexOf(z.sample);
            if (z.sampleIndex < 0) {
                let v = c.get("file");
                diagnostics.error(c.line, v.col, v.endCol, "unknown-sample", `there is no sample '${z.sample}': put it in samples/${z.sample}.wav`);
                continue;
            }
            // `key` is the one note a drum hit plays on, at its own pitch.
            let key = pitchArg(c, "key", NaN);
            z.root = pitchArg(c, "root", isNaN(key) ? 60 : key);
            z.slices = <i32>c.num("slices", 0);
            z.lo = pitchArg(c, "lo", !isNaN(key) ? key : z.slices > 0 ? z.root : 0);
            z.hi = pitchArg(c, "hi", !isNaN(key) ? key : z.slices > 0 ? z.root + <f64>(z.slices - 1) : 127);
            if (z.hi < z.lo) {
                diagnostics.error(c.line, c.node.col, c.node.endCol, "range", "'hi' is below 'lo'");
                continue;
            }
            z.gain = c.num("gain", 1);
            z.tune = c.num("tune", 0);
            z.start = c.num("start", 0);
            z.end = c.num("end", 0);
            if (z.end > 0 && z.end <= z.start) {
                diagnostics.error(c.line, c.node.col, c.node.endCol, "range", "'end' must come after 'start'");
                continue;
            }
            z.loop = c.bool("loop", c.has("loop_start") || c.has("loop_end"));
            z.loopStart = c.num("loop_start", 0);
            z.loopEnd = c.num("loop_end", 0);
            z.oneshot = c.bool("oneshot", false);
            z.reverse = c.bool("reverse", false);
            z.choke = <i32>c.num("choke", 0);
            if (z.loop && z.slices > 0) diagnostics.warning(c.line, c.node.col, c.node.endCol, "range", "slices do not loop; 'loop' is ignored");
            if (z.loop && z.oneshot) diagnostics.warning(c.line, c.node.col, c.node.endCol, "range", "a one-shot plays once; 'loop' is ignored");
            ownZones.push(z);
        } else if (n == "pitch_env") {
            def.pitchAmount = c.num("amount", 0);
            def.pitchDecay = c.num("decay", 0);
        } else if (n == "filter") {
            def.filterType = c.str("type", def.filterType == "off" ? "lowpass" : def.filterType);
            def.cutoff = c.num("cutoff", def.cutoff);
            def.res = c.num("res", def.res);
            def.filterEnvAmount = c.num("env", def.filterEnvAmount);
            def.keytrack = c.num("keytrack", def.keytrack);
            def.slope = <i32>c.num("slope", <f64>def.slope);
        } else if (n == "filter_env") {
            applyEnv(def.filterEnv, c);
        } else if (n == "drive") {
            def.drive = c.num("v", 0);
        } else if (n == "voice") {
            def.poly = <i32>c.num("poly", <f64>def.poly);
            def.mono = c.bool("mono", def.mono);
            def.glide = c.num("glide", def.glide);
            def.retrigger = c.bool("retrigger", def.retrigger);
            if (c.has("fixed")) {
                let f = c.get("fixed");
                def.fixedPitch = f.hasOctave ? f.num : 60 + f.num;
            }
        } else if (n == "defaults") {
            def.defaultVol = c.num("vol", def.defaultVol);
            def.defaultPan = c.num("pan", def.defaultPan);
            def.defaultDelay = c.num("delay", def.defaultDelay);
            def.defaultReverb = c.num("reverb", def.defaultReverb);
        } else if (n == "param") {
            let macroName = c.str("name", "");
            let targetName = c.str("target", "");
            let target = paramByName(targetName);
            if (target == null || target.scope == ParamScope.Conductor) {
                let v = c.get("target");
                diagnostics.error(c.line, v.col, v.endCol, "unknown-arg", `'${targetName}' is not a channel or instrument parameter`);
                continue;
            }
            if (paramByName(macroName) != null) {
                let v = c.get("name");
                diagnostics.error(c.line, v.col, v.endCol, "range", `'${macroName}' is already a built-in parameter`);
                continue;
            }
            def.macros.push(new Macro(macroName, target, c.num("min", NaN), c.num("max", NaN)));
        }
    }
    // An instrument that declares oscillators replaces the ones from its base.
    if (ownOscs.length > 0) def.oscs = ownOscs;
    if (ownZones.length > 0) {
        // Samples replace the base's sound too; oscillators the file declares
        // play along with them.
        def.zones = ownZones;
        if (ownOscs.length == 0) def.oscs = [];
        // Without an envelope, a sample plays as recorded.
        if (!envSet && !based) {
            def.amp.a = 0.001;
            def.amp.d = 0;
            def.amp.s = 1;
            def.amp.r = 0.05;
        }
    } else if (def.oscs.length == 0) {
        def.oscs.push(new OscDef());
    }
    return def;
}

// The instruments a song can select: every preset, then the song's own
// instruments, which replace presets of the same name.
export class InstrumentLibrary {
    names: Array<string> = [];
    sampleNames: Array<string> = []; // the song's samples, in bank order
    defs: Array<InstrumentDef> = [];
    presets: Map<string, InstrumentDef> = new Map<string, InstrumentDef>();

    preset(name: string): InstrumentDef? {
        if (this.presets.has(name)) return this.presets.get(name);
        if (!PRESET_NAMES.includes(name)) return null;
        let quiet = new Diagnostics("presets/" + name + ".inst");
        let file = checkSource(quiet.path, presetSource(name), FileKind.Instrument, new CheckContext());
        let def = buildInstrument(name, file, null, quiet);
        this.presets.set(name, def);
        return def;
    }

    indexOf(name: string): i32 {
        return this.names.indexOf(name);
    }

    def(index: i32): InstrumentDef {
        return this.defs[index];
    }

    add(def: InstrumentDef): void {
        let i = this.names.indexOf(def.name);
        if (i >= 0) {
            this.defs[i] = def;
        } else {
            this.names.push(def.name);
            this.defs.push(def);
        }
    }

    static forSong(song: Song, diagnostics: Map<string, Diagnostics>): InstrumentLibrary {
        let lib = new InstrumentLibrary();
        lib.sampleNames = song.sampleNames;
        for (let i = 0; i < PRESET_NAMES.length; i++) lib.add(lib.preset(PRESET_NAMES[i])!);
        for (let i = 0; i < song.instrumentNames.length; i++) {
            let name = song.instrumentNames[i];
            let file = song.instruments.get(name);
            let d = diagnosticsFor(diagnostics, file.path);
            lib.add(buildInstrument(name, file, lib, d));
        }
        return lib;
    }
}

export function diagnosticsFor(map: Map<string, Diagnostics>, path: string): Diagnostics {
    if (map.has(path)) return map.get(path);
    let d = new Diagnostics(path);
    map.set(path, d);
    return d;
}
