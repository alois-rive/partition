// Parser for the channel language (docs/spec.md §4.2–§4.3).
//
//   command = ident "(" [ arg { "," arg } [ "," ] ] ")"
//   arg     = ident ":" value
//   value   = list | scalar
//
// Statements are separated by ';' and never span lines. A statement with a
// syntax error is reported once and skipped up to the next ';', so the rest
// of the line still parses.

import { ArgNode, CommandNode, ParsedRow, ValueKind, ValueNode } from "./ast";
import { Diagnostics } from "./diagnostics";
import { lexLine, Tok, Token } from "./lexer";
import { layoutRows, splitLines } from "./source";

export class ParsedFile {
    rows: Array<ParsedRow> = [];
    lines: Array<string> = [];
    diagnostics: Diagnostics;

    constructor(public path: string) {
        this.diagnostics = new Diagnostics(path);
    }

    get rowCount(): i32 {
        return this.rows.length;
    }

    // Rows up to and including the last one holding a command.
    get usedRowCount(): i32 {
        for (let i = this.rows.length - 1; i >= 0; i--) {
            if (!this.rows[i].isEmpty) return i + 1;
        }
        return 0;
    }
}

class SyntaxError {
    constructor(public token: Token, public message: string) {}
}

class LineParser {
    tokens: Array<Token>;
    pos: i32 = 0;
    error: SyntaxError? = null;

    constructor(public text: string, public line: i32, public startCol: i32, public diagnostics: Diagnostics) {
        this.tokens = lexLine(text, startCol);
    }

    get peek(): Token {
        return this.tokens[this.pos];
    }

    advance(): Token {
        let t = this.tokens[this.pos];
        if (t.kind != Tok.End) this.pos++;
        return t;
    }

    fail(token: Token, message: string): void {
        if (this.error == null) this.error = new SyntaxError(token, message);
    }

    expect(kind: Tok, what: string): Token? {
        let t = this.peek;
        if (t.kind == kind) return this.advance();
        this.fail(t, this.unexpected(t, what));
        return null;
    }

    unexpected(t: Token, what: string): string {
        if (t.kind == Tok.Error) return t.error;
        if (t.kind == Tok.End) return `expected ${what} before the end of the line`;
        return `expected ${what}, found '${t.text}'`;
    }

    parseStatements(): Array<CommandNode> {
        let commands = new Array<CommandNode>();
        while (true) {
            let t = this.peek;
            if (t.kind == Tok.End) break;
            if (t.kind == Tok.Semi) {
                this.advance();
                continue;
            }
            this.error = null;
            let command = this.parseCommand();
            let error = this.error;
            if (error == null) {
                let after = this.peek;
                if (after.kind != Tok.Semi && after.kind != Tok.End) {
                    this.fail(after, after.kind == Tok.Error ? after.error : `expected ';' between commands, found '${after.text}'`);
                }
            }
            error = this.error;
            if (error != null) {
                let tok = error.token;
                let endCol = tok.endCol > tok.col ? tok.endCol : tok.col + 1;
                this.diagnostics.error(this.line, tok.col, endCol, "syntax", error.message);
                while (this.peek.kind != Tok.Semi && this.peek.kind != Tok.End) this.advance();
            } else if (command != null) {
                commands.push(command);
            }
        }
        return commands;
    }

    parseCommand(): CommandNode? {
        let nameTok = this.peek;
        if (nameTok.kind != Tok.Word || !isIdent(nameTok.text, false)) {
            this.fail(nameTok, this.unexpected(nameTok, "a command name"));
            return null;
        }
        this.advance();
        let command = new CommandNode();
        command.name = nameTok.text;
        command.line = this.line;
        command.col = nameTok.col;
        command.nameEndCol = nameTok.endCol;
        if (this.expect(Tok.LParen, `'(' after '${nameTok.text}'`) == null) return null;
        while (this.peek.kind != Tok.RParen) {
            let argTok = this.peek;
            if (argTok.kind != Tok.Word || !isIdent(argTok.text, true)) {
                this.fail(argTok, this.unexpected(argTok, "an argument name or ')'"));
                return null;
            }
            this.advance();
            if (this.expect(Tok.Colon, `':' after '${argTok.text}'`) == null) return null;
            let value = this.parseValue();
            if (value == null) return null;
            if (command.arg(argTok.text) != null) {
                this.diagnostics.error(this.line, argTok.col, argTok.endCol, "duplicate-arg", `'${argTok.text}' is given twice`);
            } else {
                command.args.push(new ArgNode(argTok.text, argTok.col, argTok.endCol, value));
            }
            if (this.peek.kind == Tok.Comma) {
                this.advance();
            } else if (this.peek.kind != Tok.RParen) {
                this.fail(this.peek, this.unexpected(this.peek, "',' or ')'"));
                return null;
            }
        }
        command.endCol = this.advance().endCol;
        return command;
    }

