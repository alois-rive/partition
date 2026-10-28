// Type checking: matches each parsed command against the registry and types
// its arguments (docs/spec.md §4.7). A command with an error is dropped from
// the checked rows; the rest of the file is unaffected.

import { ArgNode, CommandNode } from "./ast";
import { ArgSpec, CommandSpec, registry, SCOPE_CHANNEL, SCOPE_CONDUCTOR, SCOPE_INSTRUMENT } from "./commands";
import { Diagnostics, didYouMean } from "./diagnostics";
import { channelParamNames, conductorParamNames, ParamInfo, ParamKind, paramByName, ParamScope } from "./params";
import { ParsedFile, parseFile } from "./parser";
import { ArgType, Typed, typeValue } from "./types";

export enum FileKind {
    Channel,
    Conductor,
    Pattern,
    Instrument,
}

export function scopeOf(kind: FileKind): i32 {
    if (kind == FileKind.Conductor) return SCOPE_CONDUCTOR;
    if (kind == FileKind.Instrument) return SCOPE_INSTRUMENT;
    return SCOPE_CHANNEL;
}

function scopeName(scope: i32): string {
    if (scope == SCOPE_CONDUCTOR) return "conductor.ch";
    if (scope == SCOPE_INSTRUMENT) return "instrument files";
    return "channels and patterns";
}

// A parameter argument of `set` or `ramp`, or the `param:` of `lfo`.
export class ParamArg {
    constructor(
        public name: string,
        public info: ParamInfo?, // null for an instrument macro
        public value: Typed,
        public col: i32,
        public endCol: i32,
    ) {}
}

export class CheckedCommand {
    args: Map<string, Typed> = new Map<string, Typed>();
    params: Array<ParamArg> = [];

    constructor(public spec: CommandSpec, public node: CommandNode) {}

    get name(): string {
        return this.spec.name;
    }

    get line(): i32 {
        return this.node.line;
    }

    has(name: string): bool {
        return this.args.has(name);
    }

    get(name: string): Typed {
        return this.args.get(name);
    }

    num(name: string, fallback: f64): f64 {
        return this.args.has(name) ? this.args.get(name).num : fallback;
    }

    str(name: string, fallback: string): string {
        return this.args.has(name) ? this.args.get(name).str : fallback;
    }

    bool(name: string, fallback: bool): bool {
        return this.args.has(name) ? this.args.get(name).bool : fallback;
    }
}

export class CheckContext {
    // Macro parameter names declared by the song's instruments; they are valid
    // in `set`, `ramp` and `lfo` of channels.
    macros: Array<string> = [];
}

export class CheckedFile {
    rows: Array<Array<CheckedCommand>> = [];
    // The parse diagnostics followed by the checker's own; the parsed file's
    // list is left alone so a file can be checked again with a new context.
    diagnostics: Diagnostics;

    constructor(public kind: FileKind, public parsed: ParsedFile) {
        this.diagnostics = new Diagnostics(parsed.path);
        let items = parsed.diagnostics.items;
        for (let i = 0; i < items.length; i++) this.diagnostics.items.push(items[i]);
    }

    get path(): string {
        return this.parsed.path;
    }

    get rowCount(): i32 {
        return this.rows.length;
    }

    get usedRowCount(): i32 {
        return this.parsed.usedRowCount;
    }

    // Every checked command in order, ignoring rows (for instrument files).
    commands(): Array<CheckedCommand> {
        let out = new Array<CheckedCommand>();
        for (let r = 0; r < this.rows.length; r++) {
            let row = this.rows[r];
            for (let c = 0; c < row.length; c++) out.push(row[c]);
        }
        return out;
    }
}

export function paramArgType(kind: ParamKind): ArgType {
    if (kind == ParamKind.Gain) return ArgType.Gain;
    if (kind == ParamKind.Freq) return ArgType.Freq;
    if (kind == ParamKind.Time) return ArgType.Time;
    if (kind == ParamKind.Interval) return ArgType.Interval;
    return ArgType.Number;
}

class Checker {
    scope: i32;

    constructor(public kind: FileKind, public ctx: CheckContext, public diagnostics: Diagnostics) {
        this.scope = scopeOf(kind);
    }

