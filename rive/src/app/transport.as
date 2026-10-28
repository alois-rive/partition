// The main lane's side of playback (docs/spec.md §9.3): starts the audio
// processor, hands it scores and transport commands, reads its status back,
// and restarts it if it fails.

import { Audio, AudioHandle } from "rive/audio";
import { Control, CTRL_LOOP, CTRL_PLAY, CTRL_SCORE, CTRL_STOP, CTRL_STOP_AT, EngineIO, Mix, PartitionProcessor, PlayStatus, REGIONS } from "../audio/processor";
import { regionBytes, writeScore } from "../audio/scoreregion";
import { Score } from "../score/compiler";
import { FIELDS, packEvents } from "../score/events";
import { packInstruments } from "../synth/insttable";
import { emptyBank } from "../synth/samples";
import { Blob } from "rive/shared";

export enum TransportState {
    Stopped = 0,
    Playing = 1,
    Paused = 2,
}

export const MAX_RESTARTS: i32 = 3;
export const INITIAL_CAPACITY: u32 = 8 * 1024 * 1024;

class PendingScore {
    constructor(public events: Float64Array, public instruments: Float64Array, public keep: bool, public time: f64) {}
}

export class Transport {
    samples: Blob = emptyBank();
    io: EngineIO = new EngineIO(INITIAL_CAPACITY, this.samples);
    handle: AudioHandle? = null;
    status: PlayStatus = new PlayStatus();
    state: TransportState = TransportState.Stopped;
    generation: f64 = 0;
    score: Score? = null;
    failures: i32 = 0;
    retryIn: f64 = 0;
    lastError: string = "";
    mute: i32 = 0;
    solo: i32 = 0;
    loopStart: f64 = -1;
    loopEnd: f64 = -1;
    active: i32 = -1; // the region the processor plays from
    sentRegion: i32 = -1; // the region last handed over, until the processor confirms it
    sentGeneration: f64 = -1;
    queued: PendingScore? = null; // waits while a handover is in flight
    // Bumped on every processor failure, so the app can report each once.
    failureCount: i32 = 0;

    get running(): bool {
        return this.handle != null;
    }

    start(): void {
        if (this.handle != null) return;
        this.active = -1;
        this.sentRegion = -1;
        this.queued = null;
        this.handle = Audio.start(() => new PartitionProcessor(), this.io);
        this.publishMix();
        let score = this.score;
        if (score != null) this.send(score, false, this.status.time);
        this.sendLoop();
    }

    dispose(): void {
        let h = this.handle;
        if (h != null) {
            h.stop();
            h.release();
        }
        this.handle = null;
    }

    // A processor with room for `bytes` per region, replacing the current one.
    grow(bytes: u32): void {
        let playing = this.state == TransportState.Playing;
        let at = this.status.time;
        this.dispose();
        let capacity = INITIAL_CAPACITY;
        while (capacity < bytes) capacity *= 2;
        this.io = new EngineIO(capacity, this.samples);
        this.start();
        if (playing) this.control(CTRL_PLAY, at);
    }

    // A new sample bank. The processor takes samples only when it starts, so
    // a running one is replaced (playback continues from where it was).
    setSamples(bank: Blob): void {
        if (bank.id == this.samples.id) return;
        this.samples = bank;
        let running = this.handle != null;
        let playing = this.state == TransportState.Playing;
        let at = this.status.time;
        this.dispose();
        let old = this.io;
        this.io = new EngineIO(old.capacity, bank);
        old.release();
        if (!running) return;
        this.start();
        if (playing) this.control(CTRL_PLAY, at);
    }

    // Hands the processor a new score. With `keep`, playback continues from
    // where it is; otherwise it moves to `time`.
    setScore(score: Score, keep: bool, time: f64 = 0): void {
        this.score = score;
        if (this.handle == null) return;
        this.send(score, keep, time);
    }

    send(score: Score, keep: bool, time: f64): void {
        let pending = new PendingScore(packEvents(score.events), packInstruments(score.instruments), keep, time);
        let bytes = regionBytes(pending.events.length / FIELDS, pending.instruments.length);
        if (bytes > this.io.capacity) {
            this.queued = null;
            this.grow(bytes);
            return; // start() sends the score into the bigger regions
        }
        if (this.sentRegion >= 0) {
            // The processor has not taken the last one yet: only the newest waits.
            this.queued = pending;
            return;
        }
        this.handOver(pending);
    }

    handOver(p: PendingScore): void {
        let region = this.active < 0 ? 0 : (this.active + 1) % REGIONS;
        this.generation += 1;
        writeScore(this.io.regions[region], p.events, p.instruments, <u32>this.generation);
        this.sentRegion = region;
        this.sentGeneration = this.generation;
        let c = new Control();
        c.kind = <f64>CTRL_SCORE;
        c.a = <f64>region;
        c.b = p.keep ? 1 : 0;
        c.c = p.time;
        this.io.control.send(c);
    }

    control(kind: i32, a: f64, b: f64 = 0): void {
        let c = new Control();
        c.kind = <f64>kind;
        c.a = a;
        c.b = b;
        this.io.control.send(c);
    }

    // Plays from song time `from` (-1: continue where it paused).
    play(from: f64 = -1): void {
        if (this.handle == null) this.start();
        this.control(CTRL_PLAY, from);
        this.state = TransportState.Playing;
    }

    pause(): void {
        this.control(CTRL_STOP, 0);
        this.state = TransportState.Paused;
    }

    stop(): void {
        this.control(CTRL_STOP, 0);
        this.control(CTRL_STOP_AT, -1);
        this.state = TransportState.Stopped;
    }

    // Plays only until `until` (an audition of a row).
    audition(from: f64, until: f64): void {
        this.play(from);
        this.control(CTRL_STOP_AT, until);
    }

    setLoop(start: f64, end: f64): void {
        this.loopStart = start;
        this.loopEnd = end;
        this.sendLoop();
    }

    sendLoop(): void {
        if (this.handle != null) this.control(CTRL_LOOP, this.loopStart, this.loopEnd);
    }

    setMix(mute: i32, solo: i32): void {
        this.mute = mute;
        this.solo = solo;
        this.publishMix();
    }

    publishMix(): void {
        let m = new Mix();
        m.mute = <f64>this.mute;
        m.solo = <f64>this.solo;
        this.io.mix.publish(m);
    }

    // Reads the processor's status and watches for failures; call every frame.
    poll(seconds: f64): void {
        this.io.status.latestInto(this.status);
        if (this.sentRegion >= 0 && this.status.generation == this.sentGeneration) {
            this.active = this.sentRegion;
            this.sentRegion = -1;
            let q = this.queued;
            if (q != null) {
                this.queued = null;
                this.handOver(q);
            }
        }
        let h = this.handle;
        if (h != null) {
            let failed = h.failed;
            if (failed != null) {
                this.lastError = failed;
                this.handle = null;
                this.failures++;
                this.retryIn = 0.5 * <f64>this.failures;
                this.failureCount++;
            }
        } else if (this.failures > 0 && this.failures <= MAX_RESTARTS && this.state == TransportState.Playing) {
            this.retryIn -= seconds;
            if (this.retryIn <= 0) {
                // Start again where it was, with the same score.
                let at = this.status.time;
                this.start();
                this.control(CTRL_PLAY, at);
            }
        }
        if (this.state == TransportState.Playing && this.status.generation == this.generation && this.status.ended > 0 && this.status.playing == 0) {
            this.state = TransportState.Stopped;
        }
    }
}
