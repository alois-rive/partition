// Sound design (docs/spec.md §7.6): the modulation matrix's sources and
// destinations, the built-in wavetables and the tunings, by name and id.

export const MOD_SOURCES: Array<string> = ["env", "env2", "lfo1", "lfo2", "vel", "key", "random", "press", "bend"];
export const SRC_ENV: i32 = 0;
export const SRC_ENV2: i32 = 1;
export const SRC_LFO1: i32 = 2;
export const SRC_LFO2: i32 = 3;
export const SRC_VEL: i32 = 4;
export const SRC_KEY: i32 = 5;
export const SRC_RANDOM: i32 = 6;
export const SRC_PRESS: i32 = 7;
export const SRC_BEND: i32 = 8;

// Units: pitch and detune in semitones, cutoff in octaves, level as a gain
// factor (1 + amount × source), the rest in their own units.
export const MOD_DESTS: Array<string> = ["pitch", "cutoff", "res", "level", "pan", "pw", "pos", "drive", "fm", "width"];
export const DST_PITCH: i32 = 0;
export const DST_CUTOFF: i32 = 1;
export const DST_RES: i32 = 2;
export const DST_LEVEL: i32 = 3;
export const DST_PAN: i32 = 4;
export const DST_PW: i32 = 5;
export const DST_POS: i32 = 6;
export const DST_DRIVE: i32 = 7;
export const DST_FM: i32 = 8;
export const DST_WIDTH: i32 = 9;
export const MAX_MODS: i32 = 8;

// Built-in wavetables (synth/wavetable.as); a sample's name is a table too.
export const TABLES: Array<string> = ["basic", "harmonic", "formant", "pwm"];

export const TUNINGS: Array<string> = ["equal", "just", "pythagorean", "meantone", "edo"];
