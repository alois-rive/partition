import { Tests } from "rive/test";
import { parseSongConfig } from "../lang/config";
import { decimals, gainDb, SettingsPanel } from "../editor/settings";
import { EditorView } from "../editor/view";

const YAML: string = "title: Demo\nbpm: 120\nsignature: 4/4\nrows_per_beat: 4\nchannels:\n  - name: kick\n    file: channels/kick.ch\n  - name: bass\n    file: channels/bass.ch\n";

@editTime
function panel(): SettingsPanel {
    let p = new SettingsPanel();
    p.load(YAML);
    return p;
}

export class SettingsTests extends Tests {
    override run(): void {
        group("settings", () => {
            test("typed values are checked like song.yaml", (expect) => {
                let p = panel();
                expect.that(p.commit("bpm", "128")).is(true);
                let written = p.takeYaml();
                expect.that(parseSongConfig(written).config.bpm).is(128);
                expect.that(p.commit("bpm", "5000")).is(false);
                expect.that(p.errorField).is("bpm");
                expect.that(p.takeYaml()).is("");
                expect.that(p.commit("rpb", "3")).is(true);
                expect.that(parseSongConfig(p.takeYaml()).config.rowsPerBeat).is(3);
            });
            test("steppers and the signature", (expect) => {
                let p = panel();
                p.step("sigNum", -1);
                p.config.sigDen = 8;
                p.write();
                let c = parseSongConfig(p.takeYaml()).config;
                expect.that(c.sigNum).is(3);
                expect.that(c.sigDen).is(8);
                p.step("bpm", 1);
                expect.that(parseSongConfig(p.takeYaml()).config.bpm).is(121);
            });
            test("tracks: rename, width, order, add and remove", (expect) => {
                let p = panel();
                expect.that(p.commit("trk:1:name", "kick")).is(false); // taken
                expect.that(p.commit("trk:1:name", "sub")).is(true);
                expect.that(p.commit("trk:1:width", "7")).is(false);
                expect.that(p.commit("trk:1:width", "40")).is(true);
                p.moveTrack(1, -1);
                let c = parseSongConfig(p.takeYaml()).config;
                expect.that(c.channels[0].name).is("sub");
                expect.that(c.channels[0].width).is(40);
                expect.that(c.channels[0].widthSet).is(true);
                p.addTrack();
                expect.that(p.takeActions().join("|")).is("trackAdd:channels/track_3.ch");
                expect.that(parseSongConfig(p.takeYaml()).config.channels.length).is(3);
                p.toggleTrack(0, false);
                expect.that(p.takeActions().join("|")).is("trackMix:channels/bass.ch:1:0");
                p.removeTrack(2);
                expect.that(p.takeActions().join("|")).is("trackDelete:channels/track_3.ch");
                c = parseSongConfig(p.takeYaml()).config;
                expect.that(c.channels.length).is(2);
                expect.that(c.channels[0].mute).is(true);
            });
            test("controls take clicks before anything is painted", (expect) => {
                let p = panel();
                p.layout(new EditorView(), 1000, 2000);
                let bpm = p.hitOf("bpm+");
                expect.that(bpm != null).is(true);
                p.pointerDown(bpm!.x + 2, bpm!.y + 2);
                expect.that(parseSongConfig(p.takeYaml()).config.bpm).is(121);
                let field = p.hitOf("title")!;
                p.pointerDown(field.x + 2, field.y + 2);
                expect.that(p.editing).is("title");
                p.key(259); // backspace
                p.typeText("s!");
                p.key(257); // enter
                expect.that(p.editing).is("");
                expect.that(parseSongConfig(p.takeYaml()).config.title).is("Dems!");
            });
            test("a song.yaml changed elsewhere reloads the form", (expect) => {
                let p = panel();
                p.load(YAML.replace("bpm: 120", "bpm: 90"));
                expect.that(p.valueOf("bpm")).is("90");
            });
            test("readouts", (expect) => {
                expect.that(decimals(0.125, 2)).is("0.13");
                expect.that(decimals(3, 2)).is("3");
                expect.that(gainDb(1)).is("0 dB");
                expect.that(gainDb(0)).is("-inf dB");
                expect.that(gainDb(2)).is("+6 dB");
            });
        });
    }
}
