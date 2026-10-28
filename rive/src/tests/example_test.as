import { Tests } from "rive/test";
import { packBundle, parseBundle, SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong } from "../score/compiler";
import { EventKind } from "../score/events";

@editTime
function blank(n: i32): string {
    let out = "";
    for (let i = 0; i < n; i++) out += "\n";
    return out;
}

// A cut-down deep-house song in the shape of docs/spec.md §16.1.
@editTime
function deepHouse(): Array<SongFile> {
    let four = "note(p: C1)\n" + blank(3) + "note(p: C1)\n" + blank(3) + "note(p: C1)\n" + blank(3) + "note(p: C1)\n" + blank(3);
    return [
        new SongFile("song.yaml", "title: Late Night Deep House\nbpm: 122\nsignature: 4/4\nrows_per_beat: 4\nchannels:\n  - file: channels/kick.ch\n  - file: channels/bass.ch\n  - file: channels/chords.ch\n"),
        new SongFile("conductor.ch", "mark(name: intro)\n" + blank(31) + "mark(name: groove)\n" + blank(31) + "jump(to: groove, times: 1)\nmark(name: breakdown)\n\tramp(master: -3dB, over: 2bar)\n" + blank(31) + "end()\n"),
        new SongFile("patterns/four_floor.pat", four),
        new SongFile("channels/kick.ch", "inst(name: kick_deep); vol(v: 0.9)\n\tpattern(name: four_floor, times: 4)\n"),
        new SongFile("channels/bass.ch", "inst(name: organ_bass); len(v: 1/16); vel(v: 0.7); oct(v: 2)\n\tset(cutoff: 600, res: 0.25)\n\n\nnote(p: A)\n\n\n\nnote(p: A); vel(v: 0.9)\nramp(cutoff: 1.8k, over: 4bar, curve: exp)\n"),
        new SongFile("channels/chords.ch", "inst(name: stab); set(delay: 0.35, reverb: 0.3); len(v: 1/8)\n\tlfo(param: cutoff, rate: 2bar, depth: 0.4)\n" + blank(15) + "chord(root: A3, type: min9, inv: 1)\n" + blank(15) + "chord(root: D3, type: min9)\n"),
    ];
}

export class ExampleTests extends Tests {
    override run(): void {
        test("the spec's deep-house excerpt compiles cleanly", (expect) => {
            let score = compileSong(Song.fromFiles(deepHouse()));
            let problems = "";
            for (let i = 0; i < score.diagnostics.length; i++) problems += score.diagnostics[i].toString() + "\n";
            expect.that(problems).is("");
            // intro 32 + groove 33 twice + breakdown 33 rows
            expect.that(score.playback.count).is(32 + 33 * 2 + 33);
            expect.that(score.playback.ended).is(true);
            expect.that(score.count(EventKind.NoteOn)).greaterThan(16);
            expect.that(score.duration).greaterThan(60.0 / 122 / 4 * 131 - 1e-9);
        });
        test("it survives a bundle round trip", (expect) => {
            let bundle = parseBundle("deep-house.song", packBundle(deepHouse()));
            expect.that(bundle.diagnostics.length).is(0);
            let score = compileSong(Song.fromFiles(bundle.files));
            expect.that(score.diagnostics.length).is(0);
        });
    }
}
