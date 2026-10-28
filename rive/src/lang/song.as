// A song in memory: its files, parsed and checked (docs/spec.md §3).
//
// Files are kept by path. Editing one re-parses only that file; changing an
// instrument re-checks channels and patterns, since instruments declare the
// macro parameters they may use.

import { SongFile } from "./bundle";
import { CheckContext, CheckedFile, checkParsed, FileKind } from "./check";
import { ChannelConfig, CONDUCTOR_PATH, parseSongConfig, SONG_YAML, SongConfig } from "./config";
import { Diagnostic, Diagnostics } from "./diagnostics";
import { ParsedFile, parseFile } from "./parser";
import { isName } from "./types";

export const INSTRUMENTS_DIR: string = "instruments/";
export const PATTERNS_DIR: string = "patterns/";

export class ChannelSource {
    constructor(public config: ChannelConfig, public file: CheckedFile) {}

    get name(): string {
        return this.config.name;
    }
}

class Parsed {
    checked: CheckedFile? = null;
    checkedWith: string = ""; // the macro list `checked` was checked against

    constructor(public text: string, public file: ParsedFile) {}
}

// The name a file in `dir` is referenced by, or "" if it is not such a file.
export function nameIn(path: string, dir: string, ext: string): string {
    if (!path.startsWith(dir) || !path.endsWith(ext)) return "";
    let name = path.substring(dir.length, path.length - ext.length);
    return name.includes("/") ? "" : name;
}

export class Song {
    files: Map<string, string> = new Map<string, string>();
    paths: Array<string> = []; // in the order they were added
    config: SongConfig = new SongConfig();
    configDiagnostics: Diagnostics = new Diagnostics(SONG_YAML);
    songDiagnostics: Diagnostics = new Diagnostics(SONG_YAML);
    conductor: CheckedFile;
    channels: Array<ChannelSource> = [];
    patterns: Map<string, CheckedFile> = new Map<string, CheckedFile>();
    patternNames: Array<string> = [];
    instruments: Map<string, CheckedFile> = new Map<string, CheckedFile>();
    instrumentNames: Array<string> = [];
    context: CheckContext = new CheckContext();
    revision: i32 = 0;
    private cache: Map<string, Parsed> = new Map<string, Parsed>();

    constructor() {
        this.conductor = checkParsed(parseFile(CONDUCTOR_PATH, ""), FileKind.Conductor, this.context);
    }

    static fromFiles(files: Array<SongFile>): Song {
        let song = new Song();
        for (let i = 0; i < files.length; i++) {
            if (!song.files.has(files[i].path)) song.paths.push(files[i].path);
            song.files.set(files[i].path, files[i].text);
        }
        song.rebuild();
        return song;
    }

    text(path: string): string {
        return this.files.has(path) ? this.files.get(path) : "";
    }

    toFiles(): Array<SongFile> {
        let out = new Array<SongFile>();
        for (let i = 0; i < this.paths.length; i++) out.push(new SongFile(this.paths[i], this.files.get(this.paths[i])));
        return out;
    }

    // Replaces (or adds) one file and refreshes what depends on it.
    setFile(path: string, text: string): void {
        if (!this.files.has(path)) this.paths.push(path);
        this.files.set(path, text);
        this.rebuild();
    }

    removeFile(path: string): void {
        if (!this.files.has(path)) return;
        this.files.delete(path);
        let i = this.paths.indexOf(path);
        if (i >= 0) this.paths.splice(i, 1);
        this.rebuild();
    }

    // The checked file at `path`, if it is part of the song.
    checked(path: string): CheckedFile? {
        if (path == CONDUCTOR_PATH) return this.conductor;
        for (let i = 0; i < this.channels.length; i++) {
            if (this.channels[i].file.path == path) return this.channels[i].file;
        }
        let pattern = nameIn(path, PATTERNS_DIR, ".pat");
        if (pattern.length > 0 && this.patterns.has(pattern)) return this.patterns.get(pattern);
        let inst = nameIn(path, INSTRUMENTS_DIR, ".inst");
        if (inst.length > 0 && this.instruments.has(inst)) return this.instruments.get(inst);
        return null;
    }

    diagnostics(): Array<Diagnostic> {
        let out = new Array<Diagnostic>();
        append(out, this.configDiagnostics);
        append(out, this.songDiagnostics);
        append(out, this.conductor.diagnostics);
        for (let i = 0; i < this.channels.length; i++) append(out, this.channels[i].file.diagnostics);
        for (let i = 0; i < this.patternNames.length; i++) append(out, this.patterns.get(this.patternNames[i]).diagnostics);
        for (let i = 0; i < this.instrumentNames.length; i++) append(out, this.instruments.get(this.instrumentNames[i]).diagnostics);
        return out;
    }

