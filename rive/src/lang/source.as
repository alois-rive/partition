// Splitting text into lines and rows (docs/spec.md §4.1).
//
// Every line that does not start with a tab begins a row; a line that starts
// with a tab continues the row above it.

export const TAB: i32 = 9;

// Splits on LF or CRLF. A final line ending does not start an extra line, so
// "a\nb\n" is two lines and "" is none.
export function splitLines(text: string): Array<string> {
    let lines = new Array<string>();
    let start = 0;
    let n = text.length;
    for (let i = 0; i < n; i++) {
        if (text.charCodeAt(i) == 10) {
            let end = i;
            if (end > start && text.charCodeAt(end - 1) == 13) end--;
            lines.push(text.substring(start, end));
            start = i + 1;
        }
    }
    if (start < n) {
        let end = n;
        if (text.charCodeAt(end - 1) == 13) end--;
        lines.push(text.substring(start, end));
    }
    return lines;
}

export function isContinuation(line: string): bool {
    return line.length > 0 && line.charCodeAt(0) == TAB;
}

// One time step: its first line and the continuation lines under it.
export class RowSpan {
    constructor(
        public index: i32, // 0-based row index
        public firstLine: i32, // 1-based line number
        public lineCount: i32,
    ) {}
}

export class RowLayout {
    rows: Array<RowSpan> = [];
    // 1-based numbers of the continuation lines at the top of the file.
    orphans: Array<i32> = [];
    // For each 0-based line index, the row it belongs to, or -1 for an orphan.
    rowOfLine: Array<i32> = [];
}

export function layoutRows(lines: Array<string>): RowLayout {
    let layout = new RowLayout();
    for (let i = 0; i < lines.length; i++) {
        if (isContinuation(lines[i])) {
            if (layout.rows.length == 0) {
                layout.orphans.push(i + 1);
                layout.rowOfLine.push(-1);
            } else {
                let row = layout.rows[layout.rows.length - 1];
                row.lineCount++;
                layout.rowOfLine.push(row.index);
            }
        } else {
            let index = layout.rows.length;
            layout.rows.push(new RowSpan(index, i + 1, 1));
            layout.rowOfLine.push(index);
        }
    }
    return layout;
}
