// Scores in shared memory for the audio processor. A processor cannot be
// handed shared objects through rings, so two regions travel in its start
// argument: the main lane writes a new score into the idle one under the
// lock, then tells the processor (by number) to switch. The processor reads
// with atomic loads only, which it may do without the lock.
//
// Layout: a header of u32 words — generation, event count, instrument floats —
// then the instrument table, then the packed events, all f64.

import { SharedRegion } from "rive/shared";
import { FIELDS } from "../score/events";

export const HEADER_BYTES: u32 = 32;
export const H_GENERATION: u32 = 0;
export const H_EVENTS: u32 = 4;
export const H_INSTRUMENT_FLOATS: u32 = 8;

export function regionBytes(events: i32, instrumentFloats: i32): u32 {
    return HEADER_BYTES + <u32>(instrumentFloats + events * FIELDS) * 8;
}

class Writer {
    constructor(public events: Float64Array, public instruments: Float64Array, public generation: u32) {}
}

export function writeScore(region: SharedRegion, events: Float64Array, instruments: Float64Array, generation: u32): void {
    let w = new Writer(events, instruments, generation);
    region.exclusive((view) => {
        view.setU32(H_GENERATION, w.generation);
        view.setU32(H_EVENTS, <u32>(w.events.length / FIELDS));
        view.setU32(H_INSTRUMENT_FLOATS, <u32>w.instruments.length);
        view.writeFrom(HEADER_BYTES, w.instruments);
        view.writeFrom(HEADER_BYTES + <u32>w.instruments.length * 8, w.events);
    });
}

// One f64 from two atomic words (wasm is little-endian).
@inline
export function loadF64(region: SharedRegion, offset: u32): f64 {
    let lo = <u64>region.atomicLoad(offset);
    let hi = <u64>region.atomicLoad(offset + 4);
    return reinterpret<f64>((hi << 32) | lo);
}
