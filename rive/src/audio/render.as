// Offline rendering (docs/spec.md §9.4): the same Engine the processor runs,
// driven as fast as the job's thread allows.

import { Blob, Snapshot } from "rive/shared";
import { Engine } from "../synth/engine";
import { encodeWav } from "./wav";

export class RenderSettings {
    sampleRate: f64 = 48000;
    duration: f64 = 0; // song seconds to render before the tail
    maxTail: f64 = 8;
    loopStart: f64 = -1; // looping is off in renders; the score is unrolled
}

export class RenderProgress {
    rendered: f64 = 0; // seconds written so far
    total: f64 = 0; // seconds expected, tail included at most
    done: f64 = 0;
}

export class WavSettings {
    format: i32 = 0;
    title: string = "";
    author: string = "";
}

// Renders a packed score to interleaved stereo f32 samples.
@job export function renderScore(events: Blob, instruments: Blob, settings: RenderSettings, progress: Snapshot<RenderProgress>): Blob {
    let out = renderSamples(events, instruments, settings, progress);
    return Blob.fromArray(out);
}

// Renders a packed score straight to the bytes of a WAV file.
@job export function renderWav(events: Blob, instruments: Blob, settings: RenderSettings, wav: WavSettings, progress: Snapshot<RenderProgress>): Blob {
    let out = renderSamples(events, instruments, settings, progress);
    let bytes = encodeWav(out, out.length / 2, 2, <i32>settings.sampleRate, wav.format, wav.title, wav.author);
    return Blob.fromArray(bytes);
}

function renderSamples(events: Blob, instruments: Blob, settings: RenderSettings, progress: Snapshot<RenderProgress>): Float32Array {
    let sr = settings.sampleRate;
    let engine = new Engine(sr, 2);
    engine.load(events, instruments, 0);
    engine.play();
    let songFrames = <i32>Math.ceil(settings.duration * sr);
    let maxFrames = songFrames + <i32>Math.ceil(settings.maxTail * sr);
    let out = new Float32Array(maxFrames * 2);
    let step = <i32>sr; // a second at a time, so progress moves
    let p = new RenderProgress();
    p.total = <f64>maxFrames / sr;
    let written = 0;
    while (written < maxFrames) {
        let n = min<i32>(step, maxFrames - written);
        engine.renderStereo(out, written, n);
        written += n;
        if (written >= songFrames && engine.silent) break;
        p.rendered = <f64>written / sr;
        progress.publish(p);
    }
    p.rendered = <f64>written / sr;
    p.done = 1;
    progress.publish(p);
    return out.subarray(0, written * 2);
}