    check(node: CommandNode): CheckedCommand? {
        let reg = registry();
        let spec = reg.get(node.name);
        let line = node.line;
        if (spec == null) {
            let hint = didYouMean(node.name, reg.namesIn(this.scope));
            this.diagnostics.error(line, node.col, node.nameEndCol, "unknown-command", `unknown command '${node.name}'${hint}`);
            return null;
        }
        if ((spec.scopes & this.scope) == 0) {
            let where = (spec.scopes & SCOPE_CONDUCTOR) != 0 ? "conductor.ch" : (spec.scopes & SCOPE_INSTRUMENT) != 0 ? "instrument files" : "channels and patterns";
            this.diagnostics.error(line, node.col, node.nameEndCol, "scope", `'${node.name}' is not allowed in ${scopeName(this.scope)}; it belongs in ${where}`);
            return null;
        }
        let checked = new CheckedCommand(spec, node);
        let ok = true;
        for (let i = 0; i < node.args.length; i++) {
            let arg = node.args[i];
            let argSpec = spec.arg(arg.name);
            if (argSpec == null) {
                if (spec.open) {
                    if (!this.checkParam(checked, arg)) ok = false;
                    continue;
                }
                let hint = didYouMean(arg.name, spec.argNames());
                this.diagnostics.error(line, arg.col, arg.endCol, "unknown-arg", `'${node.name}' has no argument '${arg.name}'${hint}`);
                ok = false;
                continue;
            }
            let value = this.typeArg(argSpec, arg, line);
            if (value == null) {
                ok = false;
            } else {
                checked.args.set(arg.name, value);
            }
        }
        for (let i = 0; i < spec.args.length; i++) {
            let a = spec.args[i];
            if (a.required && node.arg(a.name) == null) {
                this.diagnostics.error(line, node.col, node.endCol, "missing-arg", `'${node.name}' needs '${a.name}'`);
                ok = false;
            }
        }
        if (ok && spec.open && checked.params.length == 0) {
            this.diagnostics.error(line, node.col, node.endCol, "missing-arg", `'${node.name}' needs at least one parameter, such as ${node.name}(cutoff: 800${node.name == "ramp" ? ", over: 1bar" : ""})`);
            ok = false;
        }
        if (ok && node.name == "lfo") ok = this.checkLfoParam(checked);
        if (ok && node.name == "lfo_off") ok = this.checkLfoParam(checked);
        if (ok && node.name == "sig") ok = this.checkSignature(checked);
        return ok ? checked : null;
    }

    typeArg(spec: ArgSpec, arg: ArgNode, line: i32): Typed? {
        let v = arg.value;
        let r = typeValue(v, spec.type);
        let value = r.value;
        if (value == null) {
            this.diagnostics.error(line, v.col, v.endCol, "type", `'${arg.name}': ${r.error}`);
            return null;
        }
        if (spec.choices.length > 0 && !spec.choices.includes(value.str)) {
            let hint = didYouMean(value.str, spec.choices);
            this.diagnostics.error(line, v.col, v.endCol, "range", `'${arg.name}' must be one of ${spec.choices.join(", ")}${hint}`);
            return null;
        }
        if (!this.inRange(value, spec.min, spec.max, spec.integer)) {
            this.diagnostics.error(line, v.col, v.endCol, "range", `'${arg.name}' ${rangeText(spec.min, spec.max, spec.integer)}`);
            return null;
        }
        return value;
    }

    inRange(value: Typed, lo: f64, hi: f64, integer: bool): bool {
        let t = value.type;
        let numeric = t == ArgType.Number || t == ArgType.Gain || t == ArgType.Freq || t == ArgType.Interval || t == ArgType.Time || t == ArgType.Phase;
        if (!numeric) return true;
        if (integer && value.num != Math.floor(value.num)) return false;
        return value.num >= lo && value.num <= hi;
    }

    resolveParam(name: string): ParamInfo? {
        let info = paramByName(name);
        if (info == null) return null;
        let allowed = this.scope == SCOPE_CONDUCTOR ? info.scope == ParamScope.Conductor : info.scope != ParamScope.Conductor;
        return allowed ? info : null;
    }

