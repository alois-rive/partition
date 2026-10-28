# Partition — Specification

> Composing music with text.

Status: draft v0.1 · 2026-10-28
Target toolchain: Rive CLI 1.8.0, AnimaScript (`.as`), Rive built-in audio engine.

---

## 1. Overview

Partition is a text-based music composer, player and renderer built as a
**Rive program**. A song is a set of plain-text *channels*. Each line of a
channel is one step in time, and each step holds zero or more *commands*:

```
note(p: C2, len: 2); vol(v: 0.8)
```

Channels sit side by side as editable columns in one window, and their vertical
scroll is synced, so a line at the same height in every column is the same
moment in the song. A playhead moves down through the columns while the song
plays. Sound is synthesized in real time by AnimaScript audio processors that
run on Rive's built-in audio engine. The same synthesis code renders a song
offline to WAV.

The Rive program is **self-sufficient**. It runs on its own in the `rive`
previewer: browse the bundled examples, edit, play, and render through
`rive --render-audio`. It also exposes a **view-model contract** (properties,
lists, triggers) that a host can drive. A separate **Rust shell** (§12)
embeds the Rive runtime in a native window and uses that contract to load
songs from disk, save edits, watch files for outside changes, and render WAV
files, either with a window or headless from the command line.

### 1.1 Goals

- One mental model: a line is a time step, and a command changes sound or state.
- Edit many channels at once, aligned in time.
- Live editing: changes take effect while the song plays, with no stop or rebuild.
- Built-in synth presets plus user-defined instruments written in text.
- Song-level structure (tempo, signature, sections, repeats) in a dedicated
  conductor channel. Reusable phrases come from patterns. Parameters change
  over time through automation (ramps, glides, LFOs).
- Deterministic WAV export: the same song always renders to the same samples.
- Bundled example songs (deep house and others) plus an empty template.

### 1.2 Non-goals (v1)

- Sample playback (`.wav` instruments), MIDI input or output, audio input,
  and live recording of played notes.
- User-written DSP (scriptable instruments).
- Comments in channel files (see §18).
- Any persistence inside the Rive program itself (see §2.2).

---

## 2. Architecture

```
┌──────────────────────────── Rive program (.riv) ─────────────────────────────┐
│                                                                              │
│  RML (app.rml)                     AnimaScript (main lane)                   │
│  ─ toolbar / transport / browser   ─ lang: lexer, parser, diagnostics        │
│  ─ status bar, render panel        ─ score: compiler (conductor, patterns,   │
│  ─ view models + listeners           automation) → Score blob                │
│                                    ─ editor: ChannelGrid (Layout)            │
│            ▲   view model          ─ app: bindings, songs, examples          │
│            │   contract (§11)                │ Ring / Snapshot / Blob       │
│            │                                 ▼                               │
│            │                       AnimaScript lanes                         │
│            │                       ─ PartitionProcessor (AudioProcessor)     │
│            │                         real-time playback                      │
│            │                       ─ render jobs (@job): offline render      │
│            │                       both run the same `Engine` (synth core)   │
└────────────┼─────────────────────────────────────────────────────────────────┘
             │
   ┌─────────┴──────────────────────┐        ┌────────────────────────────────┐
   │ `rive <dir>` previewer         │   or   │ Rust shell `partition`         │
   │ standalone: examples, editing, │        │ window or headless; disk I/O,  │
   │ playback, --render-audio       │        │ file watching, WAV writing     │
   └────────────────────────────────┘        └────────────────────────────────┘
```

### 2.1 Responsibilities

| Concern | Owner |
|---|---|
| Parsing, diagnostics, score compilation | Rive program (main lane) |
| Editor UI, synced scroll, playhead, transport | Rive program (RML + `ChannelGrid` script) |
| Real-time synthesis and sequencing | Rive program (`PartitionProcessor`) |
| Offline rendering to PCM | Rive program (`@job` render lanes) |
| WAV container encoding | Rive program (`wav.as`), streamed in chunks |
| Reading and writing song folders, file watching | Rust shell |
| Writing `.wav` files to disk | Rust shell, or the `rive --render-audio` CLI |
| Command-line interface | Rust shell |

### 2.2 Platform constraints (verified against Rive CLI 1.8.0 docs)

These facts drive the design:

1. **No disk access from AnimaScript.** No file read or write, no directory
   listing, no argv, no environment. The only data a script can read is
   *embedded blob assets* (`context.blob(name)`) and view model properties.
   → All disk I/O belongs to the host. Standalone, the program edits in memory
   only.
2. **No built-in oscillators or effects.** `rive/audio` gives raw interleaved
   `f32` buffers through `AudioProcessor.process(out, frames, startFrame)`.
   → Partition implements all DSP.
3. **Audio processors are isolated.** They reach only their start argument,
   lock-free shared memory (`Ring`, `Snapshot`, `Signal`, `Blob`), pure std
   code and `console`. They must never allocate or wait, and an overrun or trap
   kills a processor for good.
   → A preallocated engine, a watchdog in `advance` that restarts the
   processor, and no float-to-int casts without range checks.
4. **Sample-accurate timing exists only inside a processor.** The main lane
   ticks at about 60 fps.
   → The sequencer runs *inside* the processor, from a compiled score. The main
   lane never schedules individual notes.
5. **The `--render-audio` capture records processor output only**, and does so
   deterministically.
   → Every sound comes from Partition's own processor. `Audio.play` with audio
   assets is never used.
6. **Real-time DSP needs compiled code.** On the interpreter, blocks overrun.
   → Run with `--aot` (or `RIVE_WAMRC`), mark hot functions `@unchecked`, and
   keep a scalar path that matches any SIMD path.
7. **Text and input are available to scripts.** `rive/text` (`Font`,
   `TextRunStyle`, `Text` with `hitTest`, `caret` and `selectionRects`), plus
   `keyboardEvent`, `textEvent`, pointer and `pointerScroll` hooks. Keys arrive
   only when the scripted node has a direct `<FocusData/>` child and holds
   focus. There is no OS clipboard and no IME composition API.
8. **A scripted layout can be created twice.** The player builds the layout
   once without a bound view model, disposes it at once, and builds it again
   bound (observed in M0).
   → Bind view-model properties lazily, never assume `context.viewModel()` in
   `init`, and stop every processor and job in `dispose`.
9. **A processor cannot be handed shared objects after it starts.** Sending a
   `Blob` or any other shared handle through a ring or snapshot fails the
   processor (found in M4).
   → Scores reach the processor through two `SharedRegion`s passed in
   `Audio.start`'s argument (§9.3).
10. **`--data` values land after `init`.** A host or the CLI sets view-model
    values once the scene runs.
    → The app watches `song/exampleId` and `song/autoplay` for changes instead
    of reading them only at start.

---

## 3. Song project format

A song is a folder:

```
my-song/
  song.yaml              # metadata, initial tempo, channel order and layout
  conductor.ch           # song-level commands (tempo, sections, jumps)
  channels/
    kick.ch
    bass.ch
    chords.ch
  instruments/           # optional user-defined instruments
    warm_pad.inst
  patterns/              # optional reusable phrases
    hats_a.pat
```

All files are UTF-8 with LF or CRLF line endings. Partition writes LF.

### 3.1 `song.yaml`

Partition reads a restricted YAML subset: block mappings, block sequences of
mappings, and plain or double-quoted scalars. Anchors, flow collections and
multi-line strings are not supported.

```yaml
title: Late Night Deep House
author: someone
bpm: 122                 # beats per minute; a beat is the signature's denominator
signature: 4/4
rows_per_beat: 4         # 1 line = 1/16 note in 4/4
swing: 0                 # 0..0.75, delays every odd row (see §6.2)
master_volume: -1dB
channels:
  - name: kick           # display name; defaults to the file name
    file: channels/kick.ch
    width: 28            # column width in characters (optional, default 32)
    mute: false
    solo: false
  - name: bass
    file: channels/bass.ch
```

- The order of `channels` is the column order. `conductor.ch` is implicit and
  always comes first.
- Every `*.inst` in `instruments/` and every `*.pat` in `patterns/` is loaded.
  The file name without its extension is the name you reference it by.
- A file that is referenced but missing is a diagnostic, not a fatal error.

### 3.2 Song bundle (`.song`)

A single-file packing of a song folder, used for the embedded examples and as
an import/export format:

```
%partition-bundle 1
=== song.yaml
title: ...
=== conductor.ch
bpm(v: 122)
=== channels/kick.ch
note(p: C1)
```

