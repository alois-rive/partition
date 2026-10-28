// Syntax colouring for one line (docs/spec.md §10.4), from the language's own
// lexer so the editor and the compiler always agree.

import { lexLine, Tok } from "../lang/lexer";
import { parsePitch } from "../lang/types";

export enum Hue {
    Text = 0,
    Command,
    Arg,
    Pitch,
    Number,
    String,
    Punct,
    Error,
    Name,
}

export class Span {
    constructor(public start: i32, public end: i32, public hue: Hue) {}
}

// Spans covering the whole of `text` (0-based, end exclusive).
export function highlight(text: string): Array<Span> {
    let spans = new Array<Span>();
    let skip = text.length > 0 && text.charCodeAt(0) == 9 ? 1 : 0;
    let tokens = lexLine(skip == 1 ? text.substring(1) : text, 1);
    let pos = 0;
    for (let i = 0; i < tokens.length; i++) {
        let t = tokens[i];
        if (t.kind == Tok.End) break;
        let start = t.col - 1 + skip;
        let end = t.endCol - 1 + skip;
        if (start > pos) spans.push(new Span(pos, start, Hue.Text));
        let hue = Hue.Punct;
        if (t.kind == Tok.Word) {
            let next = i + 1 < tokens.length ? tokens[i + 1].kind : Tok.End;
            if (next == Tok.LParen) hue = Hue.Command;
            else if (next == Tok.Colon) hue = Hue.Arg;
            else if (t.text == "true" || t.text == "false") hue = Hue.Number;
            else if (parsePitch(t.text) != null) hue = Hue.Pitch;
            else hue = Hue.Name;
        } else if (t.kind == Tok.Number || t.kind == Tok.Fraction) {
            hue = Hue.Number;
        } else if (t.kind == Tok.String) {
            hue = Hue.String;
        } else if (t.kind == Tok.Error) {
            hue = Hue.Error;
        }
        spans.push(new Span(start, end, hue));
        pos = end;
    }
    if (pos < text.length) spans.push(new Span(pos, text.length, Hue.Text));
    return spans;
}
