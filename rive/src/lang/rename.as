// Renaming a pattern or an instrument: the references to it in a file's text.
// Works on the language's tokens, so only real references change: the `name:`
// of `pattern(…)` for a pattern; the `name:` of `inst(…)` and any `inst:`
// argument (a note's override) for an instrument.

import { lexLine, Tok } from "./lexer";

export function renameReferences(text: string, from: string, to: string, pattern: bool): string {
    let lines = text.split("\n");
    let changed = false;
    for (let l = 0; l < lines.length; l++) {
        let line = lines[l];
        let tokens = lexLine(line, 1);
        let command = "";
        let starts = new Array<i32>();
        let ends = new Array<i32>();
        for (let i = 0; i < tokens.length; i++) {
            let t = tokens[i];
            if (t.kind == Tok.Semi) command = "";
            if (t.kind != Tok.Word || i + 1 >= tokens.length) continue;
            let next = tokens[i + 1].kind;
            if (next == Tok.LParen) {
                command = t.text;
                continue;
            }
            if (next != Tok.Colon || i + 2 >= tokens.length) continue;
            let value = tokens[i + 2];
            if (value.kind != Tok.Word || value.text != from) continue;
            let arg = t.text;
            let matches = pattern ? command == "pattern" && arg == "name" : (command == "inst" && arg == "name") || arg == "inst";
            if (matches) {
                starts.push(value.col - 1);
                ends.push(value.endCol - 1);
            }
        }
        // Right to left, so earlier positions stay valid.
        for (let k = starts.length - 1; k >= 0; k--) {
            line = line.substring(0, starts[k]) + to + line.substring(ends[k]);
            changed = true;
        }
        lines[l] = line;
    }
    return changed ? lines.join("\n") : text;
}
