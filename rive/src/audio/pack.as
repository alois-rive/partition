// A compiled score in the form that crosses lanes: two shared blobs.

import { Blob } from "rive/shared";
import { Score } from "../score/compiler";
import { packEvents } from "../score/events";
import { packInstruments } from "../synth/insttable";

export class PackedScore {
    constructor(public events: Blob, public instruments: Blob, public duration: f64, public loopStart: f64, public loopEnd: f64) {}

    release(): void {
        this.events.release();
        this.instruments.release();
    }
}

export function packScore(score: Score): PackedScore {
    let events = Blob.fromArray(packEvents(score.events));
    let instruments = Blob.fromArray(packInstruments(score.instruments));
    return new PackedScore(events, instruments, score.duration, score.loopStart, score.loopEnd);
}
