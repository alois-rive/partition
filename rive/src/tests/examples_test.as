import { Expect, Tests } from "rive/test";
import { exampleBundle, ExampleInfo, examples } from "../app/examples";
import { packScore } from "../audio/pack";
import { Song } from "../lang/song";
import { compileSong, Score } from "../score/compiler";
import { EventKind } from "../score/events";
import { Engine } from "../synth/engine";
import { Blob } from "rive/shared";
import { buildBank } from "../synth/samples";

const SR: f64 = 48000;

// Where each example's offline check starts: a point inside its main section.
@editTime
function probeTime(id: string, duration: f64): f64 {
    if (id == "deep-house") return 30;
    if (id == "lofi") return 20;
    if (id == "techno") return 40;
    if (id == "ambient") return 20;
    if (id == "chiptune") return 10;
    return Math.floor(duration * 0.4);
}

@editTime
function problems(score: Score): string {
    let out = "";
    for (let i = 0; i < score.diagnostics.length; i++) out += score.diagnostics[i].toString() + "\n";
    return out;
}

@editTime
function compileExample(expect: Expect, info: ExampleInfo, bytes: ArrayBuffer?): Score? {
    expect.that(bytes != null).is(true);
    if (bytes == null) return null;
    let bundle = exampleBundle(info.id, bytes);
    expect.that(bundle.diagnostics.codes()).is("");
    let score = compileSong(Song.fromFiles(bundle.files));
    expect.that(problems(score)).is("");
    return score;
}

@editTime
function checkRender(expect: Expect, score: Score, bank: Blob?, from: f64, seconds: f64): void {
    let packed = packScore(score);
    let engine = new Engine(SR, 2);
    engine.attachSamples(bank);
    engine.load(packed.events, packed.instruments, from);
    engine.play();
    let frames = <i32>(seconds * SR);
    let out = new Float32Array(frames * 2);
    engine.renderStereo(out, 0, frames);
    let finite = true;
    let peak = 0.0;
    let sum = 0.0;
    for (let i = 0; i < out.length; i++) {
        let x = <f64>out[i];
        if (!isFinite(x)) finite = false;
        peak = Math.max(peak, Math.abs(x));
        sum += x * x;
    }
    let rms = Math.sqrt(sum / <f64>out.length);
    expect.that(finite).is(true);
    expect.that(peak).greaterThan(0.05);
    expect.that(peak).lessThanOrEqual(0.9661);
    expect.that(rms).greaterThan(0.01);
    packed.release();
}

export class ExampleSongTests extends Tests {
    override run(): void {
        let all = examples();
        for (let i = 0; i < all.length; i++) {
            let info = all[i];
            group(info.id, () => {
                test("compiles with no diagnostics", (expect) => {
                    let score = compileExample(expect, info, this.blob(info.blobName));
                    if (score == null || info.id == "empty") return;
                    expect.that(score.duration).greaterThan(30);
                    expect.that(score.duration).lessThan(420); // up to 7 minutes (Ultimate runs 6)
                    expect.that(score.count(EventKind.NoteOn)).greaterThan(0);
                });
                if (info.id != "empty") {
                    test("renders a lively, bounded slice", (expect) => {
                        let bytes = this.blob(info.blobName);
                        let score = compileExample(expect, info, bytes);
                        if (score == null || bytes == null) return;
                        // The example's samples, decoded as the app does (most examples have none).
                        let song = Song.fromFiles(exampleBundle(info.id, bytes).files);
                        let result = buildBank(song.sampleTexts());
                        let errors = result.errors.join("");
                        expect.that(errors).is("");
                        checkRender(expect, score, result.bank, probeTime(info.id, score.duration), 4);
                    });
                }
            });
        }
    }
}
