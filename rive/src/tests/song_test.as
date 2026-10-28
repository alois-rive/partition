import { Expect, Tests } from "rive/test";
import { parseYaml, YamlKind } from "../lang/yaml";
import { parseSongConfig, songConfigText } from "../lang/config";
import { packBundle, packProblem, parseBundle, SongFile } from "../lang/bundle";
import { Song } from "../lang/song";

const SONG_YAML_TEXT = `title: Late Night Deep House
author: someone   # trailing comment
bpm: 122
signature: 4/4
rows_per_beat: 4
swing: 0.1
master_volume: -1dB
channels:
  - name: kick
    file: channels/kick.ch
    width: 28
    mute: false
  - file: channels/bass.ch
    solo: true
`;

@editTime
function near(expect: Expect, got: f64, want: f64): void {
    expect.that(Math.abs(got - want) < 1e-6).is(true);
}

export class SongTests extends Tests {
    override run(): void {
        group("yaml", () => {
            test("maps, lists and scalars", (expect) => {
                let doc = parseYaml("song.yaml", SONG_YAML_TEXT);
                expect.that(doc.diagnostics.length).is(0);
                let root = doc.root;
                expect.that(root.kind == YamlKind.Map).is(true);
                expect.that(root.get("author")!.text).is("someone");
                let channels = root.get("channels")!;
                expect.that(channels.kind == YamlKind.List).is(true);
                expect.that(channels.items.length).is(2);
                expect.that(channels.items[0].get("width")!.text).is("28");
                expect.that(channels.items[1].get("file")!.text).is("channels/bass.ch");
            });
            test("list at the same indent as its key", (expect) => {
                let doc = parseYaml("song.yaml", "channels:\n- file: a.ch\n- file: b.ch\ntitle: x\n");
                expect.that(doc.diagnostics.length).is(0);
                expect.that(doc.root.get("channels")!.items.length).is(2);
                expect.that(doc.root.get("title")!.text).is("x");
            });
            test("nested maps and scalar lists", (expect) => {
                let doc = parseYaml("t.yaml", "a:\n  b: 1\n  c:\n    - x\n    - \"y # not a comment\"\n");
                expect.that(doc.diagnostics.length).is(0);
                let c = doc.root.get("a")!.get("c")!;
                expect.that(c.items.length).is(2);
                expect.that(c.items[1].text).is("y # not a comment");
                expect.that(c.items[1].quoted).is(true);
            });
            test("unsupported and broken input", (expect) => {
                expect.that(parseYaml("t", "a: [1, 2]\n").diagnostics.codes()).is("yaml");
                expect.that(parseYaml("t", "a: &x 1\n").diagnostics.codes()).is("yaml");
                expect.that(parseYaml("t", "a: |\n  text\n").diagnostics.length).greaterThan(0);
                expect.that(parseYaml("t", "a: 1\n\tb: 2\n").diagnostics.codes()).is("yaml");
                expect.that(parseYaml("t", "a: 1\na: 2\n").diagnostics.codes()).is("yaml");
                expect.that(parseYaml("t", "a: \"open\n").diagnostics.codes()).is("yaml");
                expect.that(parseYaml("t", "just text\n").diagnostics.codes()).is("yaml");
            });
        });

        group("config", () => {
            test("reads every key", (expect) => {
                let r = parseSongConfig(SONG_YAML_TEXT);
                expect.that(r.diagnostics.length).is(0);
                let c = r.config;
                expect.that(c.title).is("Late Night Deep House");
                expect.that(c.bpm).is(122);
                expect.that(c.sigNum).is(4);
                expect.that(c.rowsPerBeat).is(4);
                near(expect, c.swing, 0.1);
                near(expect, c.masterVolume, 0.8912509381337456);
                expect.that(c.channels.length).is(2);
                expect.that(c.channels[0].width).is(28);
                expect.that(c.channels[1].name).is("bass");
                expect.that(c.channels[1].solo).is(true);
            });
            test("bad values keep defaults and report", (expect) => {
                let r = parseSongConfig("bpm: fast\nsignature: 4/3\nrows_per_beat: 2.5\nchannels:\n  - name: x\ncolour: red\n");
                expect.that(r.diagnostics.codes()).is("config,config,config,config,config");
                expect.that(r.config.bpm).is(120);
                expect.that(r.config.sigDen).is(4);
                expect.that(r.config.channels.length).is(0);
            });
            test("duplicate channel names", (expect) => {
                let r = parseSongConfig("channels:\n  - file: a/x.ch\n  - file: b/x.ch\n");
                expect.that(r.diagnostics.codes()).is("config");
                expect.that(r.config.channels.length).is(1);
            });
            test("round trip", (expect) => {
                let r = parseSongConfig(SONG_YAML_TEXT);
                let again = parseSongConfig(songConfigText(r.config));
                expect.that(again.diagnostics.length).is(0);
                expect.that(again.config.title).is(r.config.title);
                expect.that(again.config.channels[0].width).is(28);
                expect.that(again.config.channels[1].solo).is(true);
                near(expect, again.config.masterVolume, r.config.masterVolume);
            });
        });

        group("bundle", () => {
            test("parse", (expect) => {
                let b = parseBundle("x.song", "%partition-bundle 1\n=== song.yaml\ntitle: x\n=== channels/kick.ch\nnote(p: C1)\n\n\tvol(v: 1)\n=== empty.ch\n");
                expect.that(b.diagnostics.length).is(0);
                expect.that(b.files.length).is(3);
                expect.that(b.files[1].path).is("channels/kick.ch");
                expect.that(b.files[1].text).is("note(p: C1)\n\n\tvol(v: 1)\n");
                expect.that(b.files[2].text).is("");
            });
            test("round trip", (expect) => {
                let files = [new SongFile("song.yaml", "title: x\n"), new SongFile("a.ch", "\n\nnote(p: C4)\n")];
                expect.that(packProblem(files)).is("");
                let b = parseBundle("x.song", packBundle(files));
                expect.that(b.files.length).is(2);
                expect.that(b.files[1].text).is("\n\nnote(p: C4)\n");
            });
            test("errors", (expect) => {
                expect.that(parseBundle("x", "nope\n").diagnostics.codes()).is("bundle");
                expect.that(parseBundle("x", "%partition-bundle 1\nstray\n").diagnostics.codes()).is("bundle");
                expect.that(parseBundle("x", "%partition-bundle 1\n=== ../x\n").diagnostics.codes()).is("bundle");
                expect.that(parseBundle("x", "%partition-bundle 1\n=== a\n=== a\n").diagnostics.codes()).is("bundle");
                expect.that(packProblem([new SongFile("a", "=== b\n")]).length).greaterThan(0);
            });
        });

        group("song", () => {
            test("loads every kind of file", (expect) => {
                let song = Song.fromFiles([
                    new SongFile("song.yaml", "channels:\n  - file: channels/lead.ch\n  - file: channels/missing.ch\n"),
                    new SongFile("conductor.ch", "mark(name: intro)\n"),
                    new SongFile("channels/lead.ch", "inst(name: warm)\nset(brightness: 0.4)\n"),
                    new SongFile("instruments/warm.inst", "base(preset: pad)\nparam(name: brightness, target: cutoff, min: 200, max: 8k)\n"),
                    new SongFile("patterns/hats.pat", "note(p: C1)\n\n"),
                ]);
                expect.that(song.channels.length).is(2);
                expect.that(song.instrumentNames.join(",")).is("warm");
                expect.that(song.patternNames.join(",")).is("hats");
                expect.that(song.patterns.get("hats").rowCount).is(2);
                expect.that(song.conductor.rowCount).is(1);
                let all = song.diagnostics();
                expect.that(all.length).is(1);
                expect.that(all[0].code).is("missing-file");
                expect.that(song.rowCount).is(2);
            });
            test("editing a file re-checks only what it affects", (expect) => {
                let song = Song.fromFiles([
                    new SongFile("song.yaml", "channels:\n  - file: a.ch\n"),
                    new SongFile("a.ch", "set(brightness: 0.5)\n"),
                ]);
                expect.that(song.errorCount).is(1);
                song.setFile("instruments/x.inst", "param(name: brightness, target: cutoff)\n");
                expect.that(song.errorCount).is(0);
                song.setFile("a.ch", "nte(p: C4)\n");
                expect.that(song.errorCount).is(1);
                expect.that(song.checked("a.ch")!.diagnostics.codes()).is("unknown-command");
                song.removeFile("instruments/x.inst");
                expect.that(song.paths.length).is(2);
            });
            test("no song.yaml", (expect) => {
                let song = Song.fromFiles([]);
                expect.that(song.diagnostics()[0].code).is("missing-file");
                expect.that(song.config.bpm).is(120);
            });
        });
    }
}
