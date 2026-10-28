// The documentation panel's content (docs/spec.md §10.8): a short guide to the
// language, then every command from the registry with its signature, what it
// does and an example. The view lays it out and draws it.

import { registry } from "../lang/commands";
import { PRESET_NAMES } from "../score/instrument";

export enum DocKind {
    Title = 0,
    Heading,
    Paragraph,
    Code,
    Signature, // a command's signature; its name is the block's anchor
}

export class DocBlock {
    constructor(public kind: DocKind, public text: string, public anchor: string = "") {}
}

// An example for each command, shown under its signature.
function example(name: string): string {
    if (name == "note") return "note(p: C4, len: 1/8, vel: 0.9)\nnote(p: [C4, E4, G4], at: 0.5)";
    if (name == "chord") return "chord(root: A3, type: min9, inv: 1, strum: 20ms)";
    if (name == "cut") return "cut(fade: 1/16)";
    if (name == "inst") return "inst(name: organ_bass)";
    if (name == "oct") return "oct(v: 2); note(p: A)";
    if (name == "transpose") return "transpose(v: 5st)";
    if (name == "vel") return "vel(v: 70%)";
    if (name == "len") return "len(v: 1/16)";
    if (name == "vol") return "vol(v: -6dB)";
    if (name == "pan") return "pan(v: -0.3)";
    if (name == "set") return "set(cutoff: 1.2k, res: 0.3, reverb: 0.2)";
    if (name == "ramp") return "ramp(cutoff: 4k, over: 2bar, curve: exp)";
    if (name == "glide") return "glide(to: G4, over: 1b)";
    if (name == "lfo") return "lfo(param: cutoff, rate: 1bar, depth: 0.4, shape: tri)";
    if (name == "lfo_off") return "lfo_off(param: cutoff)";
    if (name == "pattern") return "pattern(name: four_floor, times: 8)";
    if (name == "stop") return "stop(id: hats)";
    if (name == "bpm") return "bpm(v: 128)";
    if (name == "sig") return "sig(v: 7/8)";
    if (name == "rpb") return "rpb(v: 2)";
    if (name == "swing") return "swing(v: 0.3)";
    if (name == "master") return "master(vol: -1dB)";
    if (name == "mark") return "mark(name: chorus)";
    if (name == "jump") return "jump(to: chorus, times: 1)";
    if (name == "end") return "end()";
    if (name == "base") return "base(preset: pad)";
    if (name == "osc") return "osc(wave: saw, level: 0.5, detune: 8c, unison: 3, spread: 12c)";
    if (name == "env") return "env(a: 5ms, d: 300ms, s: 0.6, r: 200ms)";
    if (name == "pitch_env") return "pitch_env(amount: 24st, decay: 40ms)";
    if (name == "filter") return "filter(type: lowpass, cutoff: 900, res: 0.3, env: 0.5)";
    if (name == "filter_env") return "filter_env(a: 1ms, d: 250ms, s: 0.1, r: 200ms)";
    if (name == "drive") return "drive(v: 0.4)";
    if (name == "voice") return "voice(mono: true, glide: 40ms)";
    if (name == "defaults") return "defaults(vol: 0.6, reverb: 0.3)";
    if (name == "param") return "param(name: brightness, target: cutoff, min: 300, max: 6k)";
    return "";
}

function commands(out: Array<DocBlock>, heading: string, intro: string, names: Array<string>): void {
    out.push(new DocBlock(DocKind.Heading, heading));
    if (intro.length > 0) out.push(new DocBlock(DocKind.Paragraph, intro));
    let reg = registry();
    for (let i = 0; i < names.length; i++) {
        let spec = reg.get(names[i]);
        if (spec == null) continue;
        out.push(new DocBlock(DocKind.Signature, spec.signature(), spec.name));
        out.push(new DocBlock(DocKind.Paragraph, spec.summary.charAt(0).toUpperCase() + spec.summary.substring(1) + "."));
        let ex = example(spec.name);
        if (ex.length > 0) out.push(new DocBlock(DocKind.Code, ex));
    }
}

