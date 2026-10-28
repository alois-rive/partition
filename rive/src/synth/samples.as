// Samples (docs/spec.md §7.4): WAV files carried as base64 text in the song,
// decoded to mono f32 and packed into one bank that the engine reads.
//
// Bank layout, all f32: [0] the number of samples, then one record of
// BANK_RECORD values per sample (its first frame in the PCM area, its frame
// count, its sample rate, its peak), then the PCM area from BANK_HEADER on.
// Frame offsets stay exact in f32 up to 2^24, which caps the bank at
// MAX_BANK_FRAMES.

import { Blob } from "rive/shared";

export const MAX_SAMPLES: i32 = 64;
export const BANK_RECORD: i32 = 4;
export const BANK_HEADER: i32 = 1 + MAX_SAMPLES * BANK_RECORD;
export const B_OFFSET: i32 = 0;
export const B_FRAMES: i32 = 1;
export const B_RATE: i32 = 2;
export const B_PEAK: i32 = 3;
export const MAX_BANK_FRAMES: i32 = 1 << 24;

// --- Base64 -------------------------------------------------------------------

function sextet(c: i32): i32 {
    if (c >= 65 && c <= 90) return c - 65; // A-Z
    if (c >= 97 && c <= 122) return c - 71; // a-z
    if (c >= 48 && c <= 57) return c + 4; // 0-9
    if (c == 43 || c == 45) return 62; // + (and - in the URL alphabet)
    if (c == 47 || c == 95) return 63; // / (and _)
    return -1;
}

// Decodes base64, skipping whitespace; null on any other stray character.
export function decodeBase64(text: string): Uint8Array? {
    let n = text.length;
    let out = new Uint8Array((n * 3) / 4 + 3);
    let o = 0;
    let acc = 0;
    let bits = 0;
    for (let i = 0; i < n; i++) {
        let c = text.charCodeAt(i);
        if (c == 61) break; // '=' padding ends the data
        if (c == 32 || c == 10 || c == 13 || c == 9) continue;
        let v = sextet(c);
        if (v < 0) return null;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = <u8>((acc >> bits) & 0xFF);
        }
    }
    return out.subarray(0, o);
}

const ALPHABET: string = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Encodes bytes as base64 in lines of 76 characters, each ending with a
// newline (as the shell and tools/gen_chopped.py write it).
export function encodeBase64(bytes: Uint8Array): string {
    let parts = new Array<string>();
    let line = "";
    let n = bytes.length;
    for (let i = 0; i < n; i += 3) {
        let b0 = <i32>bytes[i];
        let b1 = i + 1 < n ? <i32>bytes[i + 1] : 0;
        let b2 = i + 2 < n ? <i32>bytes[i + 2] : 0;
        line += ALPHABET.charAt(b0 >> 2);
        line += ALPHABET.charAt(((b0 & 3) << 4) | (b1 >> 4));
        line += i + 1 < n ? ALPHABET.charAt(((b1 & 15) << 2) | (b2 >> 6)) : "=";
        line += i + 2 < n ? ALPHABET.charAt(b2 & 63) : "=";
        if (line.length >= 76) {
            parts.push(line);
            line = "";
        }
    }
    if (line.length > 0) parts.push(line);
    return parts.length > 0 ? parts.join("\n") + "\n" : "";
}

// --- WAV ----------------------------------------------------------------------

export class SampleData {
    rate: f64 = 48000;
    frames: i32 = 0;
    bits: i32 = 16; // the file's sample size (edits keep 16 bit files 16 bit)
    float: bool = false;
    data: Float32Array = new Float32Array(0); // mono
    error: string = "";
}

function u16(b: Uint8Array, i: i32): i32 {
    return <i32>b[i] | (<i32>b[i + 1] << 8);
}

function u32(b: Uint8Array, i: i32): i32 {
    return <i32>b[i] | (<i32>b[i + 1] << 8) | (<i32>b[i + 2] << 16) | (<i32>b[i + 3] << 24);
}

function failed(message: string): SampleData {
    let s = new SampleData();
    s.error = message;
    return s;
}

