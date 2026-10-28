// Diagnostics: positioned errors and warnings reported against a song file.
// Lines and columns are 1-based; `endCol` is exclusive.

export enum Severity {
    Error = 0,
    Warning = 1,
}

export class Diagnostic {
    constructor(
        public path: string,
        public line: i32,
        public col: i32,
        public endCol: i32,
        public severity: Severity,
        public code: string,
        public message: string,
    ) {}

    get isError(): bool {
        return this.severity == Severity.Error;
    }

    toString(): string {
        let sev = this.isError ? "error" : "warning";
        return `${this.path}:${this.line}:${this.col} ${sev} ${this.code}: ${this.message}`;
    }
}

export class Diagnostics {
    items: Array<Diagnostic> = [];

    constructor(public path: string) {}

    error(line: i32, col: i32, endCol: i32, code: string, message: string): void {
        this.items.push(new Diagnostic(this.path, line, col, endCol, Severity.Error, code, message));
    }

    warning(line: i32, col: i32, endCol: i32, code: string, message: string): void {
        this.items.push(new Diagnostic(this.path, line, col, endCol, Severity.Warning, code, message));
    }

    get length(): i32 {
        return this.items.length;
    }

    get errorCount(): i32 {
        let n = 0;
        for (let i = 0; i < this.items.length; i++) {
            if (this.items[i].isError) n++;
        }
        return n;
    }

    // The codes in order, for tests: "syntax,unknown-arg".
    codes(): string {
        let out = "";
        for (let i = 0; i < this.items.length; i++) {
            if (i > 0) out += ",";
            out += this.items[i].code;
        }
        return out;
    }
}

// Edit distance, for "did you mean" suggestions.
export function editDistance(a: string, b: string): i32 {
    let n = a.length;
    let m = b.length;
    let prev = new Array<i32>(m + 1);
    let cur = new Array<i32>(m + 1);
    for (let j = 0; j <= m; j++) prev[j] = j;
    for (let i = 1; i <= n; i++) {
        cur[0] = i;
        for (let j = 1; j <= m; j++) {
            let cost = a.charCodeAt(i - 1) == b.charCodeAt(j - 1) ? 0 : 1;
            cur[j] = min<i32>(min<i32>(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
        }
        for (let j = 0; j <= m; j++) prev[j] = cur[j];
    }
    return prev[m];
}

// The closest candidate within a distance of 2 (or a third of the word), or "".
export function suggest(word: string, candidates: Array<string>): string {
    let best = "";
    let bestDistance = max<i32>(2, word.length / 3) + 1;
    for (let i = 0; i < candidates.length; i++) {
        let d = editDistance(word, candidates[i]);
        if (d < bestDistance) {
            bestDistance = d;
            best = candidates[i];
        }
    }
    if (best.length > 0) return best;
    // Otherwise a prefix either way: `pitch` for `p`.
    for (let i = 0; i < candidates.length; i++) {
        let c = candidates[i];
        if (c.length > 0 && (word.startsWith(c) || c.startsWith(word))) return c;
    }
    return best;
}

export function didYouMean(word: string, candidates: Array<string>): string {
    let s = suggest(word, candidates);
    return s.length > 0 ? ` — did you mean '${s}'?` : "";
}