export function docBlocks(): Array<DocBlock> {
    let out = new Array<DocBlock>();
    out.push(new DocBlock(DocKind.Title, "Partition"));
    out.push(new DocBlock(DocKind.Paragraph, "Each column is a track. Each line is one step in time, and holds commands that play notes or change the sound. Columns scroll together, so a line at the same height is the same moment in every track."));

    out.push(new DocBlock(DocKind.Heading, "Lines and rows"));
    out.push(new DocBlock(DocKind.Paragraph, "A row lasts 60 / (bpm × rows per beat) seconds. Commands on a row run left to right and are separated by ';'. An empty line is a rest. A line starting with a tab continues the row above: it is only a way to lay out long rows."));
    out.push(new DocBlock(DocKind.Code, "inst(name: stab); len(v: 1/8)\n\tset(delay: 0.3, reverb: 0.2)\nchord(root: A3, type: min9)\n\nchord(root: D3, type: min9)"));
    out.push(new DocBlock(DocKind.Paragraph, "Arguments are always named. A command with an error is skipped and the rest of the song keeps playing; the problem shows under the code and in the footer's Diagnostics."));

    out.push(new DocBlock(DocKind.Heading, "Values"));
    out.push(new DocBlock(DocKind.Paragraph, "Durations: 2 (rows), 1/8 (a note value), 1b (beats), 2bar (bars), 250ms or 1.5s. Gains: 0.8, 80% or -6dB. Frequencies: 440, 440Hz or 2k. Intervals: 7st or 25c. Pitches: C4, F#3, Bb2, a MIDI number such as 60, or C alone to use the octave set by oct()."));

    commands(out, "Notes", "", ["note", "chord", "cut"]);
    commands(out, "Track settings", "These last until changed, for every later command on the track.", ["inst", "oct", "transpose", "vel", "len", "vol", "pan", "set"]);
    commands(out, "Automation", "Ramps and LFOs work on vol, pan, delay, reverb and the instrument's parameters (cutoff, res, env, drive, attack, decay, sustain, release, pw, detune, oscN.level …).", ["ramp", "glide", "lfo", "lfo_off"]);
    out.push(new DocBlock(DocKind.Heading, "Pattern files", "patterns"));
    out.push(new DocBlock(DocKind.Paragraph, "A pattern is a phrase written once and played from any track. Each one is a file in patterns/, named by its file name (lowercase letters, digits and '_'). Edit them in the Patterns tab (Cmd+2): the list on the left adds, renames (F2 or double-click) and deletes them, and renaming updates every pattern(name: …) that calls it."));
    out.push(new DocBlock(DocKind.Paragraph, "A pattern is written exactly like a track: one row per line, with the song's rows per beat. Its length is its number of rows, trailing empty rows included, so a one-bar pattern in 4/4 at 4 rows per beat has 16 lines even if only the first holds a note."));
    out.push(new DocBlock(DocKind.Code, "note(p: C1)\n\n\n\nnote(p: C1)\n\n\n\nnote(p: C1)\n\n\n\nnote(p: C1, vel: 0.9)\n\n\n"));
    out.push(new DocBlock(DocKind.Paragraph, "A track plays it with pattern(name: …). The pattern starts on that row and plays on top of the track's own rows, which keep playing, so the grid never shifts. times: repeats it back to back; id: names the run so stop(id: …) can end it."));
    out.push(new DocBlock(DocKind.Code, "inst(name: kick_deep)\n\tpattern(name: four_floor, times: 8, id: kick)\n"));
    out.push(new DocBlock(DocKind.Paragraph, "Each run starts from a copy of the calling track's settings (instrument, octave, velocity, length, vol…). Changes the pattern makes stay inside the run and never leak back to the track, and each repetition starts again from the call. So a track's ramp or LFO reaches only patterns called after it: put the automation before the call on the same row."));
    out.push(new DocBlock(DocKind.Paragraph, "Patterns can call patterns, up to 8 deep; a pattern that leads back to itself is reported and skipped. A pattern can set its own instrument with inst(…), or use the calling track's. Pitches written without an octave (C, Eb) use the octave set by oct(…), so one pattern plays in any register."));
    out.push(new DocBlock(DocKind.Paragraph, "In the Patterns tab, Play (or Cmd+Enter) plays only the selected pattern, on a loop, with the instrument of the first track that calls it. Edits are heard as you type."));
    commands(out, "Pattern commands", "", ["pattern", "stop"]);
    commands(out, "Conductor", "These go in the conductor, the first column, and act on the whole song.", ["bpm", "sig", "rpb", "swing", "master", "mark", "jump", "end"]);
    out.push(new DocBlock(DocKind.Heading, "Instrument files", "instruments"));
    out.push(new DocBlock(DocKind.Paragraph, "An instrument describes a sound. Each one is a file in instruments/, named by its file name, and a track selects it with inst(name: …) (or a single note with note(…, inst: …)). Edit them in the Instruments tab (Cmd+3): the list adds, renames and deletes them, and renaming updates every inst(…) that uses it. Play there loops a short example track (an arpeggio, a chord, a low line) on the selected instrument."));
    out.push(new DocBlock(DocKind.Paragraph, "An instrument file is a list of commands, read top to bottom (rows mean nothing here). Start from a preset with base(preset: …), then change what you need. Built-in presets: " + PRESET_NAMES.join(", ") + "."));
    out.push(new DocBlock(DocKind.Code, "base(preset: pad)\nosc(wave: saw, level: 0.5, detune: -8c, unison: 3, spread: 12c)\nosc(wave: saw, level: 0.5, detune: 8c, unison: 3, spread: 12c)\nosc(wave: sine, oct: -1, level: 0.3)\nenv(a: 400ms, d: 1s, s: 0.7, r: 2s)\nfilter(type: lowpass, cutoff: 1.4k, res: 0.2, env: 0.3, keytrack: 0.5)\nfilter_env(a: 600ms, d: 2s, s: 0.4, r: 2s)\nvoice(poly: 8)\ndefaults(vol: 0.6, reverb: 0.4)\nparam(name: brightness, target: cutoff, min: 300, max: 6k)"));
    out.push(new DocBlock(DocKind.Paragraph, "The voice: up to four oscillators (osc), each adding to the sound; if the file declares any, they replace the preset's. FM uses the previous oscillator as modulator (fm: index, ratio: its frequency ratio). env shapes the volume (attack, decay, sustain, release; burst: repeats the first hit, for claps). pitch_env drops the pitch at the start (kicks, toms). filter and filter_env shape the tone; keytrack opens the filter for higher notes. drive adds saturation."));
    out.push(new DocBlock(DocKind.Paragraph, "voice sets how notes share voices: poly (how many at once), mono with glide (legato slides), and fixed: a pitch every note plays at (drums). defaults gives the track vol, pan and send values the first time the instrument is selected."));
    out.push(new DocBlock(DocKind.Paragraph, "param adds a knob of your own: set(brightness: 0.5) or ramp(brightness: 1, over: 4bar) on a track moves its target between min and max. Tracks can also set the instrument's own parameters directly: cutoff, res, env, keytrack, drive, glide, attack, decay, sustain, release, pw, detune, and oscN.level, oscN.detune, oscN.pw, oscN.fm for oscillator N."));
    commands(out, "Instrument commands", "", ["base", "osc", "env", "pitch_env", "filter", "filter_env", "drive", "voice", "defaults", "param"]);

    out.push(new DocBlock(DocKind.Heading, "The overview strip"));
    out.push(new DocBlock(DocKind.Paragraph, "The strip at the left of each track draws every command on the same time grid: notes as lines placed by pitch, patterns as a bar on the left edge, ramps as wedges, LFOs as waves. Collapse a track to keep only its strip; collapse all to see the whole song at once."));

    out.push(new DocBlock(DocKind.Heading, "Song settings", "settings"));
    out.push(new DocBlock(DocKind.Paragraph, "song.yaml holds what is true of the whole song: its title and author, the tempo, signature, rows per beat and swing it starts with, the master volume, and the list of tracks. The Settings tab (Cmd+, or the cog at the bottom of the rail) edits it as a form; every change is checked, then written back to song.yaml at once, so the song plays with it while you edit."));
    out.push(new DocBlock(DocKind.Code, "title: Late Night\nauthor: Me\nbpm: 122\nsignature: 4/4\nrows_per_beat: 4\nswing: 0.1\nmaster_volume: 0.9\nchannels:\n  - name: kick\n    file: channels/kick.ch\n  - name: bass\n    file: channels/bass.ch\n    width: 40\n    mute: true"));
    out.push(new DocBlock(DocKind.Paragraph, "bpm is 20 to 999; signature is 1 to 32 beats over 1, 2, 4, 8, 16 or 32; rows_per_beat is 1 to 64 (with 4 in 4/4, each line is a 1/16 note); swing is 0 to 0.75; master_volume is a gain from 0 to 4 (or in dB, as -3dB). These are where the song starts: bpm(), sig(), rpb(), swing() and master() in the conductor change them as it plays."));
    out.push(new DocBlock(DocKind.Paragraph, "Each track has a file in channels/ and a name shown in its header; width sets its column in characters (sized to the text when left out), and mute and solo set how it starts. In the Settings tab, tracks can be renamed, reordered, added (with a new empty file) and removed (with their file, after a second click)."));

    out.push(new DocBlock(DocKind.Heading, "Tabs"));
    out.push(new DocBlock(DocKind.Paragraph, "The rail on the left switches between Tracks (Cmd+1), Patterns (Cmd+2), Instruments (Cmd+3) and Song settings (Cmd+4 or Cmd+,); hold the pointer on an icon for its name. In Patterns and Instruments, the list picks the file to edit and Play plays only that file."));

    out.push(new DocBlock(DocKind.Heading, "Keyboard"));
    out.push(new DocBlock(DocKind.Paragraph, "Cmd+Enter play / pause · Cmd+Shift+Enter play from the cursor · Alt+Enter play the cursor's row · Cmd+. stop · Cmd+L loop the selection or bar · Cmd+M mute · Cmd+Shift+S solo · Cmd+E collapse the track · Cmd+Shift+E collapse all · Cmd+= / Cmd+- zoom the collapsed view · Cmd+[ / Cmd+] previous / next track · Cmd+D duplicate row · Alt+Up / Down move row · Cmd+Z / Cmd+Shift+Z undo / redo · Cmd+1 / 2 / 3 / 4 tabs (Cmd+, settings) · F2 rename the selected pattern or instrument · Cmd+/ or F1 this panel."));
    return out;
}
