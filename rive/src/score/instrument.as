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
export function buildInstrument(name: string, file: CheckedFile, library: InstrumentLibrary?, diagnostics: Diagnostics): InstrumentDef {
    let def = new InstrumentDef();
    def.name = name;
    let commands = file.commands();
    let ownOscs = new Array<OscDef>();
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
    if (def.oscs.length == 0) def.oscs.push(new OscDef());
    return def;
}

// The instruments a song can select: every preset, then the song's own
// instruments, which replace presets of the same name.
export class InstrumentLibrary {
    names: Array<string> = [];
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
