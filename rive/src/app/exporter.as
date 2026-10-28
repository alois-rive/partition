// WAV export from inside the app (docs/spec.md §9.4, §11.5): renders the song
// on a job, then hands the file to the host in chunks through the view model.

import { Job, Jobs } from "rive/jobs";
import { Blob, Snapshot } from "rive/shared";
import { packScore } from "../audio/pack";
import { renderWav, RenderProgress, RenderSettings, WavSettings } from "../audio/render";
import { FORMAT_FLOAT32, FORMAT_PCM16, WavChunks } from "../audio/wav";
import { Score } from "../score/compiler";

export enum ExportState {
    Idle = 0,
    Rendering,
    Streaming,
    Done,
    Failed,
    Cancelled,
}

export function exportStateName(s: ExportState): string {
    if (s == ExportState.Rendering) return "rendering";
    if (s == ExportState.Streaming) return "streaming";
    if (s == ExportState.Done) return "done";
    if (s == ExportState.Failed) return "failed";
    if (s == ExportState.Cancelled) return "cancelled";
    return "idle";
}

// Seconds the exporter waits for a host to take a chunk before deciding there
// is no host (standalone in the previewer).
export const ACK_TIMEOUT: f64 = 2.0;

export class Exporter {
    state: ExportState = ExportState.Idle;
    job: Job<Blob>? = null;
    progress: Snapshot<RenderProgress> = Snapshot.create<RenderProgress>();
    latest: RenderProgress = new RenderProgress();
    stream: WavChunks? = null;
    fraction: f64 = 0;
    error: string = "";
    waiting: f64 = 0; // seconds since the last chunk went out
    chunk: ArrayBuffer? = null; // the chunk to publish, taken by the app
    chunkIndex: i32 = 0;
    chunkCount: i32 = 0;
    totalBytes: i32 = 0;
    unclaimed: bool = false; // no host took the first chunk

    start(score: Score, sampleRate: f64, format: i32, maxTail: f64, title: string, author: string): void {
        this.cancel();
        let packed = packScore(score);
        let settings = new RenderSettings();
        settings.sampleRate = sampleRate;
        settings.duration = score.duration;
        settings.maxTail = maxTail;
        let wav = new WavSettings();
        wav.format = format;
        wav.title = title;
        wav.author = author;
        this.job = Jobs.run(renderWav, packed.events, packed.instruments, settings, wav, this.progress);
        packed.release();
        this.state = ExportState.Rendering;
        this.fraction = 0;
        this.error = "";
        this.unclaimed = false;
    }

    cancel(): void {
        let job = this.job;
        if (job != null) {
            job.stop();
            job.release();
        }
        this.job = null;
        let stream = this.stream;
        if (stream != null) stream.wav.release();
        this.stream = null;
        if (this.state == ExportState.Rendering || this.state == ExportState.Streaming) this.state = ExportState.Cancelled;
    }

    // The host took the current chunk.
    ack(): void {
        if (this.state != ExportState.Streaming) return;
        this.next();
    }

    next(): void {
        let stream = this.stream;
        if (stream == null) return;
        let chunk = stream.nextChunk();
        if (chunk == null) {
            stream.wav.release();
            this.stream = null;
            this.state = ExportState.Done;
            return;
        }
        this.chunk = chunk;
        this.chunkIndex = stream.chunkIndex - 1;
        this.waiting = 0;
    }

    advance(seconds: f64): void {
        if (this.state == ExportState.Rendering) {
            if (this.progress.latestInto(this.latest) && this.latest.total > 0) {
                this.fraction = Math.min(this.latest.rendered / this.latest.total, 0.99);
            }
            let job = this.job;
            let result = job != null ? job.peek() : null;
            if (job != null && result != null) {
                this.job = null;
                if (result.ok) {
                    let stream = new WavChunks(result.value);
                    this.stream = stream;
                    this.chunkCount = stream.chunkCount;
                    this.totalBytes = stream.totalBytes;
                    this.fraction = 1;
                    this.state = ExportState.Streaming;
                    this.next();
                } else {
                    this.state = ExportState.Failed;
                    this.error = result.error;
                }
                job.release();
            }
        } else if (this.state == ExportState.Streaming) {
            this.waiting += seconds;
            if (this.waiting > ACK_TIMEOUT && this.chunkIndex == 0) {
                // Nobody is listening: standalone, the file has nowhere to go.
                this.unclaimed = true;
                let stream = this.stream;
                if (stream != null) stream.wav.release();
                this.stream = null;
                this.state = ExportState.Done;
            }
        }
    }

    takeChunk(): ArrayBuffer? {
        let c = this.chunk;
        this.chunk = null;
        return c;
    }
}

export function formatId(name: string): i32 {
    return name == "float32" ? FORMAT_FLOAT32 : FORMAT_PCM16;
}
