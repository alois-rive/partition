// WAV files (docs/spec.md §9.5): RIFF/WAVE with fmt, LIST/INFO and data, as
// 16-bit PCM with TPDF dither or 32-bit float.

import { Buffer } from "rive/buffer";
import { Blob } from "rive/shared";
import { Noise } from "../synth/dsp";

export const FORMAT_PCM16: i32 = 0;
export const FORMAT_FLOAT32: i32 = 1;

function infoChunk(id: string, text: string): ArrayBuffer {
    let bytes = Buffer.fromstring(text);
    let size = bytes.byteLength + 1; // NUL-terminated
    let padded = size + (size & 1);
    let out = new ArrayBuffer(8 + padded);
    let view = new DataView(out);
    for (let i = 0; i < 4; i++) view.setUint8(i, <u8>id.charCodeAt(i));
    view.setUint32(4, size, true);
    let src = Uint8Array.wrap(bytes);
    let dst = Uint8Array.wrap(out);
    for (let i = 0; i < bytes.byteLength; i++) dst[8 + i] = src[i];
    return out;
}

function tag(view: DataView, at: i32, id: string): void {
    for (let i = 0; i < 4; i++) view.setUint8(at + i, <u8>id.charCodeAt(i));
}

// Everything before the samples: RIFF, fmt, LIST/INFO and the data chunk header.
export function wavHeader(frames: i32, channels: i32, sampleRate: i32, format: i32, title: string, author: string): ArrayBuffer {
    let bytesPer = format == FORMAT_FLOAT32 ? 4 : 2;
    let dataBytes = frames * channels * bytesPer;
    let infos = new Array<ArrayBuffer>();
    if (title.length > 0) infos.push(infoChunk("INAM", title));
    if (author.length > 0) infos.push(infoChunk("IART", author));
    infos.push(infoChunk("ISFT", "Partition"));
    let listSize = 4;
    for (let i = 0; i < infos.length; i++) listSize += infos[i].byteLength;
    let headerBytes = 12 + 24 + 8 + listSize + 8;
    let out = new ArrayBuffer(headerBytes);
    let v = new DataView(out);
    tag(v, 0, "RIFF");
    v.setUint32(4, <u32>(headerBytes - 8 + dataBytes), true);
    tag(v, 8, "WAVE");
    tag(v, 12, "fmt ");
    v.setUint32(16, 16, true);
    v.setUint16(20, format == FORMAT_FLOAT32 ? 3 : 1, true);
    v.setUint16(22, <u16>channels, true);
    v.setUint32(24, <u32>sampleRate, true);
    v.setUint32(28, <u32>(sampleRate * channels * bytesPer), true);
    v.setUint16(32, <u16>(channels * bytesPer), true);
    v.setUint16(34, <u16>(bytesPer * 8), true);
    tag(v, 36, "LIST");
    v.setUint32(40, <u32>listSize, true);
    tag(v, 44, "INFO");
    let at = 48;
    let dst = Uint8Array.wrap(out);
    for (let i = 0; i < infos.length; i++) {
        let src = Uint8Array.wrap(infos[i]);
        for (let k = 0; k < src.length; k++) dst[at + k] = src[k];
        at += src.length;
    }
    tag(v, at, "data");
    v.setUint32(at + 4, <u32>dataBytes, true);
    return out;
}

// Encodes `frames` frames of interleaved f32 samples as a whole WAV file.
// Runs on the render job, so the main lane only copies finished bytes.
export function encodeWav(samples: Float32Array, frames: i32, channels: i32, sampleRate: i32, format: i32, title: string, author: string): Uint8Array {
    let header = wavHeader(frames, channels, sampleRate, format, title, author);
    let count = frames * channels;
    let bytesPer = format == FORMAT_FLOAT32 ? 4 : 2;
    let out = new Uint8Array(header.byteLength + count * bytesPer);
    let h = Uint8Array.wrap(header);
    for (let i = 0; i < header.byteLength; i++) out[i] = h[i];
    let view = new DataView(out.buffer);
    let at = header.byteLength;
    if (format == FORMAT_FLOAT32) {
        for (let i = 0; i < count; i++) {
            view.setFloat32(at, samples[i], true);
            at += 4;
        }
    } else {
        let dither = new Noise();
        dither.seed(0x51ed270b);
        for (let i = 0; i < count; i++) {
            // TPDF dither: the sum of two uniform values, one LSB wide.
            let d = (dither.unit() - dither.unit()) / 32768;
            let x = Math.min(Math.max(<f64>samples[i] + d, -1), 1);
            view.setInt16(at, <i16>Math.round(x * 32767), true);
            at += 2;
        }
    }
    return out;
}

// Hands out a finished WAV file in chunks of at most `chunkBytes` (§11.5).
export class WavChunks {
    next: i32 = 0; // bytes handed out so far
    chunkIndex: i32 = 0;

    constructor(public wav: Blob, public chunkBytes: i32 = 4 * 1024 * 1024) {}

    get totalBytes(): i32 {
        return <i32>this.wav.byteLength;
    }

    get chunkCount(): i32 {
        return max<i32>(1, <i32>Math.ceil(<f64>this.totalBytes / <f64>this.chunkBytes));
    }

    get finished(): bool {
        return this.next >= this.totalBytes;
    }

    // The next chunk, or null once the file is complete.
    nextChunk(): ArrayBuffer? {
        if (this.finished) return null;
        let n = min<i32>(this.chunkBytes, this.totalBytes - this.next);
        let out = new ArrayBuffer(n);
        this.wav.readInto(<u32>this.next, out, 0, n);
        this.next += n;
        this.chunkIndex++;
        return out;
    }
}