    parseValue(): ValueNode? {
        let t = this.peek;
        if (t.kind == Tok.LBracket) {
            this.advance();
            let list = new ValueNode();
            list.kind = ValueKind.List;
            list.col = t.col;
            while (this.peek.kind != Tok.RBracket) {
                let item = this.parseScalar();
                if (item == null) return null;
                list.items.push(item);
                if (this.peek.kind == Tok.Comma) {
                    this.advance();
                } else if (this.peek.kind != Tok.RBracket) {
                    this.fail(this.peek, this.unexpected(this.peek, "',' or ']'"));
                    return null;
                }
            }
            list.endCol = this.advance().endCol;
            list.text = this.text.substring(list.col - this.startCol, list.endCol - this.startCol);
            return list;
        }
        return this.parseScalar();
    }

    parseScalar(): ValueNode? {
        let t = this.peek;
        let v = new ValueNode();
        v.col = t.col;
        v.endCol = t.endCol;
        v.text = t.text;
        if (t.kind == Tok.Word) {
            v.kind = ValueKind.Word;
        } else if (t.kind == Tok.Number) {
            v.kind = ValueKind.Number;
            v.num = t.num;
            v.unit = t.unit;
        } else if (t.kind == Tok.Fraction) {
            v.kind = ValueKind.Fraction;
            v.num = t.num;
            v.den = t.den;
        } else if (t.kind == Tok.String) {
            v.kind = ValueKind.String;
            v.text = t.str;
        } else {
            this.fail(t, this.unexpected(t, "a value"));
            return null;
        }
        this.advance();
        return v;
    }
}

// Command names are lowercase identifiers; argument names may also hold dots
// (`osc2.level`).
export function isIdent(text: string, allowDots: bool): bool {
    if (text.length == 0) return false;
    for (let i = 0; i < text.length; i++) {
        let c = text.charCodeAt(i);
        let ok = (c >= 97 && c <= 122) || c == 95 || (i > 0 && c >= 48 && c <= 57) || (allowDots && i > 0 && c == 46);
        if (!ok) return false;
    }
    return true;
}

// Parses the statements of one line. A continuation line is passed without
// its leading tab, with `startCol` 2.
export function parseLine(text: string, line: i32, startCol: i32, diagnostics: Diagnostics): Array<CommandNode> {
    let parser = new LineParser(text, line, startCol, diagnostics);
    return parser.parseStatements();
}

export function parseFile(path: string, text: string): ParsedFile {
    let file = new ParsedFile(path);
    let lines = splitLines(text);
    file.lines = lines;
    let layout = layoutRows(lines);
    for (let i = 0; i < layout.orphans.length; i++) {
        let line = layout.orphans[i];
        file.diagnostics.error(line, 1, 2, "orphan-continuation", "a line starting with a tab continues the row above, but there is none");
    }
    for (let r = 0; r < layout.rows.length; r++) {
        let span = layout.rows[r];
        let row = new ParsedRow(span.index, span.firstLine, span.lineCount);
        for (let k = 0; k < span.lineCount; k++) {
            let lineNo = span.firstLine + k;
            let text = lines[lineNo - 1];
            let commands = k == 0
                ? parseLine(text, lineNo, 1, file.diagnostics)
                : parseLine(text.substring(1), lineNo, 2, file.diagnostics);
            for (let c = 0; c < commands.length; c++) row.commands.push(commands[c]);
        }
        file.rows.push(row);
    }
    return file;
}