- Line 1 is the magic header.
- A line starting with `=== ` at column 0 begins the file at the path that
  follows. The file runs until the next header or the end of the bundle.
- File content may not contain a line starting with `=== `.

---

## 4. Channel language

### 4.1 Lines and rows

- A channel file is a sequence of **rows**. Row *n* covers the time from
  `start(n)` to `start(n+1)` (§6).
- Every line that does **not** start with a tab character begins a new row.
- A line that **starts with a tab (`\t`)** is a *continuation line*: it belongs
  to the row above, as if its commands came after that row's commands. It is
  only a formatting aid. Several continuation lines can follow one row.
- An empty line, or one with only spaces, is an empty row: nothing happens and
  time passes. A tab-only line is an empty continuation and adds nothing.
- A continuation line at the very start of a file is a diagnostic
  (`orphan-continuation`) and is ignored.
- Only a leading tab marks a continuation. Leading spaces are plain whitespace.

```
note(p: C2)                         ← row 1
note(p: E2); vol(v: 0.6)            ← row 2
	set(cutoff: 800)                ← continuation of row 2
	ramp(cutoff: 4k, over: 2bar)    ← continuation of row 2
                                    ← row 3 (empty)
note(p: G2)                         ← row 4
```

### 4.2 Statements

A row (its line plus its continuation lines) holds statements separated by
`;`. Empty statements and a trailing `;` are allowed. Commands in a row run in
order: left to right, top line first, then each continuation line.

### 4.3 Grammar

```ebnf
file         = { line , EOL } ;
line         = [ TAB ] , [ stmt , { ";" , [ stmt ] } ] ;
stmt         = ws , command , ws ;
command      = ident , ws , "(" , ws , [ arg , { ws , "," , ws , arg } , [ "," ] ] , ws , ")" ;
arg          = ident , ws , ":" , ws , value ;
value        = list | scalar ;
list         = "[" , ws , [ scalar , { ws , "," , ws , scalar } ] , ws , "]" ;
scalar       = string | pitch | quantity | ident | bool ;
quantity     = number , [ unit ] | fraction ;
number       = [ "-" | "+" ] , digits , [ "." , digits ] | [ "-" | "+" ] , "." , digits ;
fraction     = digits , "/" , digits ;
unit         = "%" | "dB" | "Hz" | "k" | "ms" | "s" | "b" | "bar" | "c" | "st" ;
pitch        = letter , [ "#" | "b" ] , [ "-" ] , [ digit ] ;   (* C4, F#3, Bb2, C *)
letter       = "A".."G" | "a".."g" ;
string       = '"' , { char - '"' | '\"' } , '"' ;
bool         = "true" | "false" ;
ident        = ( "a".."z" | "_" ) , { "a".."z" | "0".."9" | "_" } ;
```

- **Arguments are named.** Their order is free, and a duplicate name is a
  diagnostic.
- Command and argument names are lowercase. Pitch letters are case-insensitive.
- Whitespace inside a statement is insignificant.
- How a token reads depends on the argument's declared type. `C4` is a pitch
  for `p:`, and `saw` is an identifier for `wave:`. A bare integer passed to a
  pitch argument is a MIDI note number (`60` = C4).

### 4.4 Value types and units

| Type | Literals | Notes |
|---|---|---|
| `number` | `0.5`, `-3`, `2k` (=2000), `80%` (=0.8) | |
| `gain` | `0.8`, `80%`, `-6dB` | linear 0..1 (dB converted) |
| `freq` | `440`, `440Hz`, `2k` | Hz |
| `pitch` | `C4`, `F#3`, `Bb2`, `C` (octave from `oct`), `60` | A4 = 440 Hz, C4 = MIDI 60 |
| `interval` | `7st`, `-12st`, `25c` | semitones / cents |
| `duration` | `2` (rows), `1/8` (note value), `1b` (beats), `2bar`, `250ms`, `1.5s` | see below |
| `ident` | `saw`, `lowpass`, `deep_bass` | enumerations and names |
| `string` | `"Verse A"` | |
| `bool` | `true`, `false` | |
| `list<T>` | `[C4, Eb4, G4]` | |

Durations:
- A bare number counts **rows**.
- A **fraction** is a note value relative to a whole note, so `1/4` is a
  quarter note whatever the signature's denominator.
- `b` counts beats, `bar` counts bars.
- `ms` and `s` are absolute time. Every other duration follows tempo changes.

### 4.5 Channel state

Each channel keeps a **persistent state**. Modifiers change it, and the change
holds for every later command on that channel, across rows, until something
changes it again. Arguments passed to a single command override the state for
that command only.

| Field | Default | Set by |
|---|---|---|
| `inst` | `sine` | `inst(name:)` |
| `oct` | `4` | `oct(v:)` |
| `transpose` | `0st` | `transpose(v:)` |
| `vel` | `0.8` | `vel(v:)` |
| `len` | `1` (row) | `len(v:)` |
| `vol` | `0.8` | `vol(v:)`, `set(vol:)` |
| `pan` | `0` (−1..1) | `pan(v:)`, `set(pan:)` |
| instrument params | from the instrument | `set(<param>: …)` |
| channel FX sends | `delay: 0`, `reverb: 0` | `set(delay:, reverb:)` |

Switching `inst` does not reset other fields. Each instrument keeps its own
parameter overrides for the channel, so switching back restores them.

### 4.6 Notes and polyphony

- Every note has an **explicit length**: the `len:` argument, or else the
  channel's `len` state. A note sounds for its length, then enters its release
  stage.
- Notes can overlap, so a channel is polyphonic. Each instrument caps its
  voices (`voice(poly:)`, default 8). Past the cap, the oldest voice is stolen,
  with a 2 ms fade.
- A mono instrument (`voice(mono: true)`) plays one voice. An overlapping note
  takes the voice over and glides if `glide > 0` (legato).

### 4.7 Diagnostics

A diagnostic has a file, line, column range, severity (`error` or `warning`),
code and message. A statement with an error is **skipped**. The rest of the
row and the rest of the song still play, so a typo never silences a song.

| Code | Example |
|---|---|
| `syntax` | `note(p C4)` (missing `:`) |
| `unknown-command` | `nte(p: C4)` (suggests `note`) |
| `unknown-arg` | `note(pitch: C4)` (suggests `p`) |
| `missing-arg` | `inst()` |
| `type` | `vol(v: C4)` |
| `range` | `pan(v: 3)` |
| `unknown-instrument` / `unknown-pattern` / `unknown-mark` | |
| `scope` | `bpm(v: 120)` in a channel, `note(...)` in the conductor |
| `pattern-cycle` | a pattern that calls itself, directly or indirectly |
| `orphan-continuation` | a tab line at the start of a file |
| `duplicate-arg` | `note(p: C4, p: D4)` |
| `duplicate-mark` | two `mark(name: a)` in the conductor |
| `limit` | an arrangement over 200 000 played rows, patterns nested deeper than 8 |
| `order` | `base(...)` after other instrument commands (warning) |
| `missing-file` / `config` / `yaml` / `bundle` | problems in `song.yaml`, the song's files or a `.song` bundle |

Unknown names get a suggestion when one is close, by edit distance or by
prefix (`pitch` → `p`).

---

## 5. Command reference

`?` marks an optional argument. Defaults are in brackets.

### 5.1 Notes

| Command | Arguments | Effect |
|---|---|---|
| `note` | `p: pitch \| list<pitch>`, `len?: duration`, `vel?: gain`, `inst?: ident`, `glide?: duration`, `at?: duration` | Plays one note, or several at once from a list. `at:` delays the start inside the row (micro-timing after swing, such as `at: 0.5` meaning half a row)¹. |
| `chord` | `root: pitch`, `type: ident`, `inv?: number [0]`, `spread?: number [0]`, `len?`, `vel?`, `strum?: duration [0]`, `at?: duration` | Plays a chord. Types: `maj min dim aug sus2 sus4 maj7 min7 dom7 m7b5 dim7 maj9 min9 dom9 min11 add9 maj6 m6`. `inv` rotates the notes upward, `spread` moves alternate notes up an octave, and `strum` staggers the note starts. |
| `cut` | `fade?: duration [5ms]` | Releases every sounding note on the channel. |

¹ `at:` accepts a fraction of a row (`at: 0.5`) or any duration. It cannot
reach past the end of the row.

### 5.2 Modifiers (persistent)

