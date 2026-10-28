// Time-aligned rows across columns (docs/spec.md §10.2). Each source row is a
// band as tall as the most lines any column gives that row, so line N of every
// column sits at the same height even when some rows have continuation lines.

import { isContinuation } from "../lang/source";

// Where each line of one column sits: its band and its line within the band.
export class ColumnMap {
    band: Array<i32> = [];
    sub: Array<i32> = [];
    // For each band, the column's first line in it (-1: none) and how many.
    firstLine: Array<i32> = [];
    lineCount: Array<i32> = [];

    static build(lines: Array<string>): ColumnMap {
        let m = new ColumnMap();
        let band = 0;
        let sub = 0;
        let started = false;
        for (let i = 0; i < lines.length; i++) {
            if (!isContinuation(lines[i]) && started) {
                band++;
                sub = 0;
            }
            if (!isContinuation(lines[i])) started = true;
            m.band.push(band);
            m.sub.push(sub);
            while (m.firstLine.length <= band) {
                m.firstLine.push(-1);
                m.lineCount.push(0);
            }
            if (m.firstLine[band] < 0) m.firstLine[band] = i;
            m.lineCount[band]++;
            sub++;
        }
        return m;
    }

    get bands(): i32 {
        return this.firstLine.length;
    }
}

export class Bands {
    heights: Array<i32> = []; // in text lines
    tops: Array<i32> = []; // first text line of each band, in grid lines

    // `extra` empty bands follow the last one, so there is room to type.
    static build(columns: Array<ColumnMap>, extra: i32): Bands {
        let b = new Bands();
        let count = 0;
        for (let c = 0; c < columns.length; c++) count = max<i32>(count, columns[c].bands);
        count += extra;
        let top = 0;
        for (let r = 0; r < count; r++) {
            let h = 1;
            for (let c = 0; c < columns.length; c++) {
                let m = columns[c];
                if (r < m.bands) h = max<i32>(h, m.lineCount[r]);
            }
            b.heights.push(h);
            b.tops.push(top);
            top += h;
        }
        return b;
    }

    // `count` bands one line each: the compact overview, where no column shows text.
    static uniform(count: i32): Bands {
        let b = new Bands();
        for (let r = 0; r < count; r++) {
            b.heights.push(1);
            b.tops.push(r);
        }
        return b;
    }

    get count(): i32 {
        return this.heights.length;
    }

    get totalLines(): i32 {
        let n = this.heights.length;
        return n == 0 ? 0 : this.tops[n - 1] + this.heights[n - 1];
    }

    // The band holding grid line `gridLine`.
    bandAt(gridLine: i32): i32 {
        let lo = 0;
        let hi = this.heights.length - 1;
        if (hi < 0) return 0;
        if (gridLine <= 0) return 0;
        while (lo < hi) {
            let mid = (lo + hi + 1) >> 1;
            if (this.tops[mid] <= gridLine) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }
}
