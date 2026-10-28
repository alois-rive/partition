// The example songs bundled with the program (docs/spec.md §16). Each one is
// a `.song` bundle declared as a blob asset named `example-<id>` in scene.rml.

import { Buffer } from "rive/buffer";
import { Bundle, parseBundle } from "../lang/bundle";

export class ExampleInfo {
    constructor(
        public id: string,
        public title: string,
        public description: string,
        public bpm: f64,
        public genre: string,
    ) {}

    get blobName(): string {
        return "example-" + this.id;
    }
}

export function examples(): Array<ExampleInfo> {
    return [
        new ExampleInfo("empty", "Empty song", "A conductor and four empty channels", 120, "template"),
        new ExampleInfo("deep-house", "Late Night Deep House", "Four-on-the-floor, organ bass, minor-nine stabs with delay, a breakdown", 122, "deep house"),
        new ExampleInfo("lofi", "Rainy Lo-Fi", "Swung drums, e-piano chords strummed, vinyl noise", 84, "lo-fi hip hop"),
        new ExampleInfo("techno", "Warehouse", "Acid bass under an LFO, long ramps, endless loop", 132, "techno"),
        new ExampleInfo("ambient", "Drift", "Long pads in reverb, slow glides", 70, "ambient"),
        new ExampleInfo("chiptune", "Pixel Quest", "Pulse leads, arpeggio patterns, square bass", 150, "chiptune"),
        new ExampleInfo("jazz", "Blue Hour", "Swung piano trio: ii–V–I changes, walking bass, brushed drums", 140, "jazz"),
        new ExampleInfo("bossa", "Copacabana Night", "Bossa nova clave, nylon-like plucked maj7 chords, soft bass", 128, "bossa nova"),
        new ExampleInfo("dnb", "Liquid Circuit", "174 bpm breakbeats with ghost notes, a reese bass and liquid pads", 174, "drum & bass"),
        new ExampleInfo("synthwave", "Neon Freeway", "Retro arps, supersaw chords, gated snare and a gliding lead", 100, "synthwave"),
        new ExampleInfo("trance", "Euphoria", "Rolling supersaw arps, offbeat bass, a long filtered build and drop", 138, "trance"),
        new ExampleInfo("dub-techno", "Deep Fog", "Echoing chord stabs in endless delay over a soft pulse", 120, "dub techno"),
        new ExampleInfo("invention", "Two-Part Invention", "Baroque counterpoint in C minor: a subject, sequences, imitation", 84, "baroque"),
        new ExampleInfo("waltz", "Paper Lanterns", "A 3/4 waltz: oom-pah-pah bass, strings, music-box bells", 156, "waltz"),
        new ExampleInfo("seven-steps", "Seven Steps", "Odd meters: 7/8 riffs, a 5/4 bridge, organ and lead", 132, "progressive"),
        new ExampleInfo("funk", "Slick", "Tight funk: popping bass, clavinet riff, horn stabs, ghost notes", 104, "funk"),
        new ExampleInfo("trap", "Midnight Drip", "Half-time trap: 808 glides, hi-hat rolls, dark bells", 140, "trap"),
        new ExampleInfo("garage", "2-Step Sunday", "UK garage shuffle, organ stabs, chopped vocal-like plucks", 132, "uk garage"),
        new ExampleInfo("boss-battle", "Final Gate", "Chiptune boss fight: chromatic riffs, meter changes, accelerando", 168, "game music"),
        new ExampleInfo("tidal", "Tidal", "Generative ambient: patterns of 5, 7 and 11 rows drifting in and out of phase", 60, "ambient"),
        new ExampleInfo("disco", "Mirrorball", "Octave bass, string stabs, open hats and a filter sweep", 120, "disco"),
        new ExampleInfo("reggae", "Island Drift", "One-drop rhythm, offbeat skank, bubbling organ, deep bass", 76, "reggae"),
    ];
}

export function exampleInfo(id: string): ExampleInfo? {
    let all = examples();
    for (let i = 0; i < all.length; i++) if (all[i].id == id) return all[i];
    return null;
}

// Decodes an example's bundle from the bytes of its blob asset.
export function exampleBundle(id: string, bytes: ArrayBuffer): Bundle {
    return parseBundle(`example-${id}.song`, Buffer.tostring(bytes));
}