| Command | Arguments | Effect |
|---|---|---|
| `inst` | `name: ident` | Selects an instrument (preset or song instrument). |
| `oct` | `v: number` | Octave for pitches written without one (`C`, `Eb`). |
| `transpose` | `v: interval` | Shifts every later note. |
| `vel` | `v: gain` | Default velocity. |
| `len` | `v: duration` | Default note length. |
| `vol` | `v: gain` | Channel volume (same as `set(vol:)`). |
| `pan` | `v: number` | Channel pan, −1..1 (same as `set(pan:)`). |
| `set` | `<param>: value, …` | Sets one or more channel or instrument parameters, for example `set(cutoff: 1.2k, res: 0.3, reverb: 0.2)`. |

### 5.3 Automation

| Command | Arguments | Effect |
|---|---|---|
| `ramp` | `<param>: value, …`, `over: duration`, `curve?: ident [linear]` | Moves each named parameter from its current value to the target over `over`, starting at this row. Curves: `linear exp log smooth`. Ramps run per sample. A later `set` or `ramp` on the same parameter replaces the ramp in progress. |
| `glide` | `to: pitch`, `over: duration` | Slides the pitch of every sounding note on the channel. |
| `lfo` | `param: ident`, `rate: duration \| freq`, `depth: number`, `shape?: ident [sine]`, `id?: ident` | Starts an LFO on a parameter. Shapes: `sine tri saw square random`. A tempo-synced rate is a duration (`rate: 1bar`). Re-running `lfo` with the same `param` and `id` replaces it. `depth` is in octaves for `cutoff` (0.4 swings ±0.4 octave) and in the parameter's own units otherwise. |
| `lfo_off` | `param: ident`, `id?: ident` | Stops an LFO. |

Rampable parameters: `vol pan delay reverb` plus every numeric instrument
parameter (§7.2). In the conductor channel, `bpm` and `master` are rampable.

### 5.4 Patterns

| Command | Arguments | Effect |
|---|---|---|
| `pattern` | `name: ident`, `times?: number [1]`, `id?: ident` | Plays `patterns/<name>.pat` starting at this row, `times` times back to back. |
| `stop` | `id?: ident` | Stops the channel's running patterns, or just the one with that `id`. Notes already playing finish normally. |

See §8 for semantics.

### 5.5 Conductor-only commands (`conductor.ch`)

| Command | Arguments | Effect |
|---|---|---|
| `bpm` | `v: number` | Changes the tempo from this row on. Rampable: `ramp(bpm: 128, over: 8bar)`. |
| `sig` | `v: fraction` | Changes the time signature. Bar counting restarts at this row. |
| `rpb` | `v: number` | Changes rows per beat. Each line still counts as one row. |
| `swing` | `v: number` | Swing amount, 0..0.75. |
| `master` | `vol?: gain` | Master volume. It replaces `song.yaml`'s `master_volume` rather than scaling it. |
| `mark` | `name: ident` | Names this row (a section start). Shown in the gutter. |
| `jump` | `to: ident`, `times?: number` | Jumps back to a mark after this row ends, for **all** channels (§6.3). |
| `end` | — | The song ends after this row. Running patterns stop and sounding notes release. |

Channels cannot use conductor commands, and the conductor cannot play notes,
change instruments or call patterns (`scope` diagnostic).

---

## 6. Timing

### 6.1 Row duration

With tempo `bpm` (beats per minute, where a beat is the signature's
denominator note) and `rpb` (rows per beat):

```
rowSeconds = 60 / (bpm × rpb)
bar        = signature.numerator beats = numerator × rpb rows
```

At 122 bpm in 4/4 with `rpb: 4`, a row lasts 0.1230 s and a bar has 16 rows.
Tempo, signature and `rpb` come from `song.yaml`, and conductor commands can
change them at any row. The **source row grid** is shared: line *n* of every
channel is row *n*, whatever tempo it plays at.

### 6.2 Swing

When `swing = s > 0`, every odd row (the 2nd, 4th, … of each beat) starts late
by `s × rowSeconds × 0.5`. Rows keep their order, so swing never moves a row
past the next one. `at:` offsets apply after swing.

### 6.3 Playback order: marks and jumps

Playback walks the conductor rows from top to bottom. Every channel follows
the conductor's position. When a row containing `jump(to: m, times: n)`
finishes:

- If the jump's counter is below `n`, the counter goes up by one and playback
  continues at mark `m`'s row.
- Otherwise, the counter resets to 0 and playback falls through to the next row.
- With `times` omitted, the jump repeats forever, which makes a song-level loop.

So `jump(to: verse, times: 1)` plays the verse twice. Nested repeats work like
tracker loops.

Channel state is **not** rewound by a jump. It carries over in playback order,
so a ramp that ends on the first pass keeps its final value. Pattern instances
and sounding notes carry on across a jump.

**Play from a row.** Starting at row *r* first replays the state effects of
rows `1..r-1` in source order (modifiers, `set`, ramps resolved to their value
at *r*), with no sound. A ramp in progress at *r* continues from the
interpolated value. Pattern instances started before *r* that are still
running at *r* keep playing from where they are, so a kick pattern called on
row 1 is heard when playing from row 64.

**Swing and meter.** Bar, beat and swing parity come from the source-order
grid (§10.2). Durations and tempo come from playback order. The two differ
only when a jump crosses a `sig` or `rpb` change.

**Song end.** The song ends at an `end()` row. Without one, it ends at the last
non-empty row of any channel, or when the last pattern instance finishes,
whichever is later. In both cases it also waits for the last note to end.
A release tail follows (§9.6).

### 6.4 Infinite loops and rendering

A song with an infinite `jump` loops forever during playback. An offline
render needs a bound: `render.loops` (default 1) sets how many extra passes
each infinite jump gets before it falls through.

---

## 7. Instruments

### 7.1 Instrument files (`.inst`)

An instrument file uses the same lexical syntax as a channel. Rows carry no
meaning here, and lines and continuation lines are statements in order.

`instruments/warm_pad.inst`:

```
base(preset: pad)
osc(wave: saw, level: 0.5, detune: -8c, unison: 3, spread: 12c)
osc(wave: saw, level: 0.5, detune: 8c, unison: 3, spread: 12c)
osc(wave: sine, level: 0.3, oct: -1)
env(a: 400ms, d: 1s, s: 0.7, r: 2s)
filter(type: lowpass, cutoff: 1.4k, res: 0.2, env: 0.3, keytrack: 0.5)
filter_env(a: 600ms, d: 2s, s: 0.4, r: 2s)
voice(poly: 8)
defaults(vol: 0.6, reverb: 0.4)
```

| Command | Arguments |
|---|---|
| `base` | `preset: ident`. Copies a preset, which later commands then override. If the file declares any `osc`, its oscillators replace the preset's instead of adding to them. |
| `osc` | `wave: sine\|tri\|saw\|square\|pulse\|noise`, `level: gain [1]`, `oct: number [0]`, `semi: interval [0]`, `detune: interval [0]`, `pw: number [0.5]`, `unison: number [1]` (max 7), `spread: interval [0]`, `fm: number [0]` (modulation index from the previous osc), `ratio: number [1]`, `phase: number \| random [random]`. At most 4 per instrument. Each `osc` adds one. |
| `env` | Amplitude ADSR: `a d s r` (durations, with `s` as a gain), `curve?: number`, `burst?: number [1]`, `burst_gap?: duration` (multi-hit claps). |
| `pitch_env` | `amount: interval`, `decay: duration`. A pitch drop for kicks and toms. |
| `filter` | `type: lowpass\|highpass\|bandpass\|notch\|off`, `cutoff: freq`, `res: number 0..1`, `env: number −1..1`, `keytrack: number 0..1`, `slope: 12\|24`. |
| `filter_env` | ADSR for the filter envelope. |
| `drive` | `v: number 0..1`. Soft saturation after the filter. |
| `voice` | `poly: number [8]`, `mono: bool`, `glide: duration [0]`, `retrigger: bool [true]`, `fixed?: pitch`. With `fixed`, every note plays at that pitch (drums). |
| `defaults` | Initial channel values applied when the instrument is selected for the first time: `vol pan delay reverb`. |
| `param` | `name: ident`, `target: ident`, `min?`, `max?`. Defines a macro parameter for `set`/`ramp` that maps to an internal target such as `osc2.level`. |

### 7.2 Parameter names for `set`, `ramp` and `lfo`

`vol pan delay reverb` (channel); `cutoff res env keytrack drive glide`;
`attack decay sustain release`; `pw detune` (all oscillators);
`oscN.level oscN.detune oscN.pw oscN.fm` (N = 1..4); any macro from `param`.

### 7.3 Built-in presets

