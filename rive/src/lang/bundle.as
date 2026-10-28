// Song bundles (docs/spec.md §3.2): a song folder packed into one text file.
//
//   %partition-bundle 1
//   === song.yaml
//   title: ...
//   === channels/kick.ch
//   note(p: C1)

import { Diagnostics } from "./diagnostics";
import { splitLines } from "./source";

export const BUNDLE_MAGIC: string = "%partition-bundle 1";
const HEADER: string = "=== ";

export class SongFile {
    constructor(public path: string, public text: string) {}
}

export class Bundle {
    files: Array<SongFile> = [];

    constructor(public diagnostics: Diagnostics) {}

    file(path: string): SongFile? {
        for (let i = 0; i < this.files.length; i++) {
            if (this.files[i].path == path) return this.files[i];
        }
        return null;
    }
}

// Why `path` cannot name a file in a song, or "" when it can.
export function pathProblem(path: string): string {
    if (path.length == 0) return "a file needs a path";
    if (path.startsWith("/") || path.includes("\\")) return `'${path}' must be a relative path with '/' separators`;
    let parts = path.split("/");
    for (let i = 0; i < parts.length; i++) {
        let part = parts[i];
        if (part.length == 0 || part == "." || part == "..") return `'${path}' must not contain empty, '.' or '..' segments`;
    }
    return "";
}

// The index of the first line at or after `from` (a line start) that begins
// with the file header, or -1.
function headerAt(text: string, from: i32): i32 {
    if (text.substring(from, from + HEADER.length) == HEADER) return from;
    let k = text.indexOf("\n" + HEADER, from);
    return k < 0 ? -1 : k + 1;
}

// The 1-based line `index` is on (only counted when there is a problem).
function lineOf(text: string, index: i32): i32 {
    let line = 1;
    let k = text.indexOf("\n");
    while (k >= 0 && k < index) {
        line++;
        k = text.indexOf("\n", k + 1);
    }
    return line;
}

// A file's body as the bundle holds it: LF line ends, ending with one when
// it has any text. Bodies are sliced whole, so bundles with large files
// (base64 samples) load without walking them line by line.
function body(text: string, from: i32, to: i32): string {
    if (to <= from) return "";
    let b = text.substring(from, to);
    if (b.includes("\r")) b = b.replaceAll("\r\n", "\n");
    if (b.length > 0 && b.charCodeAt(b.length - 1) != 10) b += "\n";
    return b;
}

export function parseBundle(path: string, text: string): Bundle {
    let bundle = new Bundle(new Diagnostics(path));
    let firstEnd = text.indexOf("\n");
    let first = firstEnd < 0 ? text : text.substring(0, firstEnd);
    if (first.endsWith("\r")) first = first.substring(0, first.length - 1);
    if (first != BUNDLE_MAGIC) {
        bundle.diagnostics.error(1, 1, 1 + first.length, "bundle", `a bundle starts with '${BUNDLE_MAGIC}'`);
        return bundle;
    }
    let n = text.length;
    let pos = firstEnd < 0 ? n : firstEnd + 1;
    let header = pos < n ? headerAt(text, pos) : -1;
    let before = header < 0 ? text.substring(pos) : text.substring(pos, header);
    if (before.trim().length > 0) {
        let at = pos + before.length - before.trimStart().length;
        bundle.diagnostics.error(lineOf(text, at), 1, 2, "bundle", "text outside of a file; start a file with '=== <path>'");
    }
    while (header >= 0) {
        let lineEnd = text.indexOf("\n", header);
        let headerLine = lineEnd < 0 ? text.substring(header) : text.substring(header, lineEnd);
        let start = lineEnd < 0 ? n : lineEnd + 1;
        let next = start < n ? headerAt(text, start) : -1;
        let end = next < 0 ? n : next;
        let filePath = headerLine.substring(HEADER.length).trim();
        let problem = pathProblem(filePath);
        if (problem.length > 0) {
            bundle.diagnostics.error(lineOf(text, header), 5, headerLine.length + 1, "bundle", problem);
        } else if (bundle.file(filePath) != null) {
            bundle.diagnostics.error(lineOf(text, header), 5, headerLine.length + 1, "bundle", `'${filePath}' appears twice`);
        } else {
            bundle.files.push(new SongFile(filePath, body(text, start, end)));
        }
        header = next;
    }
    return bundle;
}

// Why `files` cannot be packed, or "" when they can.
export function packProblem(files: Array<SongFile>): string {
    for (let i = 0; i < files.length; i++) {
        let problem = pathProblem(files[i].path);
        if (problem.length > 0) return problem;
        let lines = splitLines(files[i].text);
        for (let j = 0; j < lines.length; j++) {
            if (lines[j].startsWith(HEADER)) return `${files[i].path}:${j + 1} starts with '=== ', which a bundle cannot hold`;
        }
    }
    return "";
}

export function packBundle(files: Array<SongFile>): string {
    let out = BUNDLE_MAGIC + "\n";
    for (let i = 0; i < files.length; i++) {
        out += HEADER + files[i].path + "\n";
        let lines = splitLines(files[i].text);
        if (lines.length > 0) out += lines.join("\n") + "\n";
    }
    return out;
}