    get errorCount(): i32 {
        let all = this.diagnostics();
        let n = 0;
        for (let i = 0; i < all.length; i++) if (all[i].isError) n++;
        return n;
    }

    // Rows in the tallest file the grid shows (conductor and channels).
    get rowCount(): i32 {
        let n = this.conductor.rowCount;
        for (let i = 0; i < this.channels.length; i++) n = max<i32>(n, this.channels[i].file.rowCount);
        return n;
    }

    private parse(path: string): Parsed {
        let text = this.text(path);
        if (this.cache.has(path)) {
            let hit = this.cache.get(path);
            if (hit.text == text) return hit;
        }
        let parsed = new Parsed(text, parseFile(path, text));
        this.cache.set(path, parsed);
        return parsed;
    }

    // Checks `path` as `kind`, reusing the last result while neither the text
    // nor the macros it may use have changed.
    private check(path: string, kind: FileKind, ctx: CheckContext): CheckedFile {
        let entry = this.parse(path);
        let key = `${kind}:${ctx.macros.join(",")}`;
        let hit = entry.checked;
        if (hit != null && entry.checkedWith == key) return hit;
        let checked = checkParsed(entry.file, kind, ctx);
        entry.checked = checked;
        entry.checkedWith = key;
        return checked;
    }

    private rebuild(): void {
        this.revision++;
        this.songDiagnostics = new Diagnostics(SONG_YAML);
        if (this.files.has(SONG_YAML)) {
            let result = parseSongConfig(this.files.get(SONG_YAML));
            this.config = result.config;
            this.configDiagnostics = result.diagnostics;
        } else {
            this.config = new SongConfig();
            this.configDiagnostics = new Diagnostics(SONG_YAML);
            this.configDiagnostics.error(1, 1, 1, "missing-file", "the song has no song.yaml; defaults are used");
        }

        // Instruments first: their macros are part of the context the rest is checked in.
        this.instruments = new Map<string, CheckedFile>();
        this.instrumentNames = [];
        this.patterns = new Map<string, CheckedFile>();
        this.patternNames = [];
        let ctx = new CheckContext();
        for (let i = 0; i < this.paths.length; i++) {
            let path = this.paths[i];
            let name = nameIn(path, INSTRUMENTS_DIR, ".inst");
            if (name.length == 0) continue;
            if (!isName(name)) {
                this.songDiagnostics.error(1, 1, 1, "config", `'${path}': instrument names use lowercase letters, digits and '_'`);
                continue;
            }
            let file = this.check(path, FileKind.Instrument, new CheckContext());
            this.instruments.set(name, file);
            this.instrumentNames.push(name);
            let commands = file.commands();
            for (let c = 0; c < commands.length; c++) {
                if (commands[c].name == "param") {
                    let macro = commands[c].str("name", "");
                    if (!ctx.macros.includes(macro)) ctx.macros.push(macro);
                }
            }
        }
        this.context = ctx;

        for (let i = 0; i < this.paths.length; i++) {
            let path = this.paths[i];
            let name = nameIn(path, PATTERNS_DIR, ".pat");
            if (name.length == 0) continue;
            if (!isName(name)) {
                this.songDiagnostics.error(1, 1, 1, "config", `'${path}': pattern names use lowercase letters, digits and '_'`);
                continue;
            }
            this.patterns.set(name, this.check(path, FileKind.Pattern, ctx));
            this.patternNames.push(name);
        }

        this.conductor = this.check(CONDUCTOR_PATH, FileKind.Conductor, ctx);

        this.channels = [];
        let channels = this.config.channels;
        for (let i = 0; i < channels.length; i++) {
            let c = channels[i];
            if (!this.files.has(c.file)) {
                this.songDiagnostics.error(c.line, 1, 1, "missing-file", `channel '${c.name}' reads '${c.file}', which the song does not have`);
            }
            if (c.file == CONDUCTOR_PATH) {
                this.songDiagnostics.error(c.line, 1, 1, "config", "conductor.ch is always the first column; it cannot also be a channel");
                continue;
            }
            this.channels.push(new ChannelSource(c, this.check(c.file, FileKind.Channel, ctx)));
        }
    }
}

function append(out: Array<Diagnostic>, d: Diagnostics): void {
    for (let i = 0; i < d.items.length; i++) out.push(d.items[i]);
}