Presets are `.inst` files embedded in the program (`rive/assets/presets/`).
A song instrument with the same name as a preset replaces it within that song.

| Group | Presets |
|---|---|
| Basic | `sine tri saw square pulse noise` |
| Bass | `sub_bass deep_bass organ_bass acid_bass` |
| Keys / chords | `stab pluck epiano organ bell` |
| Pads / leads | `pad strings supersaw lead` |
| Drums | `kick kick_deep snare clap rim hat_closed hat_open shaker tom` |

The presets are written in the instrument language (`rive/src/score/presets.as`),
so any of them can be copied into `instruments/` as a starting point.

Drum presets other than `tom` use `voice(fixed: …)`, so they ignore the
written pitch: `note(p: C1)` on `kick` plays the kick.

---

## 8. Patterns

- A pattern is a `.pat` file using the channel language. Its length is its row
  count, and trailing empty rows count, so you can pad a pattern to one bar.
- `pattern(name: p)` on channel row *r* starts an **instance**. Pattern row *k*
  plays at song row `r + k − 1`, timed by the conductor (tempo, swing).
- **Overlay, not insertion.** The channel's own rows keep playing while the
  instance runs, and both sets of events mix. The grid alignment is never
  broken.
- An instance starts with a **copy** of the channel state at its call. State
  changes inside the pattern stay local to the instance and never leak to the
  channel. That includes `vol`, `pan` and the sends: the score gives every
  pattern repetition its own *owner* (§9.1), and parameter changes address one
  owner only.
- With `times: n`, the pattern plays *n* times back to back. Each repetition
  starts again from the state at the call.
- Patterns may call patterns, up to 8 levels deep. Cycles are rejected
  (`pattern-cycle`).
- A pattern's parameters are fixed when it is called. A channel's later
  `set`, `ramp` or `lfo` reaches only patterns called after it, so put the
  automation before the call on the same row (the examples do).
- Instances follow conductor jumps like everything else. If a jump lands
  before an instance's start, the instance keeps playing until it finishes or
  `stop()` ends it. A call row reached again starts a new instance.

---

## 9. Audio engine

### 9.1 Score compilation (main lane)

On load and after each edit, the compiler turns the song into a **Score**:

1. Parse each changed file. Parsing is incremental per file, and the AST is
   cached per file revision.
2. Build the conductor timeline: row start times in seconds, tempo ramps
   integrated exactly, swing applied, and playback order with jumps unrolled
   (§6.3, §6.4). An infinite jump becomes a *loop point* in the score.
3. Simulate each channel in playback order. Expand patterns, resolve state,
   and emit **events** stamped in seconds of song time (`score/events.as`):

   | Event | Fields |
   |---|---|
   | `Fork` | `ch, owner, parent`: a new owner starts as a copy of `parent`'s parameters |
   | `NoteOn` / `NoteOff` | `ch, owner, note, pitch` (MIDI, fractional), `vel, inst, seconds` (length), `from`/`value` (per-note glide from the previous pitch) |
   | `Param` | `ch, owner, inst` (−1 for the channel strip), `param, value, from, seconds, curve`. `from` is NaN for a plain set |
   | `Glide` / `Cut` | channel-wide pitch slide, or release with a fade |
   | `Lfo` / `LfoOff` | `ch, owner, inst, param, rate` (Hz), `value` (depth), `curve` (shape), `note` (id) |
   | `RowMark` | `row` (source row), `value` (tempo), for the playhead |
   | `End` | when the last row or pattern instance finishes |

   **Owners** keep patterns isolated. A channel's own rows play as owner 0.
   Calling a pattern forks a frozen snapshot of the caller's parameters, and
   each repetition forks a fresh owner from that snapshot. Voices follow their
   owner's parameters, including ramps in progress. Master volume events use
   channel −1.
4. Pack events and instrument definitions into flat typed arrays, and wrap
   them in a shared `Blob` (`Blob.fromArray`), which crosses lanes by id. Large
   songs compile in a `@job` so the frame stays under budget (§9.7).

### 9.2 Engine (shared synth core)

`Engine` is pure AnimaScript with no host access. It is built once with
preallocated voices, buffers and delay lines:

- **Voices.** Oscillators with phase in turns, using PolyBLEP for
  saw/square/pulse and the `sinTurn` polynomial for sine. Unison, 2-operator
  FM, a noise source, amp ADSR with bursts, a pitch envelope, a state-variable
  filter (12/24 dB) with its own envelope, and drive.
- **Channel strip.** Volume, constant-power pan, delay send, reverb send, and
  per-sample smoothing (5 ms) on every parameter change.
- **Buses.** One tempo-synced stereo delay with feedback and a high-cut, and
  one algorithmic reverb (FDN, 8 lines, power-of-two lengths). Both are global
  sends.
- **Master.** Master volume, then a soft-knee limiter at −0.3 dBFS.
- **Limits.** 16 channels plus the conductor, 64 voices in total, 4 oscillators
  per voice, unison up to 7.
- **Determinism.** Output depends only on (score, sample rate, channel count,
  start time). It never depends on the host's block size. The engine renders
  internal 32-frame sub-blocks and splits them at event times. Randomness
  (noise, random phase) comes from a seeded PRNG that is reset per voice from
  the event index.
- **Safety.** Never allocate in `render()`. Clamp every value before a
  float-to-int cast, and mask delay indices with `& (len − 1)`. Flush denormals
  to zero, and replace any NaN in a voice's output by killing that voice.

### 9.3 Real-time playback: `PartitionProcessor`

`PartitionProcessor extends AudioProcessor<EngineIO>` owns one `Engine`
(`rive/src/audio/processor.as`). `EngineIO` is its start argument:

| Channel | Type | Direction | Content |
|---|---|---|---|
| `control` | `Ring<Control>` (8 KB, numbers only) | main → audio | `play(from)`, `stop`, `loop(a, b)`, `stopAt(t)`, `score(region, keep, time)` |
| `regions` | 2 × `SharedRegion` (8 MB each, grown on demand) | main → audio | the score: header, instrument table and packed events (`audio/scoreregion.as`) |
| `mix` | `Snapshot<Mix>` | main → audio | per-channel mute/solo bitmasks |
| `status` | `Snapshot<PlayStatus>` | audio → main | song time, source row, tempo, playing/ended flags, voices, peaks (master and per channel), the score generation in use |

- **Score handover.** The main lane writes a new score into the idle region
  under its lock, then sends `score(region, …)`. The processor reads it with
  atomic loads only, which needs no lock and no allocation. The main lane
  reuses a region only after `status.generation` confirms the switch. While a
  handover is in flight, only the newest pending score waits. A score larger
  than a region restarts the processor with bigger regions.

- **Sequencing.** The processor keeps song time from `startFrame` and its own
  sample rate, and fires events whose time falls in the current block, at the
  exact frame.
- **Live edits.** A score sent with `keep` swaps at the next block and keeps
  the song position. Voices that are sounding keep playing to their own end,
  while events from the old score that have not fired yet are dropped. Edits
  are debounced by 150 ms on the main lane.
- **Seeking chases notes.** Moving to a position (play, play from cursor, a
  new score without `keep`) applies every earlier state event, then starts the
  notes still held at that point (up to 64), so a pad started before the
  cursor still sounds. At a loop seam, sounding voices instead keep what is
  left of their notes, with their times shifted back by the loop length.
- **Sleep.** When stopped with no voices sounding, `process` returns at once.
  It wakes on `control.used > 0` or a new `mix.seq`.
- **Watchdog.** The main lane checks `handle.failed` in `advance`. On failure,
  it logs once, shows an error in the status bar, restarts the processor
  (with backoff up to 3 times) and resends the score and position.

### 9.4 Offline rendering (`@job`)

1. The main lane compiles the score with `render.loops` and packs it into two
   `Blob`s (`audio/pack.as`).
2. **One render job** (`renderWav` in `audio/render.as`) runs the same `Engine`
   from time 0 to the end of the song plus its tail. It then encodes the WAV
   file on the job, since sample-by-sample encoding on the main lane would
   break the frame budget on the interpreter, and returns the file as a
   `Blob`.
3. Progress goes through a `Snapshot<RenderProgress>` that the job writes.
4. The main lane copies the file to the view model in 4 MB chunks (§11.5)
   with `Blob.readInto`, so main-lane memory stays bounded.

Rendering is single-threaded per song: the job renders a 2–3 minute song in
about a second when compiled. Splitting the work per channel stays possible
later, because the engine's output depends only on the score. The offline
render and the real-time processor (captured with `rive --render-audio`) are
**bit-identical**, which M4 checked by checksum.

