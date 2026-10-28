// Built-in presets (docs/spec.md §7.3), written in the instrument language so
// users can copy one into instruments/ and change it.

export function presetSource(name: string): string {
    // Basic waves
    if (name == "sine") return "osc(wave: sine)\nenv(a: 5ms, d: 100ms, s: 0.8, r: 150ms)\n";
    if (name == "tri") return "osc(wave: tri)\nenv(a: 5ms, d: 100ms, s: 0.8, r: 150ms)\n";
    if (name == "saw") return "osc(wave: saw, level: 0.6)\nenv(a: 5ms, d: 100ms, s: 0.8, r: 150ms)\n";
    if (name == "square") return "osc(wave: square, level: 0.5)\nenv(a: 5ms, d: 100ms, s: 0.8, r: 150ms)\n";
    if (name == "pulse") return "osc(wave: pulse, pw: 0.25, level: 0.5)\nenv(a: 5ms, d: 100ms, s: 0.8, r: 150ms)\n";
    if (name == "noise") return "osc(wave: noise, level: 0.5)\nenv(a: 1ms, d: 100ms, s: 0.8, r: 100ms)\n";

    // Bass
    if (name == "sub_bass") return "osc(wave: sine)\nosc(wave: tri, level: 0.15)\nfilter(type: lowpass, cutoff: 400)\nenv(a: 4ms, d: 300ms, s: 0.9, r: 120ms)\nvoice(poly: 2)\n";
    if (name == "deep_bass") return "osc(wave: saw, level: 0.55)\nosc(wave: sine, oct: -1, level: 0.6)\nfilter(type: lowpass, cutoff: 450, res: 0.2, env: 0.35)\nfilter_env(a: 1ms, d: 250ms, s: 0.2, r: 200ms)\nenv(a: 2ms, d: 300ms, s: 0.8, r: 150ms)\nvoice(poly: 2)\n";
    if (name == "organ_bass") return "osc(wave: sine, level: 0.8)\nosc(wave: sine, oct: 1, level: 0.4)\nosc(wave: sine, semi: 19st, level: 0.22)\nosc(wave: square, level: 0.06)\nfilter(type: lowpass, cutoff: 1.8k)\nenv(a: 2ms, d: 260ms, s: 0.45, r: 90ms)\nvoice(poly: 2)\n";
    if (name == "acid_bass") return "osc(wave: saw, level: 0.7)\nfilter(type: lowpass, cutoff: 350, res: 0.78, env: 0.55, slope: 24)\nfilter_env(a: 1ms, d: 180ms, s: 0, r: 120ms)\nenv(a: 2ms, d: 200ms, s: 0.7, r: 80ms)\ndrive(v: 0.45)\nvoice(mono: true, glide: 60ms)\n";

    // Keys and chords
    if (name == "stab") return "osc(wave: saw, level: 0.45, detune: -9c)\nosc(wave: saw, level: 0.45, detune: 9c)\nosc(wave: square, oct: -1, level: 0.2)\nfilter(type: lowpass, cutoff: 900, res: 0.3, env: 0.45)\nfilter_env(a: 1ms, d: 320ms, s: 0.1, r: 250ms)\nenv(a: 2ms, d: 420ms, s: 0.25, r: 300ms)\ndefaults(delay: 0.25, reverb: 0.3)\n";
    if (name == "pluck") return "osc(wave: saw, level: 0.5)\nosc(wave: square, level: 0.25, detune: 5c)\nfilter(type: lowpass, cutoff: 600, res: 0.25, env: 0.6)\nfilter_env(a: 1ms, d: 180ms, s: 0, r: 150ms)\nenv(a: 1ms, d: 260ms, s: 0, r: 200ms)\n";
    if (name == "epiano") return "osc(wave: sine, ratio: 14, level: 0)\nosc(wave: sine, fm: 0.25, level: 0.7)\nosc(wave: sine, oct: 1, level: 0.15)\nenv(a: 2ms, d: 1.4s, s: 0.25, r: 400ms)\n";
    if (name == "organ") return "osc(wave: sine, level: 0.5)\nosc(wave: sine, oct: 1, level: 0.35)\nosc(wave: sine, oct: 2, level: 0.2)\nosc(wave: square, level: 0.04)\nenv(a: 6ms, d: 50ms, s: 1, r: 70ms)\n";
    if (name == "bell") return "osc(wave: sine, ratio: 3.5, level: 0)\nosc(wave: sine, fm: 1.8, level: 0.7)\nenv(a: 1ms, d: 2.2s, s: 0, r: 1.5s)\ndefaults(reverb: 0.35)\n";

    // Pads and leads
    if (name == "pad") return "osc(wave: saw, level: 0.4, unison: 5, spread: 18c)\nosc(wave: saw, oct: -1, level: 0.25)\nfilter(type: lowpass, cutoff: 1.4k, res: 0.1, env: 0.2, keytrack: 0.3)\nfilter_env(a: 900ms, d: 2s, s: 0.6, r: 2s)\nenv(a: 700ms, d: 1s, s: 0.8, r: 2s)\ndefaults(reverb: 0.45)\n";
    if (name == "strings") return "osc(wave: saw, level: 0.35, unison: 7, spread: 22c)\nfilter(type: lowpass, cutoff: 3k, res: 0.05)\nenv(a: 400ms, d: 500ms, s: 0.9, r: 1s)\ndefaults(reverb: 0.35)\n";
    if (name == "supersaw") return "osc(wave: saw, level: 0.3, unison: 7, spread: 38c)\nosc(wave: saw, oct: -1, level: 0.15)\nfilter(type: lowpass, cutoff: 6k)\nenv(a: 8ms, d: 400ms, s: 0.8, r: 400ms)\n";
    if (name == "lead") return "osc(wave: pulse, pw: 0.4, level: 0.4)\nosc(wave: saw, detune: 7c, level: 0.35)\nfilter(type: lowpass, cutoff: 2.4k, res: 0.3, env: 0.3)\nfilter_env(a: 5ms, d: 300ms, s: 0.5, r: 200ms)\nenv(a: 5ms, d: 200ms, s: 0.75, r: 150ms)\nvoice(mono: true, glide: 40ms)\n";

    // Drums
    if (name == "kick") return "osc(wave: sine)\npitch_env(amount: 36st, decay: 35ms)\nenv(a: 1ms, d: 320ms, s: 0, r: 60ms)\ndrive(v: 0.35)\nvoice(fixed: G1, poly: 2)\n";
    if (name == "kick_deep") return "osc(wave: sine)\nosc(wave: tri, level: 0.08)\npitch_env(amount: 30st, decay: 55ms)\nenv(a: 1ms, d: 520ms, s: 0, r: 80ms)\ndrive(v: 0.2)\nvoice(fixed: F1, poly: 2)\n";
    if (name == "snare") return "osc(wave: tri, level: 0.5)\nosc(wave: noise, level: 0.7)\npitch_env(amount: 12st, decay: 30ms)\nfilter(type: highpass, cutoff: 180)\nenv(a: 1ms, d: 180ms, s: 0, r: 80ms)\nvoice(fixed: F#3)\n";
    if (name == "clap") return "osc(wave: noise)\nfilter(type: bandpass, cutoff: 1.3k, res: 0.3)\nenv(a: 1ms, d: 180ms, s: 0, r: 90ms, burst: 3, burst_gap: 9ms)\nvoice(fixed: C4)\n";
    if (name == "rim") return "osc(wave: tri, level: 0.6)\nosc(wave: noise, level: 0.3)\nfilter(type: bandpass, cutoff: 2.2k, res: 0.4)\nenv(a: 1ms, d: 40ms, s: 0, r: 30ms)\nvoice(fixed: G5)\n";
    if (name == "hat_closed") return "osc(wave: noise, level: 0.7)\nfilter(type: highpass, cutoff: 7.5k, res: 0.2)\nenv(a: 1ms, d: 45ms, s: 0, r: 30ms)\nvoice(fixed: C4)\n";
    if (name == "hat_open") return "osc(wave: noise, level: 0.6)\nfilter(type: highpass, cutoff: 6.5k, res: 0.15)\nenv(a: 2ms, d: 380ms, s: 0, r: 200ms)\nvoice(fixed: C4)\n";
    if (name == "shaker") return "osc(wave: noise, level: 0.5)\nfilter(type: bandpass, cutoff: 5k, res: 0.3)\nenv(a: 12ms, d: 70ms, s: 0, r: 50ms)\nvoice(fixed: C4)\n";
    if (name == "tom") return "osc(wave: sine)\npitch_env(amount: 12st, decay: 120ms)\nenv(a: 1ms, d: 420ms, s: 0, r: 100ms)\n";
    return "";
}
