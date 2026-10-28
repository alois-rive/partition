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

export function parseBundle(path: string, text: string): Bundle {
    let bundle = new Bundle(new Diagnostics(path));
    let lines = splitLines(text);
    if (lines.length == 0 || lines[0] != BUNDLE_MAGIC) {
        bundle.diagnostics.error(1, 1, 1 + (lines.length > 0 ? lines[0].length : 0), "bundle", `a bundle starts with '${BUNDLE_MAGIC}'`);
        return bundle;
    }
    let current: SongFile? = null;
    let body = new Array<string>();
    for (let i = 1; i < lines.length; i++) {
        let line = lines[i];
        if (line.startsWith(HEADER)) {
            if (current != null) current.text = joinBody(body);
            body = new Array<string>();
            let filePath = line.substring(HEADER.length).trim();
            let problem = pathProblem(filePath);
            if (problem.length > 0) {
                bundle.diagnostics.error(i + 1, 5, line.length + 1, "bundle", problem);
                current = null;
                continue;
            }
            if (bundle.file(filePath) != null) {
                bundle.diagnostics.error(i + 1, 5, line.length + 1, "bundle", `'${filePath}' appears twice`);
                current = null;
                continue;
            }
            let file = new SongFile(filePath, "");
            bundle.files.push(file);
            current = file;
        } else if (current != null) {
            body.push(line);
        } else if (line.trim().length > 0) {
            bundle.diagnostics.error(i + 1, 1, line.length + 1, "bundle", "text outside of a file; start a file with '=== <path>'");
        }
    }
    if (current != null) current.text = joinBody(body);
    return bundle;
}

function joinBody(lines: Array<string>): string {
    if (lines.length == 0) return "";
    return lines.join("\n") + "\n";
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