// Reads a WAV file: PCM 8, 16, 24 or 32 bit, or float 32 or 64 bit, any rate
// and channel count. Channels are summed to mono (stereo voices are M13).
export function decodeWav(b: Uint8Array): SampleData {
    let n = b.length;
    if (n < 12 || b[0] != 82 || b[1] != 73 || b[2] != 70 || b[3] != 70 || b[8] != 87 || b[9] != 65 || b[10] != 86 || b[11] != 69) {
        return failed("not a WAV file (RIFF/WAVE)");
    }
    let i = 12;
    let format = -1;
    let channels = 0;
    let rate = 0;
    let bits = 0;
    while (i + 8 <= n) {
        let size = u32(b, i + 4);
        let body = i + 8;
        if (size < 0) return failed("a WAV chunk is too large");
        let id0 = b[i];
        let id1 = b[i + 1];
        let id2 = b[i + 2];
        let id3 = b[i + 3];
        if (id0 == 102 && id1 == 109 && id2 == 116 && id3 == 32 && size >= 16 && body + 16 <= n) { // "fmt "
            format = u16(b, body);
            channels = u16(b, body + 2);
            rate = u32(b, body + 4);
            bits = u16(b, body + 14);
            if (format == 0xFFFE && size >= 26 && body + 26 <= n) format = u16(b, body + 24);
        } else if (id0 == 100 && id1 == 97 && id2 == 116 && id3 == 97) { // "data"
            if (format < 0) return failed("WAV data before its format");
            if (channels < 1 || rate < 1000 || rate > 384000) return failed("unsupported WAV channels or rate");
            let pcm = format == 1 && (bits == 8 || bits == 16 || bits == 24 || bits == 32);
            let float = format == 3 && (bits == 32 || bits == 64);
            if (!pcm && !float) return failed(`unsupported WAV encoding (format ${format}, ${bits} bits)`);
            let width = bits / 8;
            let end = min<i32>(body + size, n);
            let frames = (end - body) / (width * channels);
            let s = new SampleData();
            s.rate = <f64>rate;
            s.frames = frames;
            s.bits = bits;
            s.float = float;
            let data = new Float32Array(frames);
            let scale = 1.0 / <f64>channels;
            let p = body;
            for (let f = 0; f < frames; f++) {
                let sum = 0.0;
                for (let c = 0; c < channels; c++) {
                    let v = 0.0;
                    if (float) {
                        v = bits == 32 ? <f64>reinterpret<f32>(u32(b, p)) : reinterpret<f64>(<u64><u32>u32(b, p) | (<u64><u32>u32(b, p + 4) << 32));
                    } else if (bits == 8) {
                        v = (<f64>b[p] - 128) / 128;
                    } else if (bits == 16) {
                        v = <f64><i16>u16(b, p) / 32768;
                    } else if (bits == 24) {
                        let x = <i32>b[p] | (<i32>b[p + 1] << 8) | (<i32>b[p + 2] << 16);
                        if (x & 0x800000) x |= 0xFF000000;
                        v = <f64>x / 8388608;
                    } else {
                        v = <f64>u32(b, p) / 2147483648;
                    }
                    if (!isFinite(v)) v = 0;
                    sum += v;
                    p += width;
                }
                data[f] = <f32>(sum * scale);
            }
            s.data = data;
            return s;
        }
        i = body + size + (size & 1);
    }
    return failed("a WAV file without data");
}

// --- Bank ---------------------------------------------------------------------

export class BankResult {
    bank: Blob? = null;
    // One message per sample that could not be read ("" when it was).
    errors: Array<string> = [];
}

// Decodes the samples (base64 WAV texts, in bank order) into one bank.
@job export function buildBank(texts: Array<string>): BankResult {
    let result = new BankResult();
    let count = min<i32>(texts.length, MAX_SAMPLES);
    let decoded = new Array<SampleData>();
    let total = 0;
    for (let i = 0; i < count; i++) {
        let bytes = decodeBase64(texts[i]);
        let s = bytes == null ? failed("not base64 text") : decodeWav(bytes);
        if (s.error.length == 0 && total + s.frames > MAX_BANK_FRAMES) s = failed("the samples are too long together (about 5 minutes at 48 kHz at most)");
        if (s.error.length == 0) total += s.frames;
        decoded.push(s);
        result.errors.push(s.error);
    }
    let bank = new Float32Array(BANK_HEADER + total);
    bank[0] = <f32>count;
    let offset = 0;
    for (let i = 0; i < count; i++) {
        let s = decoded[i];
        let r = 1 + i * BANK_RECORD;
        let peak = 0.0;
        for (let f = 0; f < s.frames; f++) {
            let v = <f64>s.data[f];
            bank[BANK_HEADER + offset + f] = <f32>v;
            peak = Math.max(peak, Math.abs(v));
        }
        bank[r + B_OFFSET] = <f32>offset;
        bank[r + B_FRAMES] = <f32>s.frames;
        bank[r + B_RATE] = <f32>s.rate;
        bank[r + B_PEAK] = <f32>peak;
        offset += s.frames;
    }
    result.bank = Blob.fromArray(bank);
    return result;
}

// An empty bank: no samples.
export function emptyBank(): Blob {
    return Blob.fromArray(new Float32Array(BANK_HEADER));
}
