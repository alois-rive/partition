// M0 spike: checks the platform assumptions listed in docs/spec.md §17.
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { KeyboardEvent, TextInput } from "rive/events";
import { Buffer } from "rive/buffer";
import { Blob } from "rive/shared";
import { Job, Jobs } from "rive/jobs";
import { Audio, AudioHandle, AudioProcessor } from "rive/audio";
import { Snapshot } from "rive/shared";

// Renders `seconds` of a 440 Hz sine at 48 kHz mono into a blob of f32.
@job export function renderSine(seconds: f64): Blob {
    let frames = <i32>(seconds * 48000);
    let out = new Float32Array(frames);
    let phase = 0.0;
    for (let i = 0; i < frames; i++) {
        out[i] = <f32>(Math.sin(phase) * 0.25);
        phase += 2 * Math.PI * 440 / 48000;
    }
    return Blob.fromArray(out);
}

export class Load {
    voices: i32 = 0;
}

// A stress processor: `voices` naive saw oscillators with a one-pole filter each.
export class Stress extends AudioProcessor<Snapshot<Load>> {
    load: Snapshot<Load>? = null;
    current: Load = new Load();
    phases: StaticArray<f32> = new StaticArray<f32>(256);
    lp: StaticArray<f32> = new StaticArray<f32>(256);
    steps: StaticArray<f32> = new StaticArray<f32>(256);
    channels: i32 = 2;

    override init(sampleRate: f64, maxFrames: i32, channels: i32, load: Snapshot<Load>): void {
        this.load = load;
        this.channels = channels;
        for (let v = 0; v < 256; v++) {
            this.steps[v] = <f32>((55 + v * 3.7) / sampleRate);
        }
    }

    @unchecked
    override process(out: StaticArray<f32>, frames: i32, startFrame: f64): void {
        this.load!.latestInto(this.current);
        let voices = min<i32>(this.current.voices, 256);
        if (voices <= 0) return;
        let channels = this.channels;
        let gain = <f32>(0.5 / <f32>voices);
        for (let i = 0; i < frames; i++) {
            let sum: f32 = 0;
            for (let v = 0; v < voices; v++) {
                let p = this.phases[v] + this.steps[v];
                if (p >= 1) p -= 1;
                this.phases[v] = p;
                let saw = p * 2 - 1;
                let y = this.lp[v] + (saw - this.lp[v]) * 0.2;
                this.lp[v] = y;
                sum += y;
            }
            let s = sum * gain;
            for (let c = 0; c < channels; c++) out[i * channels + c] = s;
        }
    }
}

export class Spike extends Layout {
    context: Context? = null;
    job: Job<Blob>? = null;
    load: Snapshot<Load> = Snapshot.create<Load>();
    handle: AudioHandle? = null;
    keys: string = "";
    lastVoices: f64 = -1;

    override init(context: Context): bool {
        this.context = context;
        this.checkBlob(context, "example-a");
        this.checkBlob(context, "songs/example-a");
        this.checkBlob(context, "top");
        this.checkBlob(context, "top.txt");

        let vm = context.viewModel();
        if (vm != null) {
            let go = vm.getTrigger("go");
            if (go != null) {
                go.addListener(() => { this.startRender(); });
                context.log("m0: listening on trigger go");
            }
        } else {
            context.log("m0: no view model bound");
        }
        this.handle = Audio.start(() => new Stress(), this.load);
        context.log(`m0: audio sampleRate ${Audio.sampleRate()}`);
        return true;
    }

    checkBlob(context: Context, name: string): void {
        let bytes = context.blob(name);
        if (bytes == null) {
            context.log(`m0: blob '${name}' -> null`);
        } else {
            let text = Buffer.tostring(bytes);
            context.log(`m0: blob '${name}' -> ${bytes.byteLength} bytes, first line '${text.split("\n")[0]}'`);
        }
    }

    startRender(): void {
        let context = this.context!;
        context.log("m0: go fired, starting render job");
        this.job = Jobs.run(renderSine, 1.0);
    }

    override advance(seconds: f64): bool {
        let context = this.context!;
        let vm = context.viewModel();
        if (vm != null) {
            let voices = vm.getNumber("voices");
            if (voices != null && voices.value != this.lastVoices) {
                this.lastVoices = voices.value;
                let l = new Load();
                l.voices = <i32>voices.value;
                this.load.publish(l);
                context.log(`m0: stress voices ${l.voices}`);
            }
        }
        let handle = this.handle;
        if (handle != null) {
            let failed = handle.failed;
            if (failed != null) {
                context.log(`m0: processor failed: ${failed}`);
                this.handle = null;
            }
        }
        let job = this.job;
        if (job != null && !job.running) {
            let result = job.join();
            this.job = null;
            if (result != null && result.ok) {
                let blob = result.value;
                let bytes = blob.toArrayBuffer();
                context.log(`m0: job blob ${blob.byteLength} bytes`);
                if (vm != null) {
                    let wav = vm.getBlob("wav");
                    let size = vm.getNumber("wavBytes");
                    if (wav != null) {
                        wav.value = bytes;
                        let back = wav.value;
                        context.log(`m0: PropertyBlob set; read back ${back == null ? -1 : back.byteLength} bytes`);
                    } else {
                        context.log("m0: no wav property");
                    }
                    if (size != null) size.value = <f64>bytes.byteLength;
                }
                blob.release();
            } else {
                context.log("m0: job failed");
            }
        }
        return true;
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        let context = this.context!;
        context.log(`m0: key ${event.key} phase ${event.phase} shift ${event.shift} ctrl ${event.control} alt ${event.alt} meta ${event.meta}`);
        return true;
    }

    override textEvent(event: TextInput): bool {
        let context = this.context!;
        context.log(`m0: text '${event.text}'`);
        return true;
    }

    override dispose(): void {
        let context = this.context;
        if (context != null) context.log("m0: dispose");
        let handle = this.handle;
        if (handle != null) handle.stop();
    }

    override draw(renderer: Renderer): void {}
}
