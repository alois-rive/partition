// song.yaml (docs/spec.md §3.1): metadata, initial tempo and the channel list.

import { ValueNode } from "./ast";
import { Diagnostics } from "./diagnostics";
import { lexLine, Tok } from "./lexer";
import { ValueKind } from "./ast";
import { ArgType, typeValue } from "./types";
import { parseYaml, YamlKind, YamlNode } from "./yaml";

export const SONG_YAML: string = "song.yaml";
export const CONDUCTOR_PATH: string = "conductor.ch";

export class ChannelConfig {
    name: string = "";
    file: string = "";
    width: i32 = 32;
    widthSet: bool = false; // song.yaml gave a width; otherwise the editor sizes the column
    mute: bool = false;
    solo: bool = false;
    line: i32 = 0; // where song.yaml declares it
}

export class SongConfig {
    title: string = "Untitled";
    author: string = "";
    bpm: f64 = 120;
    sigNum: i32 = 4;
    sigDen: i32 = 4;
    rowsPerBeat: i32 = 4;
    swing: f64 = 0;
    masterVolume: f64 = 1;
    channels: Array<ChannelConfig> = [];
}

export class ConfigResult {
    constructor(public config: SongConfig, public diagnostics: Diagnostics) {}
}

const SONG_KEYS: Array<string> = ["title", "author", "bpm", "signature", "rows_per_beat", "swing", "master_volume", "channels"];
const CHANNEL_KEYS: Array<string> = ["name", "file", "width", "mute", "solo"];

// Reads a scalar the way the channel language would (so `-1dB` and `4/4` work).
function scalarValue(text: string): ValueNode? {
    let tokens = lexLine(text, 1);
    if (tokens.length != 2) return null;
    let t = tokens[0];
    let v = new ValueNode();
    v.text = t.text;
    v.col = t.col;
    v.endCol = t.endCol;
    if (t.kind == Tok.Number) {
        v.kind = ValueKind.Number;
        v.num = t.num;
        v.unit = t.unit;
    } else if (t.kind == Tok.Fraction) {
        v.kind = ValueKind.Fraction;
        v.num = t.num;
        v.den = t.den;
    } else if (t.kind == Tok.Word) {
        v.kind = ValueKind.Word;
    } else {
        return null;
    }
    return v;
}

class ConfigReader {
    constructor(public diagnostics: Diagnostics) {}

    fail(node: YamlNode, message: string): void {
        this.diagnostics.error(node.line, max<i32>(node.col, 1), max<i32>(node.col, 1) + max<i32>(node.text.length, 1), "config", message);
    }

    text(node: YamlNode, key: string): string {
        if (node.kind != YamlKind.Scalar) {
            this.fail(node, `'${key}' must be text`);
            return "";
        }
        return node.text;
    }

    number(node: YamlNode, key: string, type: ArgType, lo: f64, hi: f64, integer: bool, fallback: f64): f64 {
        let v = node.kind == YamlKind.Scalar && !node.quoted ? scalarValue(node.text) : null;
        if (v == null) {
            this.fail(node, `'${key}' must be a number`);
            return fallback;
        }
        let r = typeValue(v, type);
        let value = r.value;
        if (value == null) {
            this.fail(node, `'${key}': ${r.error}`);
            return fallback;
        }
        if (value.num < lo || value.num > hi || (integer && value.num != Math.floor(value.num))) {
            this.fail(node, `'${key}' must be ${integer ? "a whole number " : ""}between ${lo} and ${hi}`);
            return fallback;
        }
        return value.num;
    }

    bool(node: YamlNode, key: string): bool {
        if (node.kind == YamlKind.Scalar && (node.text == "true" || node.text == "false")) return node.text == "true";
        this.fail(node, `'${key}' must be true or false`);
        return false;
    }

    warnUnknown(map: YamlNode, known: Array<string>): void {
        for (let i = 0; i < map.keys.length; i++) {
            if (!known.includes(map.keys[i])) {
                let v = map.values[i];
                this.diagnostics.warning(v.line, 1, 1 + map.keys[i].length, "config", `unknown key '${map.keys[i]}' (known: ${known.join(", ")})`);
            }
        }
    }
}

function baseName(path: string): string {
    let slash = path.lastIndexOf("/");
    let name = slash >= 0 ? path.substring(slash + 1) : path;
    let dot = name.lastIndexOf(".");
    return dot > 0 ? name.substring(0, dot) : name;
}

