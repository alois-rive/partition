// Tokens of one line of the channel language (docs/spec.md §4.3).
//
// Statements never span lines, so each line is lexed on its own. Columns are
// 1-based and `endCol` is exclusive.

export enum Tok {
    Word, // C4, saw, osc2.level, true
    Number, // 0.5, -6dB, 2k, 1b, 80%
    Fraction, // 1/4
    String, // "Verse A"
    LParen,
    RParen,
    LBracket,
    RBracket,
    Colon,
    Comma,
    Semi,
    Error,
    End,
}

export const UNITS: Array<string> = ["%", "dB", "Hz", "k", "ms", "s", "b", "bar", "c", "st"];

export class Token {
    kind: Tok = Tok.End;
    text: string = "";
    col: i32 = 0;
    endCol: i32 = 0;
    num: f64 = 0; // a number's value, or a fraction's numerator
    den: f64 = 1; // a fraction's denominator
    unit: string = ""; // a number's unit suffix, "" for none
    str: string = ""; // a string's decoded value
    error: string = ""; // why an Error token is one
}

function isDigit(c: i32): bool {
    return c >= 48 && c <= 57;
}

function isLetter(c: i32): bool {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

// '$' starts a pattern variable, as in $root (§8.1).
function isWordStart(c: i32): bool {
    return isLetter(c) || c == 95 || c == 36;
}

function isWordPart(c: i32): bool {
    return isLetter(c) || isDigit(c) || c == 95 || c == 35 || c == 46;
}

function isSpace(c: i32): bool {
    return c == 32 || c == 9 || c == 13;
}

function punct(c: i32): Tok {
    if (c == 40) return Tok.LParen;
    if (c == 41) return Tok.RParen;
    if (c == 91) return Tok.LBracket;
    if (c == 93) return Tok.RBracket;
    if (c == 58) return Tok.Colon;
    if (c == 44) return Tok.Comma;
    if (c == 59) return Tok.Semi;
    return Tok.Error;
}

export function tokName(kind: Tok): string {
    switch (kind) {
        case Tok.Word: return "a name";
        case Tok.Number: return "a number";
        case Tok.Fraction: return "a fraction";
        case Tok.String: return "a string";
        case Tok.LParen: return "'('";
        case Tok.RParen: return "')'";
        case Tok.LBracket: return "'['";
        case Tok.RBracket: return "']'";
        case Tok.Colon: return "':'";
        case Tok.Comma: return "','";
        case Tok.Semi: return "';'";
        case Tok.End: return "end of line";
        default: return "an invalid character";
    }
}

// Lexes `text`, numbering columns from `startCol` for its first character.
// The result always ends with an End token.
export function lexLine(text: string, startCol: i32 = 1): Array<Token> {
    let tokens = new Array<Token>();
    let n = text.length;
    let i = 0;
    while (i < n) {
        let c = text.charCodeAt(i);
        if (isSpace(c)) {
            i++;
            continue;
        }
        let tok = new Token();
        tok.col = startCol + i;
        let start = i;
        let next = i + 1 < n ? text.charCodeAt(i + 1) : 0;
        let afterNext = i + 2 < n ? text.charCodeAt(i + 2) : 0;
        let signed = (c == 45 || c == 43) && (isDigit(next) || (next == 46 && isDigit(afterNext)));
        if (isDigit(c) || signed || (c == 46 && isDigit(next))) {
            i = lexNumber(text, i, tok);
        } else if (isWordStart(c)) {
            i++;
            while (i < n) {
                let d = text.charCodeAt(i);
                // '-' belongs to a word only before a digit, as in C-1.
                if (isWordPart(d) || (d == 45 && i + 1 < n && isDigit(text.charCodeAt(i + 1)))) {
                    i++;
                } else {
                    break;
                }
            }
            tok.kind = Tok.Word;
        } else if (c == 34) {
            i = lexString(text, i, tok);
        } else {
            tok.kind = punct(c);
            if (tok.kind == Tok.Error) tok.error = `unexpected character '${String.fromCharCode(c)}'`;
            i++;
        }
        tok.text = text.substring(start, i);
        tok.endCol = startCol + i;
        tokens.push(tok);
    }
    let end = new Token();
    end.kind = Tok.End;
    end.col = startCol + n;
    end.endCol = end.col;
    tokens.push(end);
    return tokens;
}

function lexNumber(text: string, i: i32, tok: Token): i32 {
    let n = text.length;
    let start = i;
    let sign = 1.0;
    let c = text.charCodeAt(i);
    if (c == 45 || c == 43) {
        if (c == 45) sign = -1;
        i++;
    }
    let digitsStart = i;
    while (i < n && isDigit(text.charCodeAt(i))) i++;
    let intEnd = i;
    // A fraction: digits '/' digits, unsigned and without decimals.
    if (i < n && text.charCodeAt(i) == 47 && intEnd > digitsStart && start == digitsStart) {
        let denStart = i + 1;
        let j = denStart;
        while (j < n && isDigit(text.charCodeAt(j))) j++;
        if (j > denStart) {
            tok.kind = Tok.Fraction;
            tok.num = parseFloat(text.substring(digitsStart, intEnd));
            tok.den = parseFloat(text.substring(denStart, j));
            if (tok.den == 0) {
                tok.kind = Tok.Error;
                tok.error = "a fraction cannot have a zero denominator";
            }
            return j;
        }
    }
    if (i < n && text.charCodeAt(i) == 46) {
        i++;
        while (i < n && isDigit(text.charCodeAt(i))) i++;
    }
    tok.kind = Tok.Number;
    tok.num = sign * parseFloat(text.substring(digitsStart, i));
    let unitStart = i;
    while (i < n && (isLetter(text.charCodeAt(i)) || text.charCodeAt(i) == 37)) i++;
    if (i > unitStart) {
        let unit = text.substring(unitStart, i);
        if (UNITS.includes(unit)) {
            tok.unit = unit;
        } else {
            tok.kind = Tok.Error;
            tok.error = `unknown unit '${unit}' (expected one of ${UNITS.join(", ")})`;
        }
    }
    return i;
}

function lexString(text: string, i: i32, tok: Token): i32 {
    let n = text.length;
    i++;
    let value = "";
    while (i < n) {
        let c = text.charCodeAt(i);
        if (c == 34) {
            tok.kind = Tok.String;
            tok.str = value;
            return i + 1;
        }
        if (c == 92 && i + 1 < n) {
            let e = text.charCodeAt(i + 1);
            value += e == 110 ? "\n" : String.fromCharCode(e);
            i += 2;
            continue;
        }
        value += String.fromCharCode(c);
        i++;
    }
    tok.kind = Tok.Error;
    tok.error = "unterminated string";
    return n;
}
