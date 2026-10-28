import { Tests } from "rive/test";
import { SongFile } from "../lang/bundle";
import { Song } from "../lang/song";
import { compileSong, CompileOptions, Score } from "../score/compiler";
import { EventKind } from "../score/events";
import { jsonString } from "../app/app";

// 120 bpm, 4 rows per beat: a row is 0.125 s.
const YAML = "bpm: 120\nrows_per_beat: 4\nchannels:\n  - file: a.ch\n";

@editTime
function cut(channel: string, endRow: i32, conductor: string = ""): Score {
    let files = [new SongFile("song.yaml", YAML), new SongFile("conductor.ch", conductor), new SongFile("a.ch", channel)];
    let o = new CompileOptions();
    o.endRow = endRow;
    return compileSong(Song.fromFiles(files), o);
}

@editTime
function count(score: Score, kind: EventKind): i32 {
    let n = 0;
    for (let i = 0; i < score.events.length; i++) if (score.events[i].kind == kind) n++;
    return n;
}

export class HostTests extends Tests {
    override run(): void {
        group("shell bridge", () => {
            test("JSON strings escape what a log line cannot hold", (expect) => {
                expect.that(jsonString("plain")).is("\"plain\"");
                expect.that(jsonString("a\"b\\c")).is("\"a\\\"b\\\\c\"");
                expect.that(jsonString("x\n\ty\r")).is("\"x\\n\\ty\\r\"");
                expect.that(jsonString(String.fromCharCode(1))).is("\"\\u0001\"");
                expect.that(jsonString("é ♪")).is("\"é ♪\"");
            });
            test("an end row cuts the song and releases held notes there", (expect) => {
                let channel = "note(p: C4, len: 8)\n\n\n\nnote(p: E4)\n\n\n\nnote(p: G4)\n";
                let whole = cut(channel, -1);
                expect.that(count(whole, EventKind.NoteOn)).is(3);
                let part = cut(channel, 3);
                expect.that(count(part, EventKind.NoteOn)).is(1);
                expect.that(part.duration).is(0.5); // rows 0–3
                for (let i = 0; i < part.events.length; i++) {
                    let e = part.events[i];
                    if (e.kind == EventKind.NoteOff) expect.that(e.time <= 0.5).is(true);
                }
            });
            test("an end row past the end changes nothing", (expect) => {
                let channel = "note(p: C4)\n";
                expect.that(cut(channel, 100).duration).is(cut(channel, -1).duration);
            });
            test("an end row before an endless loop drops the loop", (expect) => {
                let conductor = "mark(name: a)\n\n\n\njump(to: a)\n";
                let looped = cut("note(p: C4)\n", -1, conductor);
                expect.that(looped.loopStart >= 0).is(true);
                let part = cut("note(p: C4)\n", 1, conductor);
                expect.that(part.loopStart).is(-1);
                expect.that(part.duration).is(0.25);
            });
        });
    }
}