export function parseSongConfig(text: string): ConfigResult {
    let doc = parseYaml(SONG_YAML, text);
    let diagnostics = doc.diagnostics;
    let config = new SongConfig();
    let reader = new ConfigReader(diagnostics);
    let root = doc.root;
    if (root.kind != YamlKind.Map) {
        diagnostics.error(1, 1, 2, "config", "song.yaml must be a mapping of keys to values");
        return new ConfigResult(config, diagnostics);
    }
    reader.warnUnknown(root, SONG_KEYS);
    for (let i = 0; i < root.keys.length; i++) {
        let key = root.keys[i];
        let v = root.values[i];
        if (key == "title") config.title = reader.text(v, key);
        else if (key == "author") config.author = reader.text(v, key);
        else if (key == "bpm") config.bpm = reader.number(v, key, ArgType.Number, 20, 999, false, config.bpm);
        else if (key == "rows_per_beat") config.rowsPerBeat = <i32>reader.number(v, key, ArgType.Number, 1, 64, true, config.rowsPerBeat);
        else if (key == "swing") config.swing = reader.number(v, key, ArgType.Number, 0, 0.75, false, config.swing);
        else if (key == "master_volume") config.masterVolume = reader.number(v, key, ArgType.Gain, 0, 4, false, config.masterVolume);
        else if (key == "signature") readSignature(reader, v, config);
        else if (key == "channels") readChannels(reader, v, config);
    }
    return new ConfigResult(config, diagnostics);
}

function readSignature(reader: ConfigReader, v: YamlNode, config: SongConfig): void {
    let value = v.kind == YamlKind.Scalar ? scalarValue(v.text) : null;
    if (value == null || value.kind != ValueKind.Fraction) {
        reader.fail(v, "'signature' must be a fraction such as 4/4");
        return;
    }
    let den = <i32>value.den;
    let num = <i32>value.num;
    if (num < 1 || num > 32 || !(den == 1 || den == 2 || den == 4 || den == 8 || den == 16 || den == 32)) {
        reader.fail(v, "a signature is 1..32 over 1, 2, 4, 8, 16 or 32");
        return;
    }
    config.sigNum = num;
    config.sigDen = den;
}

function readChannels(reader: ConfigReader, v: YamlNode, config: SongConfig): void {
    if (v.kind == YamlKind.Null) return;
    if (v.kind != YamlKind.List) {
        reader.fail(v, "'channels' must be a list");
        return;
    }
    let names = new Array<string>();
    for (let i = 0; i < v.items.length; i++) {
        let item = v.items[i];
        if (item.kind != YamlKind.Map) {
            reader.fail(item, "each channel is a mapping with at least 'file'");
            continue;
        }
        reader.warnUnknown(item, CHANNEL_KEYS);
        let channel = new ChannelConfig();
        channel.line = item.line;
        for (let k = 0; k < item.keys.length; k++) {
            let key = item.keys[k];
            let value = item.values[k];
            if (key == "name") channel.name = reader.text(value, key);
            else if (key == "file") channel.file = reader.text(value, key);
            else if (key == "width") {
                channel.width = <i32>reader.number(value, key, ArgType.Number, 8, 200, true, channel.width);
                channel.widthSet = true;
            }
            else if (key == "mute") channel.mute = reader.bool(value, key);
            else if (key == "solo") channel.solo = reader.bool(value, key);
        }
        if (channel.file.length == 0) {
            reader.fail(item, "a channel needs a 'file'");
            continue;
        }
        if (channel.name.length == 0) channel.name = baseName(channel.file);
        if (names.includes(channel.name)) {
            reader.fail(item, `two channels are named '${channel.name}'`);
            continue;
        }
        names.push(channel.name);
        config.channels.push(channel);
    }
}

// Writes `config` back as song.yaml.
export function songConfigText(config: SongConfig): string {
    let out = `title: ${quote(config.title)}\n`;
    if (config.author.length > 0) out += `author: ${quote(config.author)}\n`;
    out += `bpm: ${fmt(config.bpm)}\n`;
    out += `signature: ${config.sigNum}/${config.sigDen}\n`;
    out += `rows_per_beat: ${config.rowsPerBeat}\n`;
    if (config.swing != 0) out += `swing: ${fmt(config.swing)}\n`;
    if (config.masterVolume != 1) out += `master_volume: ${fmt(config.masterVolume)}\n`;
    out += "channels:\n";
    for (let i = 0; i < config.channels.length; i++) {
        let c = config.channels[i];
        out += `  - name: ${quote(c.name)}\n    file: ${quote(c.file)}\n`;
        if (c.widthSet) out += `    width: ${c.width}\n`;
        if (c.mute) out += "    mute: true\n";
        if (c.solo) out += "    solo: true\n";
    }
    return out;
}

function fmt(x: f64): string {
    if (x == Math.floor(x) && Math.abs(x) < 1e9) return (<i64>x).toString();
    return x.toString();
}

function quote(text: string): string {
    let plain = text.length > 0;
    for (let i = 0; i < text.length; i++) {
        let c = text.charCodeAt(i);
        if (c == 58 || c == 35 || c == 34 || c == 92 || c == 91 || c == 123 || c == 38 || c == 42 || c == 33) plain = false;
    }
    if (plain && text.trim() == text) return text;
    return "\"" + text.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"") + "\"";
}
