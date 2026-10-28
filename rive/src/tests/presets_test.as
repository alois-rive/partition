import { Tests } from "rive/test";
import { checkSource, CheckContext, FileKind } from "../lang/check";
import { PRESET_NAMES } from "../score/instrument";
import { presetSource } from "../score/presets";

export class PresetTests extends Tests {
    override run(): void {
        test("every preset is valid instrument source", (expect) => {
            let problems = "";
            for (let i = 0; i < PRESET_NAMES.length; i++) {
                let name = PRESET_NAMES[i];
                let src = presetSource(name);
                if (src.length == 0) problems += `${name}: missing\n`;
                let f = checkSource(`presets/${name}.inst`, src, FileKind.Instrument, new CheckContext());
                for (let k = 0; k < f.diagnostics.items.length; k++) problems += f.diagnostics.items[k].toString() + "\n";
            }
            expect.that(problems).is("");
        });
    }
}
