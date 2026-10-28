// Real-time playback (docs/spec.md §9.3): the audio processor that owns one
// Engine, and the messages the main lane sends it.

import { AudioProcessor } from "rive/audio";
import { Ring, SharedRegion, Snapshot } from "rive/shared";
import { H_GENERATION } from "./scoreregion";
import { Engine, MAX_CHANNELS } from "../synth/engine";

export const CTRL_PLAY: i32 = 1; // a: song time to start from, or -1 to continue
export const CTRL_STOP: i32 = 2; // release every voice; the position stays
export const CTRL_LOOP: i32 = 3; // a, b: loop start and end in seconds; -1 for none
export const CTRL_STOP_AT: i32 = 4; // a: song time to stop at (auditions), -1 for none
// A new score is in region `a`. `b` 1 continues from the current position;
// 0 moves to song time `c`.
export const CTRL_SCORE: i32 = 5;

export const REGIONS: i32 = 2;

export class Control {
    kind: f64 = 0;
    a: f64 = 0;
    b: f64 = 0;
    c: f64 = 0;
}

export class Mix {
    mute: f64 = 0; // channel bitmasks
    solo: f64 = 0;
}

export class PlayStatus {
    time: f64 = 0;
    row: f64 = 0;
    bpm: f64 = 120;
    playing: f64 = 0;
    ended: f64 = 0;
    voices: f64 = 0;
    peakL: f64 = 0;
    peakR: f64 = 0;
    generation: f64 = 0; // the score it is playing
    channelPeaks: StaticArray<f64> = new StaticArray<f64>(MAX_CHANNELS);
}

export class EngineIO {
    control: Ring<Control> = Ring.create<Control>(8192);
    mix: Snapshot<Mix> = Snapshot.create<Mix>();
    status: Snapshot<PlayStatus> = Snapshot.create<PlayStatus>(1024);
    regions: Array<SharedRegion> = [];
    capacity: u32 = 0;

    constructor(capacity: u32) {
        this.capacity = capacity;
        for (let i = 0; i < REGIONS; i++) this.regions.push(SharedRegion.create(capacity));
    }

    release(): void {
        this.control.release();
        this.mix.release();
        this.status.release();
        for (let i = 0; i < this.regions.length; i++) this.regions[i].release();
    }
}

export class PartitionProcessor extends AudioProcessor<EngineIO> {
    io: EngineIO? = null;
    engine: Engine? = null;
    control: Control = new Control();
    mix: Mix = new Mix();
    mixSeq: f64 = -1;
    status: PlayStatus = new PlayStatus();
    generation: f64 = 0;
    idleBlocks: i32 = 0;

    override init(sampleRate: f64, maxFrames: i32, channels: i32, io: EngineIO): void {
        this.io = io;
        this.engine = new Engine(sampleRate, channels);
    }

    @unchecked
    override process(out: StaticArray<f32>, frames: i32, startFrame: f64): void {
        let io = this.io!;
        let engine = this.engine!;
        let woke = false;
        while (io.control.receiveInto(this.control)) {
            this.apply(engine, this.control);
            woke = true;
        }
        if (io.mix.seq != this.mixSeq) {
            this.mixSeq = io.mix.seq;
            if (io.mix.latestInto(this.mix)) {
                engine.muteMask = <i32>this.mix.mute;
                engine.soloMask = <i32>this.mix.solo;
            }
        }
        // Asleep while nothing plays or rings: `out` arrives zeroed.
        if (!woke && !engine.playing && this.idleBlocks > 8) return;
        engine.render(out, frames);
        this.idleBlocks = !engine.playing && engine.silent ? this.idleBlocks + 1 : 0;
        this.publish(engine, io);
    }

    apply(engine: Engine, c: Control): void {
        let kind = <i32>c.kind;
        if (kind == CTRL_PLAY) {
            if (c.a >= 0) engine.seek(c.a);
            engine.play();
        } else if (kind == CTRL_STOP) {
            engine.stop();
        } else if (kind == CTRL_LOOP) {
            engine.loopStart = c.a;
            engine.loopEnd = c.b;
        } else if (kind == CTRL_STOP_AT) {
            engine.stopAt = c.a;
        } else if (kind == CTRL_SCORE) {
            let index = <i32>c.a;
            let regions = this.io!.regions;
            if (index < 0 || index >= regions.length) return;
            let region = regions[index];
            // A live edit keeps the voices already sounding; a move to a new
            // position starts the notes held there.
            let keep = c.b > 0;
            engine.loadRegion(region, keep ? engine.time : c.c, !keep);
            this.generation = <f64>region.atomicLoad(H_GENERATION);
        }
    }

    publish(engine: Engine, io: EngineIO): void {
        let s = this.status;
        let e = engine.status;
        s.time = engine.time;
        s.row = e.row;
        s.bpm = e.bpm;
        s.playing = e.playing;
        s.ended = e.ended;
        s.voices = e.voices;
        s.peakL = e.peakL;
        s.peakR = e.peakR;
        s.generation = this.generation;
        for (let i = 0; i < MAX_CHANNELS; i++) s.channelPeaks[i] = e.channelPeaks[i];
        io.status.publish(s);
    }
}
