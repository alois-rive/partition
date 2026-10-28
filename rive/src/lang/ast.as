// Syntax tree of the channel language: rows of commands with named arguments.
// Values stay untyped here; check.as types them against command specs.

export enum ValueKind {
    Word,
    Number,
    Fraction,
    String,
    List,
}

export class ValueNode {
    kind: ValueKind = ValueKind.Word;
    text: string = ""; // source text (a string's decoded value for String)
    num: f64 = 0; // Number value, or Fraction numerator
    den: f64 = 1; // Fraction denominator
    unit: string = ""; // Number unit suffix
    items: Array<ValueNode> = []; // List items
    col: i32 = 0;
    endCol: i32 = 0;
}

export class ArgNode {
    constructor(
        public name: string,
        public col: i32,
        public endCol: i32, // end of the name
        public value: ValueNode,
    ) {}
}

export class CommandNode {
    name: string = "";
    line: i32 = 0;
    col: i32 = 0; // start of the name
    nameEndCol: i32 = 0;
    endCol: i32 = 0; // after ')'
    args: Array<ArgNode> = [];

    arg(name: string): ArgNode? {
        for (let i = 0; i < this.args.length; i++) {
            if (this.args[i].name == name) return this.args[i];
        }
        return null;
    }
}

export class ParsedRow {
    commands: Array<CommandNode> = [];

    constructor(
        public index: i32, // 0-based
        public firstLine: i32, // 1-based
        public lineCount: i32,
    ) {}

    get isEmpty(): bool {
        return this.commands.length == 0;
    }
}
