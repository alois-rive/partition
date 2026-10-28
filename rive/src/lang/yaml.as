// The YAML subset read from song.yaml (docs/spec.md §3.1): block mappings,
// block sequences (of mappings or scalars), plain and double-quoted scalars and
// `#` comments. Flow collections, anchors, tags and multi-line scalars are
// reported as unsupported.

import { Diagnostics } from "./diagnostics";
import { splitLines } from "./source";

export enum YamlKind {
    Null,
    Scalar,
    Map,
    List,
}

export class YamlNode {
    kind: YamlKind = YamlKind.Null;
    text: string = ""; // a scalar's value
    quoted: bool = false;
    keys: Array<string> = [];
    values: Array<YamlNode> = [];
    items: Array<YamlNode> = [];
    line: i32 = 0;
    col: i32 = 0;

    get(key: string): YamlNode? {
        for (let i = 0; i < this.keys.length; i++) {
            if (this.keys[i] == key) return this.values[i];
        }
        return null;
    }
}

class YamlLine {
    constructor(
        public number: i32, // 1-based
        public indent: i32,
        public content: string, // without indentation and comment
    ) {}
}

// Removes a trailing comment: a '#' at the start or after whitespace, outside quotes.
function stripComment(text: string): string {
    let inQuote = false;
    for (let i = 0; i < text.length; i++) {
        let c = text.charCodeAt(i);
        if (c == 34 && (i == 0 || text.charCodeAt(i - 1) != 92)) inQuote = !inQuote;
        if (c == 35 && !inQuote && (i == 0 || text.charCodeAt(i - 1) == 32 || text.charCodeAt(i - 1) == 9)) {
            return text.substring(0, i);
        }
    }
    return text;
}

function trimEnd(text: string): string {
    let n = text.length;
    while (n > 0 && (text.charCodeAt(n - 1) == 32 || text.charCodeAt(n - 1) == 9)) n--;
    return text.substring(0, n);
}

// The index of the ':' that ends a mapping key (followed by a space or the end
// of the line, outside quotes), or -1.
function keyColon(text: string): i32 {
    let inQuote = false;
    for (let i = 0; i < text.length; i++) {
        let c = text.charCodeAt(i);
        if (c == 34) inQuote = !inQuote;
        if (c == 58 && !inQuote && (i + 1 == text.length || text.charCodeAt(i + 1) == 32)) return i;
    }
    return -1;
}

function isDash(content: string): bool {
    return content == "-" || content.startsWith("- ");
}

class YamlParser {
    lines: Array<YamlLine> = [];
    pos: i32 = 0;

    constructor(public diagnostics: Diagnostics) {}

    load(text: string): void {
        let raw = splitLines(text);
        for (let i = 0; i < raw.length; i++) {
            let line = trimEnd(stripComment(raw[i]));
            let indent = 0;
            while (indent < line.length && line.charCodeAt(indent) == 32) indent++;
            if (indent == line.length) continue;
            if (line.charCodeAt(indent) == 9) {
                this.diagnostics.error(i + 1, indent + 1, indent + 2, "yaml", "indent with spaces, not tabs");
                continue;
            }
            this.lines.push(new YamlLine(i + 1, indent, line.substring(indent)));
        }
    }

    parseDocument(): YamlNode {
        if (this.lines.length == 0) {
            let empty = new YamlNode();
            empty.kind = YamlKind.Map;
            return empty;
        }
        let root = this.parseBlock(this.lines[0].indent);
        while (this.pos < this.lines.length) {
            let l = this.lines[this.pos];
            let what = isDash(l.content) ? "a list item where a key was expected" : "unexpected indentation";
            this.diagnostics.error(l.number, l.indent + 1, l.indent + 2, "yaml", what);
            this.pos++;
        }
        return root;
    }

    parseBlock(indent: i32): YamlNode {
        let first = this.lines[this.pos];
        if (isDash(first.content)) return this.parseList(indent);
        return this.parseMap(indent);
    }

