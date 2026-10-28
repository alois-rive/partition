// Score events (docs/spec.md §9.1): everything the engine needs to play a
// song, stamped in seconds of song time.
//
// Sound is grouped by *owner*: a channel's own rows are owner 0, and every
// pattern repetition plays as an owner of its own that starts as a copy of the
// state it was called from. Parameter changes address one owner, so a pattern
// never changes the sound of its channel (§8).

export enum EventKind {
    Fork = 0, // owner starts as a copy of `parent`'s parameters
    NoteOn = 1,
    NoteOff = 2,
    Param = 3,
    Glide = 4,
    Lfo = 5,
    LfoOff = 6,
    Cut = 7,
    RowMark = 8,
    End = 9,
}

export const MASTER_CHANNEL: i32 = -1;

export class ScoreEvent {
    time: f64 = 0;
    seq: i32 = 0; // emission order, which breaks ties in time
    kind: EventKind = EventKind.End;
    channel: i32 = MASTER_CHANNEL;
    owner: i32 = 0;
    parent: i32 = 0; // Fork: the owner copied from
    note: i32 = 0; // NoteOn/NoteOff: note id; Lfo/LfoOff: LFO id
    inst: i32 = -1; // instrument index, -1 for the channel strip
    param: i32 = -1; // ParamId
    pitch: f64 = 0; // MIDI note number, fractional for detune
    vel: f64 = 0;
    value: f64 = 0; // Param target, Lfo depth, RowMark tempo
    from: f64 = NaN; // Param start value (NaN: the engine's current value)
    seconds: f64 = 0; // note length, ramp/glide/fade time
    rate: f64 = 0; // Lfo frequency in Hz
    curve: i32 = 0; // Param curve, Lfo shape
    row: i32 = 0; // RowMark: the source row; NoteOn: the source line
    played: i32 = 0; // RowMark: the played row index

    describe(): string {
        let t = Math.round(this.time * 10000) / 10000;
        switch (this.kind) {
            case EventKind.Fork: return `${t} fork ch${this.channel} o${this.owner}<o${this.parent}`;
            case EventKind.NoteOn: return `${t} on ch${this.channel} o${this.owner} n${this.note} p${this.pitch} v${this.vel} i${this.inst} len${Math.round(this.seconds * 10000) / 10000}`;
            case EventKind.NoteOff: return `${t} off ch${this.channel} n${this.note}`;
            case EventKind.Param: return `${t} param ch${this.channel} o${this.owner} i${this.inst} #${this.param}=${this.value} from ${this.from} in ${Math.round(this.seconds * 10000) / 10000}`;
            case EventKind.Glide: return `${t} glide ch${this.channel} p${this.pitch} in ${this.seconds}`;
            case EventKind.Lfo: return `${t} lfo ch${this.channel} o${this.owner} #${this.param} ${this.rate}Hz d${this.value} s${this.curve}`;
            case EventKind.LfoOff: return `${t} lfo_off ch${this.channel} o${this.owner} #${this.param}`;
            case EventKind.Cut: return `${t} cut ch${this.channel} in ${this.seconds}`;
            case EventKind.RowMark: return `${t} row ${this.row}`;
            default: return `${t} end`;
        }
    }
}

export function sortEvents(events: Array<ScoreEvent>): void {
    events.sort((a: ScoreEvent, b: ScoreEvent): i32 => {
        if (a.time < b.time) return -1;
        if (a.time > b.time) return 1;
        return a.seq - b.seq;
    });
}

// Flat form for crossing lanes (one block, §9.1 step 4): FIELDS numbers per event.
export const FIELDS: i32 = 16;

export function packEvents(events: Array<ScoreEvent>): Float64Array {
    let out = new Float64Array(events.length * FIELDS);
    for (let i = 0; i < events.length; i++) {
        let e = events[i];
        let o = i * FIELDS;
        out[o] = e.time;
        out[o + 1] = <f64>e.kind;
        out[o + 2] = <f64>e.channel;
        out[o + 3] = <f64>e.owner;
        out[o + 4] = <f64>e.parent;
        out[o + 5] = <f64>e.note;
        out[o + 6] = <f64>e.inst;
        out[o + 7] = <f64>e.param;
        out[o + 8] = e.pitch;
        out[o + 9] = e.vel;
        out[o + 10] = e.value;
        out[o + 11] = e.from;
        out[o + 12] = e.seconds;
        out[o + 13] = e.rate;
        out[o + 14] = <f64>e.curve;
        out[o + 15] = <f64>e.row;
    }
    return out;
}

export function unpackEvent(data: Float64Array, index: i32): ScoreEvent {
    let o = index * FIELDS;
    let e = new ScoreEvent();
    e.seq = index;
    e.time = data[o];
    e.kind = <EventKind>(<i32>data[o + 1]);
    e.channel = <i32>data[o + 2];
    e.owner = <i32>data[o + 3];
    e.parent = <i32>data[o + 4];
    e.note = <i32>data[o + 5];
    e.inst = <i32>data[o + 6];
    e.param = <i32>data[o + 7];
    e.pitch = data[o + 8];
    e.vel = data[o + 9];
    e.value = data[o + 10];
    e.from = data[o + 11];
    e.seconds = data[o + 12];
    e.rate = data[o + 13];
    e.curve = <i32>data[o + 14];
    e.row = <i32>data[o + 15];
    return e;
}