### 9.5 Render formats

The sample rate defaults to 48000 (choices: 44100, 48000, 96000). Output is
stereo, as 16-bit PCM with TPDF dither (default) or 32-bit float. The WAV file
has a `RIFF/WAVE` header followed by `fmt `, `data` and a `LIST/INFO`
(`INAM` title, `IART` author, `ISFT` "Partition").

### 9.6 Tail

After the song ends, rendering continues until every voice has released and
the buses have decayed below −90 dBFS, up to `render.maxTail` (default 8 s).

### 9.7 Budgets

| Budget | Value |
|---|---|
| Main-lane call (`init`, `advance`, `draw`) | < 200 ms hard (Rive), target < 4 ms per frame |
| Processor block | ≤ 50 % of the block duration at 64 voices, compiled (`--aot`) |
| Recompile after a keystroke | < 30 ms for a 16-channel, 2 000-row song (on a job if larger) |
| Shared memory | ≤ 512 MB (Rive cap). A 10-minute stereo float render is about 230 MB, so renders stream instead |

---

## 10. Editor UI

### 10.1 Layout

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ ▶ ■ Loop Follow Collapse all  9.1 0:15.7 122 bpm  Title │ New  Examples ▾  Export WAV │  toolbar (RML)
├──────┬─────────────┬─────────────────┬──────────────────┬─────────────────────┤
│      │ conductor   │ kick   M S ▮▮▮  │ bass    M S ▮▮   │ chords  M S ▮       │  headers
├──────┼─────────────┼─────────────────┼──────────────────┼─────────────────────┤
│  1.1 │ mark(name:… │ inst(name: kick)│ inst(name: deep_…│ inst(name: stab)    │
│    · │             │                 │                  │ 	set(delay: 0.3)    │  ← continuation
│    2 │             │                 │                  │                     │
│    3 │             │                 │ note(p: A1, len…│                     │
│▶ 1.2 │             │ note(p: C1)     │                  │ chord(root: A3, …  │  ← playhead row
│  ... │             │                 │                  │                     │
├──────┴─────────────┴─────────────────┴──────────────────┴─────────────────────┤
│ chords:3:14  error unknown-arg: 'pitch' — did you mean 'p'?   │ cpu 12% · 18 v │  status bar (RML)
└───────────────────────────────────────────────────────────────────────────────┘
```

- **RML** draws the chrome: toolbar, transport, song and example menus, render
  panel, status bar and dialogs. It binds to the view model (§11), and RML
  listeners fire the view model triggers.
- **`ChannelGrid`** is an AnimaScript `Layout` attached to a fill
  `LayoutComponent`. It draws the gutter, headers and columns, owns text
  editing, and has a direct `<FocusData/>` child so it receives keys.
- The font is a bundled monospace font (Iosevka for code, Barlow Semi Condensed for labels, both OFL). All metrics come
  from the font (`Font.lineHeight`, advance width), and nothing is hard-coded.

### 10.2 Time-aligned rows with continuation lines

Rows line up across columns even when a column has continuation lines:

- Each **visual band** is one source row. Its height is
  `max over columns (1 + continuation lines in that row)` text lines.
- A column with fewer lines in a band gets blank filler space, which is not
  editable text, under its row.
- The gutter prints the row label once per band, as `bar.beat` on the first row
  of each beat and the row's index within the beat otherwise. Continuation
  lines show `·`.
- Gutter shading separates beats and bars. Bar lines are stronger, and marks
  show their name.
- So vertical scroll moves in the shared band space, and every column scrolls
  together.

### 10.3 Scrolling

- **Vertical.** One scroll offset shared by every column (synced). Wheel and
  trackpad use `pointerScroll` with momentum. PgUp/PgDn move one screen.
- **Horizontal.** The gutter and conductor stay pinned on the left. Channel
  columns scroll horizontally when they overflow, independent of vertical
  scroll.
- **Follow mode** (on by default during playback) keeps the playhead band at
  35 % of the viewport height. Scrolling manually turns follow off until the
  next play.
- Only visible bands are laid out. `Text` objects are cached per (file, row,
  revision).

### 10.4 Editing

- Cursor and selection live in a single column. Rectangular selection across
  columns, using the row band as the unit, is a stretch goal.
- Text insertion comes from `textEvent`. Keys are dispatched in
  `keyboardEvent`. Pointer click, drag and double-click handle placement and
  selection (`Text.hitTest`, `caret`, `selectionRects`).
- Undo/redo per file. Groups merge while typing, with a break after 1 s idle
  or after a cursor jump.
- **Clipboard.** Rive has no OS clipboard API. Standalone, Partition uses an
  internal clipboard. When hosted, it mirrors copies to `editor/clipboard` and
  reads pastes from it, so the shell can bridge to the OS clipboard.
- Pressing Tab at column 0 types a continuation tab. Elsewhere it inserts a tab
  too, since there is no auto-indent. Enter splits the line, and Shift+Enter
  opens a continuation line below.
- **Syntax highlighting.** Command names, argument names, pitches, quantities
  with units, strings, and errors (with a squiggle underline).
- **Hint line.** The status bar shows the signature of the command under the
  cursor, then the diagnostic at the cursor if there is one.
- **Channel management** (header context menu): add, rename, delete, reorder
  (drag the header), resize (drag the column edge), mute, solo, pick the
  instrument (which inserts `inst(...)` at row 1).

### 10.5a Bars

The chrome is generated by `tools/gen_scene.py` (run it after changing the
chrome or adding an example; it rewrites `rive/scene.rml`).

- **Title bar (28 px):** the window controls (macOS integrated title bar),
  "Partition", the song title with its status (`app/status`: "In memory",
  "Edited", "Saved"), and **Docs**.
- **Transport (38 px):** Play/Pause (one white button that swaps icons through
  `transport/playDisplay` and `pauseDisplay`), Stop, the **Loop**, **Follow**
  and **Collapse all** toggles, then the readout: position `006.1`, time
  `00:09.4`, tempo and meter (`transport/position`, `time`, `tempo`, `meter`).
  On the right: **New**, **Examples ▾** and **Export WAV**.
- **Footer (24 px):** the breadcrumb (`editor/hint`: the track, then the
  command under the cursor, such as "guitar / F3 maj7", or a passing message),
  voices, the output sample rate, and **Diagnostics ▾**, which opens the list
  of problems. Clicking one moves the cursor to it.

A toggle's look comes from `app/<name>Fill`, `Ink` and `Edge`. When it is on,
it has a pressed fill, a white label and a visible border.

### 10.5b Narrow windows

Below 1000 px the transport keeps Play, Stop and the position. Everything
else moves into a **More** popover (`app/moreToggle`, `moreDisplay`), driven by
`app/wideDisplay` and `narrowDisplay`, with Loop, Follow, Collapse all, New,
Examples and Export. In the editor, tracks that do not fit fold to their
strips (§10.6), and the selected track takes the remaining width. The
selected track takes the remaining width on wide windows too. Popovers close on
Escape or on a click elsewhere.

### 10.5 Key map

On macOS `Mod` is Cmd (`meta`). Elsewhere it is Ctrl.

| Keys | Action |
|---|---|
| `Mod+Enter` | Play / pause |
| `Mod+Shift+Enter` | Play from the cursor row |
| `Mod+.` | Stop (back to the start or the loop start) |
| `Alt+Enter` | Audition the cursor row in every channel |
| `Mod+L` | Loop the selected rows (toggle) |
| `Mod+M` / `Mod+Shift+S` | Mute / solo the current channel |
| `Mod+[` / `Mod+]` | Previous / next column |
| `Mod+S` | Fire `editor/saveRequested`. Hosted only. Standalone, it shows "not persisted" |
| `Mod+Z` / `Mod+Shift+Z` | Undo / redo |
| `Mod+C` / `Mod+X` / `Mod+V` | Copy / cut / paste |
| `Mod+D` | Duplicate the line (with its continuation lines) |
| `Alt+↑` / `Alt+↓` | Move the row up or down (with its continuation lines) |
| `Mod+F` | Follow mode on/off |
| `Mod+E` / `Mod+Shift+E` | Collapse or expand the current column / all columns |
| `Mod+=` / `Mod+-` | Zoom the overview in or out while every column is collapsed |
| `Mod+/` or `F1` | The documentation panel (Escape closes it) |
| `Mod+1` / `Mod+2` / `Mod+3` | Tracks / Patterns / Instruments tab (§10.9) |
| `F2` | Rename the selected pattern or instrument (Patterns and Instruments tabs) |
| Arrows, Home/End, PgUp/PgDn, `Mod+↑/↓` | Navigation (`Mod+↑/↓` goes to the file start/end) |

---

### 10.6 Overview strips and collapsed columns

Every column starts with a 64 px **overview strip**, and an expanded column
shows its text to the right of it. Collapsing a column (the chevron in its
header, `Mod+E`, or **Collapse all**) leaves only the strip, so the song can be
read across all channels at once. The strip is built from the checked source
in source order, with patterns expanded where they are called
(`rive/src/editor/overview.as`). It is rebuilt with every compile.

| Command | Mark |
|---|---|
| `note`, `chord` | A vertical line in the pitch area (pitch placed between the channel's lowest and highest note, like a piano roll). It is as long as the note, thicker and more opaque with velocity, coloured by instrument, and dimmer inside patterns. Its icon is a dot (a ring for chords). Delay or reverb sends add a faint echo tail. Notes under the playhead glow. |
| `pattern` | A translucent bar on the strip's left edge over the call's whole span, coloured by pattern name, with a tick at each repetition. The icon is a square. |
| `ramp` | A wedge whose width goes from the start value to the end value (0..1 of the parameter's range, frequencies on a log scale). The icon is a triangle pointing up or down. |
| `lfo` | A wave at the LFO's rate, until `lfo_off`. |
| `set`, `vol`, `pan`, `master` | A short bar as long as the value. |
| `glide` | A slanted line from the last pitch to the target. |
| `inst` | A diamond in the instrument's colour. |
| `cut` | A red line across the strip. |
| `mark`, `jump`, `end` (conductor) | A flag with a line across; an arrow up to the mark it jumps to; a thick red bar. |
| `bpm`, `sig`, `rpb`, `swing` | Small icons in the automation lane. |

Problems show as a tick on the strip's right edge. When every column is
collapsed no text is shown, so rows shrink to fit the whole song in the view
(down to 1.5 px). `Mod+=`/`Mod+-` zoom, and the gutter labels bars only.
Typing into a collapsed column expands it first.

### 10.7 Visual design ("compressed monochrome")

- **Neutral chrome.** Every chrome colour has equal RGB channels: canvas
  `#000000`; bars and headers `#0A0A0A`; controls `#151515`; hover and
  selection `#222222`; dividers `#303030`; essential borders `#666666`; text
  `#FFFFFF`, `#A0A0A0` and `#808080`. Fills are flat, with no gradients or
  glows.
- **Colour only in music and code.** Each track has an identity colour (the
  dot in its header). Its notes, patterns and curves in the overview strip use
  that same colour. Code keeps syntax colours. Structural marks (jumps, flags)
  stay white, and cuts and ends are red.
- **Type.** Iosevka (a narrow monospace) for code at 13/18 px and for numbers.
  Barlow Semi Condensed for labels at 12–13 px. Both are OFL and subset to the
  characters used, in `rive/assets/fonts`.
- **Geometry.** Buttons are 24 px tall with 7 px padding, 3 px corners and a
  1 px border. Gaps are 4 px between controls and 12–16 px between groups.
  Track headers are 28 px.
- **States.** Play is white with a black icon. Track selection is a white name
  with a thin white underline. The selected event has a neutral row fill and a
  white marker where the code starts. The playhead is a thin white line with a
  white marker in the gutter. M and S buttons have an explicit white pressed
  fill.
- **Gutter.** `bar.beat` on each beat's first row, with the row within the
  beat in small figures beside it. Compact rows show bars only.

### 10.8 Documentation panel

**Docs** in the title bar (or `Mod+/`, `F1`) opens a panel on the right. On
wide windows it takes its width from the tracks; below 720 px it covers them.
It holds a short guide (rows, statements, values), every command from the
registry with its signature, a sentence and an example (grouped as notes,
track settings, automation, patterns, conductor, instruments), the overview
strip, and the keyboard. It opens scrolled to the command under the cursor.
The content is in `rive/src/editor/docs.as`. It includes a *Pattern files*
and an *Instrument files* section. In the Patterns and Instruments tabs the
panel opens at those sections when the cursor is not on a command.

### 10.9 Tabs: tracks, patterns, instruments

A 44 px **rail** on the left of the editor area holds one icon per tab:
Tracks (`Mod+1`), Patterns (`Mod+2`) and Instruments (`Mod+3`). The selected
icon is highlighted with a white edge. Hovering an icon for 0.6 s shows a hint
with the tab's name and shortcut. The title bar, transport and footer are the
same in every tab.

- **Tracks** is the song editor of §10.1–10.6.
- **Patterns** and **Instruments** have a 200 px **file list** between the rail
  and the editor:
  - The list has one row per file in `patterns/` or `instruments/`, with a
    detail (a pattern's row count, an instrument's base preset).
  - Clicking a row opens that file in the editor next to the list, as a single
    column. A pattern keeps its strip and the bar/beat gutter of the song's
    meter, and its trailing empty rows are kept, since they are part of its
    length. An instrument has line numbers and no strip.
  - The **+** in the list header adds `pattern_N.pat` (one bar with a note on
    each beat) or `instrument_N.inst` (a saw with a filter), selects it, and
    opens its name for editing.
  - **Rename:** use the pencil on the hovered row, a double-click, or `F2`.
    The name is edited in place: typing is lowercased, spaces and `-` become
    `_`, and only letters, digits and `_` are kept. Enter confirms and Escape
    cancels. Renaming moves the file and rewrites every reference in `.ch`
    and `.pat` files: `pattern(name: …)` for a pattern; `inst(name: …)` and
    `inst:` overrides for an instrument. The rewrite works on tokens, so
    other text is never touched. Invalid or duplicate names are refused with
    a status message.
  - **Delete:** the × on the hovered row, clicked twice within 3 s (the row
    reads "Delete name?" in between).
  - Every change is written to the view model's files (§11.2), like editing a
    track.
- **Auditions.** In the Patterns and Instruments tabs, Play (and
  `Mod+Enter`, `Mod+Shift+Enter`) plays only the selected file, on a loop. It
  builds a temporary song with the same files and settings, a conductor that
  loops, and one track:
  - A pattern track calls the pattern once, with the instrument of the first
    track that calls it, directly or through other patterns (or the default).
  - An instrument track plays a two-bar example on the instrument: an
    arpeggio, a strummed maj7 chord and a low line.

  Edits made during an audition are heard on the next compile. Selecting
  another file while playing (including a newly added one) plays that file
  from its start. Stop, or playing in the Tracks tab, ends the audition.

## 11. View-model contract

The contract is the program's public API. The RML chrome, the Rust shell and
headless `--data` runs all use it. The root view model is `Partition`, and
paths below are relative to it. "rw" means writable by the host.

### 11.1 `app`

| Path | Type | rw | Meaning |
|---|---|---|---|
| `app/hosted` | bool | rw | Set by the shell. Enables save requests and hides the "not persisted" badge |
| `app/version` | string | | Program version |
| `app/platformMod` | enum `cmd\|ctrl` | rw | Key map modifier |

### 11.2 `song`

| Path | Type | rw | Meaning |
|---|---|---|---|
| `song/files` | list of `SongFile` | rw | Every file of the current song |
| `song/files[i]/path` | string | rw | Relative path, such as `channels/bass.ch` |
| `song/files[i]/text` | string | rw | Full contents. The editor writes it back on every edit (debounced) |
| `song/files[i]/revision` | number | rw | The writer increments it. The app reloads a file when the host bumps it |
| `song/files[i]/dirty` | bool | rw | The app sets it on edit. The host clears it after saving |
| `song/load` | trigger | rw | The host replaced `files`. The app reparses everything and keeps the playhead if it can |
| `song/new` | trigger | rw | Loads the empty template |
| `song/exampleId` | string | rw | Example to load, such as `deep-house` |
| `song/loadExample` | trigger | rw | Loads `exampleId` from the embedded bundles |
| `song/autoplay` | bool | rw | Starts playing after a load (used headless) |
| `song/examples` | list of `{id, title, description, bpm, genre}` | | The embedded catalogue |
| `song/title` | string | | From `song.yaml` |
| `song/durationSeconds` | number | | Including one pass of each infinite loop, without the tail |
| `song/rows` | number | | |
| `song/diagnostics` | list of `{path, line, col, endCol, severity, code, message}` | | |
| `song/errorCount` | number | | |

### 11.3 `editor`

| Path | Type | rw | Meaning |
|---|---|---|---|
| `editor/changed` | trigger | | Fires (debounced, 300 ms) after a user edit |
| `editor/lastChangedPath` | string | | File behind the last `changed` |
| `editor/saveRequested` | trigger | | `Mod+S` |
| `editor/clipboard` | string | rw | Clipboard mirror (§10.4) |
| `editor/copied` / `editor/pasteRequested` | trigger | | Clipboard bridge handshake |
| `editor/cursorPath`, `editor/cursorRow`, `editor/cursorCol` | string / number | rw | |
| `editor/follow` | bool | rw | |

### 11.4 `transport`

| Path | Type | rw | Meaning |
|---|---|---|---|
| `transport/play`, `pause`, `stop`, `playFromCursor` | trigger | rw | |
| `transport/state` | enum `stopped\|playing\|paused` | | |
| `transport/row`, `transport/bar`, `transport/beat` | number | | Current source position |
| `transport/seconds` | number | | Song time |
| `transport/bpm` | number | | Current tempo |
| `transport/loopEnabled`, `loopStartRow`, `loopEndRow` | bool / number | rw | |
| `transport/masterVolume` | number | rw | |
| `transport/load`, `transport/voices` | number | | Processor load (0..1, not measured yet) and voice count |
| `transport/position`, `transport/playLabel`, `transport/info` | string | | Display text for the toolbar and status bar |
| `transport/toggle`, `transport/loopToggle` | trigger | rw | Play/pause, and loop on/off (the selection's rows, or the cursor's bar) |

### 11.5 `render` (offline export)

| Path | Type | rw | Meaning |
|---|---|---|---|
| `render/sampleRate` | number | rw | 44100, 48000 (default) or 96000 |
| `render/format` | enum `pcm16\|float32` | rw | |
| `render/loops` | number | rw | Extra passes per infinite loop (§6.4) |
| `render/fromRow`, `render/toRow` | number | rw | 0 means song start / song end |
| `render/maxTail` | number | rw | Seconds |
| `render/start`, `render/cancel` | trigger | rw | |
| `render/state` | enum `idle\|rendering\|streaming\|done\|failed\|cancelled` | | |
| `render/progress` | number | | 0..1 |
| `render/error` | string | | |
| `render/totalBytes` | number | | Known once rendering finishes |
| `render/chunk` | blob | | The current chunk of the WAV file, header included in chunk 0 |
| `render/chunkIndex`, `render/chunkCount` | number | | |
| `render/chunkReady` | trigger | | `chunk` holds a new chunk |
| `render/ack` | trigger | rw | The host consumed the chunk, so the app publishes the next one |

`render/label` (string) is the export button's text. `editor/followToggle`
(trigger) and `editor/hint` (string, the status line) serve the chrome.

Chunks are 4 MB. If no host acknowledges within 2 s of `chunkReady`, a
standalone run ends with `done` and the render panel tells the user to export
through `rive --render-audio` (§13.2).

### 11.6 Change propagation rules

- **Host → app.** Write `text`, then bump `revision`. The app reloads that file,
  clamps the cursor, and records the replacement as one undo step. To replace
  the whole song, rewrite `files` and fire `song/load`.
- **App → host.** On edit, the app writes `text`, sets `dirty = true`,
  increments `revision` and fires `editor/changed`.
- **Conflicts.** The host decides. The app always shows the last `text` it
  received.

---

## 12. Rust shell (`partition`)

A native host that embeds the Rive runtime, loads `partition.riv`, and wires the
view-model contract to the file system. It holds no music logic.

### 12.1 Command line

```
partition [SONG_DIR | FILE.song]             open a window (default: last song, else the examples browser)
partition new DIR [--template ID]            create a song from a template (default: empty)
partition examples                           list the embedded examples
partition render SONG -o OUT.wav [--rate 48000] [--format pcm16|float32]
                 [--loops N] [--from ROW] [--to ROW]    headless WAV render
partition check SONG                         print diagnostics, exit 1 on errors
partition pack SONG_DIR -o FILE.song         folder → bundle
partition unpack FILE.song -o DIR            bundle → folder
```

With no subcommand, `partition` opens the window. `render` and `check` run
headless: no window and no audio device. They drive the same `.riv` through the
contract (§11) and wait for `render/state = done` or for diagnostics.

### 12.2 Wiring

| Event | Shell action |
|---|---|
| Open a song | Read every file → fill `song/files` → `app/hosted = true` → fire `song/load` |
| `editor/changed` | Write the dirty files atomically (temp file + rename), then clear `dirty`. Autosave by default. `--no-autosave` saves only on `saveRequested` |
| `editor/saveRequested` | Save now |
| File changed on disk (watcher, 100 ms debounce, ignoring the shell's own writes) | Set `text` and bump `revision`. If the file was dirty, keep the disk version and back up the in-app text to `<file>.partition-backup` |
| `editor/copied` / `pasteRequested` | Bridge to the OS clipboard |
| `render/chunkReady` | Append the chunk to `OUT.wav.part` → fire `render/ack` → on `done`, rename to `OUT.wav` |
| Window menu | Open, Save As, Export WAV (sets `render/*` then fires `render/start`) |

### 12.3 Runtime

The shell links the Rive C++ runtime (with its audio engine and AnimaScript
support) through FFI, or Rive's Rust bindings if they cover scripting and
audio (see §18). It opens a window with `winit`, uses the GPU renderer, and
forwards keyboard and text input. It uses `notify` for file watching, `arboard`
for the clipboard, and `clap` for the CLI. The `.riv` is built with
`rive rive/ --publish` (signed) and embedded in the binary with `include_bytes!`.

---

## 13. Standalone use (`rive` previewer)

### 13.1 Interactive

```
rive rive/ --aot          # open the app; --aot is needed for real-time DSP
```

The app opens on the examples browser. Every feature works except
persistence: edits live in memory and are lost on close, and a badge says so.
Opening a song from disk needs the shell. As a workaround in development, a
song can be dropped into `rive/assets/examples/` as a `.song` bundle, and the
watcher rebuilds the app.

### 13.2 Headless render with the stock CLI

```bash
# ask for the song length
rive rive/ --data-dump=- --data-dump-filter=song/durationSeconds \
     --data=song/exampleId=deep-house --data=song/loadExample=true --advance=2

# render it in real time through the processor (deterministic, no dropped blocks)
rive rive/ --render-audio=deep-house.wav --audio-rate=48000 \
     --data=song/exampleId=deep-house --data=song/autoplay=true \
     --data=song/loadExample=true --advance=<duration+tail>s
```

The rendered WAV is 32-bit float (a CLI limitation). It must match an offline
render at the same rate in float32 format (§14).

---

## 14. Testing

| Layer | How |
|---|---|
| Lexer, parser, diagnostics | `Tests` classes (`rive rive/ --test`). Golden AST and diagnostic lists for every command, unit, edge case (tabs, CRLF, orphan continuations, Unicode) |
| Timing | Row start times for tempo/rpb/sig changes, tempo ramps, swing, jump unrolling, play-from-row state replay |
| Score compiler | Event lists for patterns (overlay, state isolation, `times`, nesting, cycles), automation, chords |
| DSP | Per-module tests (oscillator aliasing bounds, envelope shapes, filter response at known frequencies, limiter ceiling) with `@job` functions called directly |
| Determinism | Offline render of each example hashed against a golden. Real-time `Engine` with random block sizes == offline render, bit-exact. `--render-audio` output == offline float32 render |
| Performance | `--bench` and processor load on the deep-house example at 64 voices, AOT, under 50 % of the block |
| Editor | `--screenshot` with `--key` / `--pointer` sequences (typing, continuation alignment, scroll sync, playhead), compared with `--compare` |
| Contract | `--data` + `--data-dump(-every)` runs that check every path in §11, including the render chunk handshake |
| Shell | Rust integration tests: open/save/watch round trips, `check` exit codes, `render` producing a valid WAV |

Before every commit: `rive rive/ --verify`, `rive inspect rive/ --summary`
(no problems), `rive rive/ --test --aot`. The audio tests render seconds of
sound per case, which only fits the runner's 2 s budget when compiled. On the
interpreter those five cases time out.

---

## 15. Repository layout

```
partition/
  docs/spec.md
  rive/                                 Rive project (rive.yaml, scripting: wasm)
    rive.yaml
    app.rml                             chrome, view models, listeners
    src/
      lang/      lexer.as parser.as ast.as types.as diagnostics.as yaml.as bundle.as
      score/     timeline.as compiler.as patterns.as automation.as score.as
      synth/     dsp.as osc.as env.as filter.as voice.as instrument.as fx.as engine.as
      audio/     processor.as render.as wav.as
      editor/    view.as doc.as bands.as highlight.as overview.as docs.as rail.as filelist.as
      app/       app.as bindings.as songs.as
      tests/     *.as  (Tests classes)
    assets/
      fonts/Iosevka-*.ttf, BarlowSemiCondensed-*.ttf
      presets/*.inst
      examples/index.json, example-*.song
  shell/                                Rust crate `partition`
    Cargo.toml
    src/ main.rs cli.rs host.rs contract.rs fs.rs render.rs
```

Blob assets in an RML project must be declared, as
`<BlobAsset file="assets/examples/example-deep-house.song" name="example-deep-house"/>`.
`context.blob()` looks them up by that `name` only, not by path. Files that are
not declared are not in the build (verified in M0). Names must therefore be
unique (hence `example-deep-house.song`).

---

## 16. Bundled examples

Every example is a `.song` bundle in `rive/assets/examples/`, declared as a
blob asset in `scene.rml` and listed in `rive/src/app/examples.as`. Each one uses only presets and song-local instruments, has a
conductor with marks, and uses at least one pattern and one automation.

| Id | Title | bpm | Shows |
|---|---|---|---|
| `empty` | Empty song | 120 | template: conductor plus 4 empty channels (`drums`, `bass`, `keys`, `lead`) |
| `deep-house` | Late Night Deep House | 122 | four-on-the-floor, offbeat organ bass, min9 stabs with delay, filter ramps, breakdown |
| `lofi` | Rainy Lo-Fi | 84 | swing, e-piano chords with `strum`, vinyl noise channel |
| `techno` | Warehouse | 132 | 24 dB acid bass with `lfo`, long `ramp` builds, `jump` loops |
| `ambient` | Drift | 70 | long pads, reverb sends, `glide`, rpb 2 |
| `chiptune` | Pixel Quest | 150 | square/pulse leads with `pw` LFO, arpeggios from patterns |
| `jazz` | Blue Hour | 140 | swing, ii–V–I changes, walking bass, brushed drums |
| `bossa` | Copacabana Night | 128 | bossa clave, plucked maj7 chords with inversions and spread |
| `dnb` | Liquid Circuit | 174 | breakbeats with ghost notes, a reese bass with a filter LFO |
| `synthwave` | Neon Freeway | 100 | arps, supersaw chords, gated snare, gliding lead |
| `trance` | Euphoria | 138 | rolling arps from nested patterns, a filtered build and drop |
| `dub-techno` | Deep Fog | 120 | chord stabs in delay and reverb, cutoff LFO |
| `invention` | Two-Part Invention | 84 | baroque counterpoint: subject, answer, sequences with `transpose` |
| `waltz` | Paper Lanterns | 156 | 3/4 time, oom-pah-pah bass, strings and bells |
| `seven-steps` | Seven Steps | 132 | 7/8 and 5/4 sections through `sig` changes |
| `funk` | Slick | 104 | popping bass, clavinet riff, horn stabs, ghost notes with `at:` |
| `trap` | Midnight Drip | 140 | half-time drums, 808 glides, hi-hat rolls |
| `garage` | 2-Step Sunday | 132 | shuffled 2-step drums, organ stabs |
| `boss-battle` | Final Gate | 168 | chromatic chiptune riffs, a meter change, an accelerando with `ramp(bpm:)` |
| `tidal` | Tidal | 60 | patterns of 5, 7, 11 and 13 rows drifting in and out of phase |
| `disco` | Mirrorball | 120 | octave bass, string stabs, a long filter sweep |
| `reggae` | Island Drift | 76 | one-drop rhythm, offbeat skank, bubbling organ |

The toolbar's **Examples ▾** button opens a dropdown listing every example in
two columns (an `ArtboardComponentList` of `ExampleRow` components bound to
`song/examples`). Clicking a row fires that item's `select` trigger, and the
app loads the song. The current song is marked, and rows highlight on hover.
`song/examplesToggle`, `song/examplesDisplay` (the panel's `displayValue`:
0 shown, 1 hidden) and `song/examplesLabel` drive it. A click outside the
panel or Escape closes it. Each `ExampleInfo` also carries `select`,
`subtitle`, `hover` and `current`.

### 16.1 `deep-house` (excerpt)

In these excerpts, `…` stands for rows left out of the listing. It is not syntax.

`song.yaml`: 122 bpm, 4/4, `rows_per_beat: 4`, channels
`kick hats clap bass chords pad`.

`conductor.ch`:
```
mark(name: intro)
… (rows 2–128 empty: 8 bars)
mark(name: groove)
… 256 rows
jump(to: groove, times: 1)
mark(name: breakdown)
	ramp(master: -3dB, over: 8bar)
… 128 rows
mark(name: drop)
	master(vol: -1dB)
…
end()
```

`patterns/four_floor.pat` (one bar, 16 rows):
```
note(p: C1)



note(p: C1)



note(p: C1)



note(p: C1)



```

`channels/kick.ch`:
```
inst(name: kick_deep); vol(v: 0.9)
	pattern(name: four_floor, times: 24)
```

`channels/bass.ch` (offbeat organ bass, Am9 → Dm9):
```
inst(name: organ_bass); len(v: 1/16); vel(v: 0.7); oct(v: 2)
	set(cutoff: 600, res: 0.25)


note(p: A)
…
note(p: A); vel(v: 0.9)
…
ramp(cutoff: 1.8k, over: 16bar, curve: exp)
```

`channels/chords.ch`:
```
inst(name: stab); set(delay: 0.35, reverb: 0.3); len(v: 1/8)
	lfo(param: cutoff, rate: 2bar, depth: 0.4)
…
chord(root: A3, type: min9, inv: 1)
…
chord(root: D3, type: min9)
```

The full songs are written during milestone M6.

---

## 17. Milestones

| # | Deliverable | Exit criteria |
|---|---|---|
| M0 ✅ | **Spike**: verify §2.2 assumptions (`spikes/m0`, findings in `docs/m0-findings.md`) | Blob lookup names with folders; key codes; `<FocusData/>` focus in an RML layout; processor at 64 voices under AOT; job → Blob → `PropertyBlob` chunk readable by the host runtime |
| M1 ✅ | Language: lexer, parser, types, diagnostics, YAML subset, bundles (`rive/src/lang`) | Parser test suite green |
| M2 ✅ | Score: timeline, conductor, patterns, automation, compiler (`rive/src/score`) | Timing and score test suites green |
| M3 ✅ | Synth engine + presets + offline render + WAV (`rive/src/synth`, `rive/src/audio`) | Golden renders, determinism tests |
| M4 ✅ | `PartitionProcessor`, transport, live score swap, watchdog (`audio/processor.as`, `app/transport.as`) | Plays the examples glitch-free with AOT |
| M5 ✅ | `ChannelGrid` editor: aligned bands, synced scroll, editing, highlighting, playhead (`rive/src/editor`) | Screenshot tests |
| M6 ✅ | RML chrome, view-model contract, examples (`rive/scene.rml`, `rive/src/app`, `rive/assets/examples`) | Contract tests, all six examples |
| M7 | Rust shell: window, wiring, watch, CLI, headless render | Shell integration tests |

---

## 18. Open questions and risks

1. **Comments.** v1 has no comment syntax (per the current scope). Text-only
   songs get hard to read without them. Should `//` to end of line come in v1.1?
2. **Positional shorthand.** `note(C4)` for a command's main argument would
   halve typing. Should it come in v1.1?
3. **Host runtime.** Does the Rive C++ runtime (or the Rust bindings) available
   to the shell let a host read a view model **blob** property? The CLI's data
   dump cannot (`blobs report their type only`). Fallback: chunk the WAV as
   base64 in a string property. That costs 33 % more and needs a decoder in the
   shell, which is acceptable.
4. **Host audio.** The shell must use the runtime's built-in audio engine with
   AnimaScript processors. This needs confirming for an embedded runtime (M0).
5. **Text input.** No IME composition or dead keys are documented, so typing
   accented characters may fail on some layouts. Commands are ASCII, so this
   affects only strings.
6. **Web.** `--publish=web` needs threads and cross-origin isolation for
   processors, and frame clocks drift on the web (§2.2). The web is out of
   scope for v1.
7. **Real-time DSP headroom.** The interpreter tier cannot run the engine.
   `--aot` is required, and debug builds with fuel run 20–33 % slower. The
   standalone previewer must therefore always be launched with `--aot`.