    parseList(indent: i32): YamlNode {
        let list = new YamlNode();
        list.kind = YamlKind.List;
        list.line = this.lines[this.pos].number;
        list.col = indent + 1;
        while (this.pos < this.lines.length) {
            let l = this.lines[this.pos];
            if (l.indent != indent || !isDash(l.content)) break;
            let rest = l.content.substring(1);
            let pad = 1;
            while (pad - 1 < rest.length && rest.charCodeAt(pad - 1) == 32) pad++;
            let body = l.content.substring(pad);
            if (body.length == 0) {
                this.pos++;
                if (this.pos < this.lines.length && this.lines[this.pos].indent > indent) {
                    list.items.push(this.parseBlock(this.lines[this.pos].indent));
                } else {
                    list.items.push(new YamlNode());
                }
                continue;
            }
            // `- key: value` opens a mapping whose keys line up after the dash.
            l.indent = indent + pad;
            l.content = body;
            if (keyColon(body) >= 0 && !body.startsWith("\"")) {
                list.items.push(this.parseMap(l.indent));
            } else {
                list.items.push(this.scalar(body, l.number, l.indent + 1));
                this.pos++;
            }
        }
        return list;
    }

    parseMap(indent: i32): YamlNode {
        let map = new YamlNode();
        map.kind = YamlKind.Map;
        map.line = this.lines[this.pos].number;
        map.col = indent + 1;
        while (this.pos < this.lines.length) {
            let l = this.lines[this.pos];
            if (l.indent < indent) break;
            if (l.indent > indent) {
                this.diagnostics.error(l.number, l.indent + 1, l.indent + 2, "yaml", "unexpected indentation");
                this.pos++;
                continue;
            }
            if (isDash(l.content)) break;
            let colon = keyColon(l.content);
            if (colon <= 0) {
                this.diagnostics.error(l.number, l.indent + 1, l.indent + 1 + l.content.length, "yaml", "expected 'key: value'");
                this.pos++;
                continue;
            }
            let key = l.content.substring(0, colon);
            let valueText = l.content.substring(colon + 1).trim();
            let valueCol = l.indent + 1 + l.content.length - valueText.length;
            if (map.get(key) != null) {
                this.diagnostics.error(l.number, l.indent + 1, l.indent + 1 + colon, "yaml", `duplicate key '${key}'`);
            }
            this.pos++;
            let value: YamlNode;
            if (valueText.length > 0) {
                value = this.scalar(valueText, l.number, valueCol);
            } else if (this.pos < this.lines.length && this.lines[this.pos].indent > indent) {
                value = this.parseBlock(this.lines[this.pos].indent);
            } else if (this.pos < this.lines.length && this.lines[this.pos].indent == indent && isDash(this.lines[this.pos].content)) {
                value = this.parseList(indent);
            } else {
                value = new YamlNode();
                value.line = l.number;
            }
            map.keys.push(key);
            map.values.push(value);
        }
        return map;
    }

    scalar(text: string, line: i32, col: i32): YamlNode {
        let node = new YamlNode();
        node.kind = YamlKind.Scalar;
        node.line = line;
        node.col = col;
        let c = text.charCodeAt(0);
        if (c == 34) {
            let value = "";
            let closed = false;
            let i = 1;
            while (i < text.length) {
                let d = text.charCodeAt(i);
                if (d == 34) {
                    closed = true;
                    i++;
                    break;
                }
                if (d == 92 && i + 1 < text.length) {
                    let e = text.charCodeAt(i + 1);
                    value += e == 110 ? "\n" : e == 116 ? "\t" : String.fromCharCode(e);
                    i += 2;
                    continue;
                }
                value += String.fromCharCode(d);
                i++;
            }
            if (!closed) {
                this.diagnostics.error(line, col, col + text.length, "yaml", "unterminated string");
            } else if (i < text.length) {
                this.diagnostics.error(line, col + i, col + text.length, "yaml", "unexpected text after the string");
            }
            node.text = value;
            node.quoted = true;
            return node;
        }
        if (c == 91 || c == 123) {
            this.diagnostics.error(line, col, col + text.length, "yaml", "flow collections ([...] and {...}) are not supported; use block style");
        } else if (c == 38 || c == 42 || c == 33) {
            this.diagnostics.error(line, col, col + 1, "yaml", "anchors, aliases and tags are not supported");
        } else if ((c == 124 || c == 62) && text.length <= 2) {
            this.diagnostics.error(line, col, col + text.length, "yaml", "multi-line strings are not supported");
        }
        node.text = text;
        return node;
    }
}

export class YamlDocument {
    constructor(public root: YamlNode, public diagnostics: Diagnostics) {}
}

export function parseYaml(path: string, text: string): YamlDocument {
    let diagnostics = new Diagnostics(path);
    let parser = new YamlParser(diagnostics);
    parser.load(text);
    let root = parser.parseDocument();
    return new YamlDocument(root, diagnostics);
}
