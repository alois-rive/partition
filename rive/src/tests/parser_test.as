import { Expect, Tests } from "rive/test";
import { lexLine, Tok, Token } from "../lang/lexer";
import { parseFile, parseLine } from "../lang/parser";
import { Diagnostics } from "../lang/diagnostics";
import { ValueKind } from "../lang/ast";
import { splitLines, layoutRows } from "../lang/source";

@editTime
function kinds(tokens: Array<Token>): string {
    let out = "";
    for (let i = 0; i < tokens.length; i++) {
        let t = tokens[i];
        if (i > 0) out += " ";
        if (t.kind == Tok.Word) out += `W(${t.text})`;
        else if (t.kind == Tok.Number) out += `N(${t.num}${t.unit})`;
        else if (t.kind == Tok.Fraction) out += `F(${t.num}/${t.den})`;
        else if (t.kind == Tok.String) out += `S(${t.str})`;
        else if (t.kind == Tok.Error) out += "ERR";
        else if (t.kind == Tok.End) out += "$";
        else out += t.text;
    }
    return out;
}

@editTime
function expectTokens(expect: Expect, text: string, want: string): void {
    expect.that(kinds(lexLine(text))).is(want);
}

export class ParserTests extends Tests {
    override run(): void {
        group("source", () => {
            test("splits LF and CRLF, no trailing empty line", (expect) => {
                expect.that(splitLines("a\nb\n").length).is(2);
                expect.that(splitLines("a\r\nb").join("|")).is("a|b");
                expect.that(splitLines("").length).is(0);
                expect.that(splitLines("a\n\n").join("|")).is("a|");
            });
            test("continuation lines join the row above", (expect) => {
                let layout = layoutRows(splitLines("a\n\tb\n\tc\nd\n\n"));
                expect.that(layout.rows.length).is(3);
                expect.that(layout.rows[0].lineCount).is(3);
                expect.that(layout.rows[1].firstLine).is(4);
                expect.that(layout.rows[2].firstLine).is(5);
                expect.that(layout.rowOfLine[2]).is(0);
            });
            test("orphan continuation at the top", (expect) => {
                let layout = layoutRows(splitLines("\tx\na"));
                expect.that(layout.orphans.length).is(1);
                expect.that(layout.rows.length).is(1);
            });
        });

        group("lexer", () => {
            test("command", (expect) => {
                expectTokens(expect, "note(p: C4, len: 2)", "W(note) ( W(p) : W(C4) , W(len) : N(2.0) ) $");
            });
            test("units and signs", (expect) => {
                expectTokens(expect, "-6dB 2k 80% 1.5s +3st .5 2bar 250ms 1b", "N(-6.0dB) N(2.0k) N(80.0%) N(1.5s) N(3.0st) N(0.5) N(2.0bar) N(250.0ms) N(1.0b) $");
            });
            test("fractions", (expect) => {
                expectTokens(expect, "1/4 3/16", "F(1.0/4.0) F(3.0/16.0) $");
            });
            test("pitches and dotted names", (expect) => {
                expectTokens(expect, "F#3 Bb2 C-1 osc2.level", "W(F#3) W(Bb2) W(C-1) W(osc2.level) $");
            });
            test("strings with escapes", (expect) => {
                expectTokens(expect, "\"a \\\"b\\\"\"", "S(a \"b\") $");
            });
            test("errors", (expect) => {
                expectTokens(expect, "2xyz", "ERR $");
                expectTokens(expect, "\"open", "ERR $");
                expectTokens(expect, "1/0", "ERR $");
                expectTokens(expect, "@", "ERR $");
            });
            test("columns are 1-based and exclusive at the end", (expect) => {
                let toks = lexLine("  vol(v: 1)", 1);
                expect.that(toks[0].col).is(3);
                expect.that(toks[0].endCol).is(6);
                let cont = lexLine("x", 2);
                expect.that(cont[0].col).is(2);
            });
        });

        group("parser", () => {
            test("statements and args", (expect) => {
                let d = new Diagnostics("t.ch");
                let cmds = parseLine("note(p: C4, len: 2); vol(v: 0.8);", 1, 1, d);
                expect.that(d.length).is(0);
                expect.that(cmds.length).is(2);
                expect.that(cmds[0].name).is("note");
                expect.that(cmds[0].args.length).is(2);
                expect.that(cmds[0].args[1].name).is("len");
                expect.that(cmds[0].args[1].value.num).is(2);
                expect.that(cmds[1].endCol).is(33);
            });
            test("empty statements, trailing comma, no args", (expect) => {
                let d = new Diagnostics("t.ch");
                let cmds = parseLine(";; cut() ; note(p: C4,) ;", 1, 1, d);
                expect.that(d.length).is(0);
                expect.that(cmds.length).is(2);
                expect.that(cmds[0].args.length).is(0);
            });
            test("lists", (expect) => {
                let d = new Diagnostics("t.ch");
                let cmds = parseLine("note(p: [C4, Eb4, G4])", 1, 1, d);
                expect.that(d.length).is(0);
                let v = cmds[0].args[0].value;
                expect.that(v.kind == ValueKind.List).is(true);
                expect.that(v.items.length).is(3);
                expect.that(v.text).is("[C4, Eb4, G4]");
            });
            test("syntax error skips only its statement", (expect) => {
                let d = new Diagnostics("t.ch");
                let cmds = parseLine("note(p C4); vol(v: 1)", 3, 1, d);
                expect.that(d.codes()).is("syntax");
                expect.that(d.items[0].line).is(3);
                expect.that(d.items[0].col).is(8);
                expect.that(cmds.length).is(1);
                expect.that(cmds[0].name).is("vol");
            });
            test("missing separator", (expect) => {
                let d = new Diagnostics("t.ch");
                let cmds = parseLine("cut() cut()", 1, 1, d);
                expect.that(d.codes()).is("syntax");
                expect.that(cmds.length).is(0);
            });
            test("duplicate arg", (expect) => {
                let d = new Diagnostics("t.ch");
                let cmds = parseLine("note(p: C4, p: D4)", 1, 1, d);
                expect.that(d.codes()).is("duplicate-arg");
                expect.that(cmds[0].args.length).is(1);
            });
            test("uppercase command is a syntax error", (expect) => {
                let d = new Diagnostics("t.ch");
                parseLine("Note(p: C4)", 1, 1, d);
                expect.that(d.codes()).is("syntax");
            });
            test("unclosed", (expect) => {
                let d = new Diagnostics("t.ch");
                parseLine("note(p: C4", 1, 1, d);
                expect.that(d.codes()).is("syntax");
            });
            test("file rows with continuations", (expect) => {
                let f = parseFile("t.ch", "note(p: C2)\nnote(p: E2); vol(v: 0.6)\n\tset(cutoff: 800)\n\n\t\nnote(p: G2)\n");
                expect.that(f.diagnostics.length).is(0);
                expect.that(f.rows.length).is(4);
                expect.that(f.rows[1].commands.length).is(3);
                expect.that(f.rows[1].commands[2].col).is(2);
                expect.that(f.rows[1].commands[2].line).is(3);
                expect.that(f.rows[2].isEmpty).is(true);
                expect.that(f.rows[2].lineCount).is(2);
                expect.that(f.usedRowCount).is(4);
            });
            test("orphan continuation", (expect) => {
                let f = parseFile("t.ch", "\tnote(p: C2)\nvol(v: 1)\n\n");
                expect.that(f.diagnostics.codes()).is("orphan-continuation");
                expect.that(f.rows.length).is(2);
                expect.that(f.usedRowCount).is(1);
            });
        });
    }
}