    paramNames(): Array<string> {
        if (this.scope == SCOPE_CONDUCTOR) return conductorParamNames();
        let names = channelParamNames();
        for (let i = 0; i < this.ctx.macros.length; i++) names.push(this.ctx.macros[i]);
        return names;
    }

    checkParam(checked: CheckedCommand, arg: ArgNode): bool {
        let line = checked.node.line;
        let info = this.resolveParam(arg.name);
        let isMacro = info == null && this.scope == SCOPE_CHANNEL && this.ctx.macros.includes(arg.name);
        if (info == null && !isMacro) {
            let hint = didYouMean(arg.name, this.paramNames());
            let other = paramByName(arg.name);
            if (other != null) {
                this.diagnostics.error(line, arg.col, arg.endCol, "scope", `parameter '${arg.name}' is not available in ${scopeName(this.scope)}`);
            } else {
                this.diagnostics.error(line, arg.col, arg.endCol, "unknown-arg", `unknown parameter '${arg.name}'${hint}`);
            }
            return false;
        }
        let type = info != null ? paramArgType(info.kind) : ArgType.Number;
        let r = typeValue(arg.value, type);
        let value = r.value;
        if (value == null) {
            this.diagnostics.error(line, arg.value.col, arg.value.endCol, "type", `'${arg.name}': ${r.error}`);
            return false;
        }
        if (info != null && !this.inRange(value, info.min, info.max, false)) {
            this.diagnostics.error(line, arg.value.col, arg.value.endCol, "range", `'${arg.name}' ${rangeText(info.min, info.max, false)}`);
            return false;
        }
        checked.params.push(new ParamArg(arg.name, info, value, arg.col, arg.endCol));
        return true;
    }

    checkLfoParam(checked: CheckedCommand): bool {
        let value = checked.get("param");
        let name = value.str;
        let info = this.resolveParam(name);
        if (info == null && !this.ctx.macros.includes(name)) {
            let hint = didYouMean(name, this.paramNames());
            this.diagnostics.error(checked.line, value.col, value.endCol, "unknown-arg", `unknown parameter '${name}'${hint}`);
            return false;
        }
        checked.params.push(new ParamArg(name, info, value, value.col, value.endCol));
        return true;
    }

    checkSignature(checked: CheckedCommand): bool {
        let v = checked.get("v");
        let num = v.num;
        let den = v.num2;
        let denOk = den == 1 || den == 2 || den == 4 || den == 8 || den == 16 || den == 32;
        if (num < 1 || num > 32 || !denOk) {
            this.diagnostics.error(checked.line, v.col, v.endCol, "range", "a signature is 1..32 over 1, 2, 4, 8, 16 or 32");
            return false;
        }
        return true;
    }
}

function fmt(x: f64): string {
    if (x == Math.floor(x) && Math.abs(x) < 1e9) return (<i64>x).toString();
    return x.toString();
}

function rangeText(lo: f64, hi: f64, integer: bool): string {
    let whole = integer ? "a whole number " : "";
    if (lo == -Infinity) return `must be ${whole}at most ${fmt(hi)}`;
    if (hi == Infinity) return `must be ${whole}at least ${fmt(lo)}`;
    return `must be ${whole}between ${fmt(lo)} and ${fmt(hi)}`;
}

export function checkParsed(parsed: ParsedFile, kind: FileKind, ctx: CheckContext): CheckedFile {
    let file = new CheckedFile(kind, parsed);
    let checker = new Checker(kind, ctx, file.diagnostics);
    for (let r = 0; r < parsed.rows.length; r++) {
        let row = parsed.rows[r];
        let out = new Array<CheckedCommand>();
        for (let c = 0; c < row.commands.length; c++) {
            let checked = checker.check(row.commands[c]);
            if (checked != null) out.push(checked);
        }
        file.rows.push(out);
    }
    return file;
}

export function checkSource(path: string, text: string, kind: FileKind, ctx: CheckContext = new CheckContext()): CheckedFile {
    return checkParsed(parseFile(path, text), kind, ctx);
}
