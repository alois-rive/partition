# partition
Composing music with text.

Each channel is a column of text where every line is a time step, and each
line holds commands such as `note(p: C4, len: 1/8); vol(v: 0.8)`. Columns sit
side by side and scroll together, and the song plays while you edit it. The
synthesis runs in AnimaScript on Rive's audio engine.

Specification: [docs/spec.md](docs/spec.md).

## Run it

```bash
rive rive --aot      # the app, opening on the deep-house example; --aot is needed for real-time audio
```

In the window:
- **Play and stop:** Cmd+Enter plays and pauses, Cmd+Shift+Enter plays from the cursor's row, and Cmd+. stops.
- **Audition:** Alt+Enter plays just the cursor's row.
- **Loop:** Cmd+L loops the selected rows, or the cursor's bar.
- **Documentation:** **Docs** in the title bar (or Cmd+/) opens a reference for every command, scrolled to the one under the cursor.
- **Tabs:** the rail on the left switches between Tracks (Cmd+1), Patterns (Cmd+2), Instruments (Cmd+3), Samples (Cmd+4) and Song settings (Cmd+5 or Cmd+,, the cog at the bottom). Settings edits song.yaml as a form: title, tempo, signature, rows per beat, swing, master volume, and the track list. In Patterns and Instruments, a list adds, renames (F2) and deletes files; renaming updates every reference. Play there loops only the selected pattern, or an example phrase on the selected instrument.
- **Overview:** each column starts with a strip that draws every command as a line or shape. Cmd+E collapses a column to just its strip; **Collapse all** (Cmd+Shift+E) shows the whole song at once, with Cmd+= and Cmd+- to zoom.
- **Samples:** the Samples tab imports audio files (with the `partition` app) or records any instrument into a sample. It shows the waveform with a selection to play, trim, cut, normalize, reverse, fade or change the gain of (with undo), and makes an instrument that plays it. Instruments play samples with `sample(file: …)`: zones across the keyboard, slices of a break, loops, one-shots, reverse and choke groups (spec §7.4, §10.11). Try the **Chopped** example.
- **Mixer:** `fx(type: eq|comp|dist|chorus|phaser|filter, …)` builds an effect chain on a track, a bus (`buses:` in song.yaml, shown after the tracks) or the master (in `conductor.ch`). Compressors take a `sidechain: kick`, tracks play into a group bus with `bus:` or send to one with `set(send.space: 0.3)`, every effect parameter can be set, ramped or modulated (`ramp(filter.cutoff: 8k, over: 4bar)`), and the footer shows the loudness in LUFS (spec §7.5). Try the **Pump** example.
- **Keys and variations:** `key(root: A, mode: minor)` (song-wide in the conductor, or per track) lets notes be written as scale degrees (`note(d: [1, 3, 5])`, `chord(d: 2)`) and chords as progressions (`prog(chords: "ii V7 I", every: 1bar)`). Patterns take arguments (`pattern(name: riff, root: F3, busy: true)`, used inside as `$root`, defaults with `args(...)`), and any command can play on some passes only (`on: 4/4`, `except: 4/4`, `if: $busy`) for fills and variations (spec §5.6, §8.1, §8.2). Try the **Variations** example.
- **Randomness:** `prob:` on any command, `humanize(time: 8ms, vel: 0.1)`, Euclidean rhythms (`euclid(hits: 5, steps: 16, p: C4)`), random picks of notes (`note(d: [1, 3, 5], pick: 1)`) and of patterns (`pick(from: [fill_a, fill_b])`). It all follows `song.yaml`'s `seed:` (Settings has a Shuffle button), so the same seed always renders the same song, and every pass of a loop is different (spec §6.5). Try the **Drift Machine** example.
- **Sound design:** wavetable oscillators (`osc(wave: table, table: formant, pos: 0.4)`, or a sample's cycles), a modulation matrix per voice (`mod(src: lfo1, dst: pos, amt: 0.3)` from envelopes, voice LFOs, velocity, key, random, pressure and bend), stereo voices (`voice(width: 0.8)`, stereo samples), per-note expression (`note(p: A4, bend: 2st, press: 0.8)`) and tunings (`tuning(v: just)`, `edo` with any number of steps, or Scala `.scl` files in `tunings/`) (spec §7.6). Try the **Wavefront** example.
- **Mute and solo:** Cmd+M mutes the current channel and Cmd+Shift+S solos it. The M and S buttons in each column header do the same.
- **Toolbar:** **Examples ▾** opens a dropdown of the 27 bundled songs, **New** starts an empty one, and **Export WAV** renders the song. Saving to disk needs the shell (below); in the plain previewer, edits stay in memory.

Render a song to WAV without a window:

```bash
rive rive --render-audio=song.wav --data=song/exampleId=techno --data=song/autoplay=true --advance=70s
```

## The `partition` shell

`shell/` is a Rust command line that opens songs from disk in a window and keeps them saved, and renders and checks them without one (spec §12). It runs the app on the Rive CLI, so `rive` must be installed and signed in. Milestone M8 (spec §17.1) replaces the CLI with the Rive engine linked into the shell, once its bindings run AnimaScript and the audio engine.

```bash
cd shell && cargo build --release        # or download a macOS release (Releases on GitHub)
partition new my-song --template deep-house
partition my-song                         # the window; every edit is saved to my-song/
partition check my-song                   # diagnostics; exit 1 on errors
partition render my-song -o my-song.wav   # headless; --rate, --format pcm16|float32, --loops, --from, --to, --tail
partition pack my-song -o my-song.song    # and `unpack`, `examples`
```

In the window, Export WAV writes `my-song/exports/<title>.wav`. Edits made to the song's files elsewhere (another editor, git) reopen it in the window. `cargo test` runs the shell's tests (the `check` and `render` ones use the Rive CLI when it is on `PATH`).

Releases: pushing a `v<version>` tag that matches `shell/Cargo.toml` makes the Release workflow build a universal macOS binary (signed ad hoc, not notarized) and publish it with its checksum. Run the workflow by hand to get the build as an artifact only. After downloading, `xattr -d com.apple.quarantine partition` lets macOS run it.

## Web

Published on UAT at https://partition-kqeo1q.uat.rive.to (UAT pages expire). `rive.yaml` binds the page to the UAT team, so republish with:

```bash
rive rive --publish=web --uat
```

## Layout

- `rive/`: the Rive program.
  - `src/lang`: the channel language (M1).
  - `src/score`: the score compiler and presets (M2/M3).
  - `src/synth`: the synth engine (M3).
  - `src/audio`: the processor, offline render and WAV (M3/M4).
  - `src/editor`: the channel grid (M5).
  - `src/app`: the app, transport, export and view-model bindings (M4/M6).
  - `scene.rml`: the chrome and the view-model contract (M6).
  - `assets/examples`: the 27 bundled songs (`chopped`, `pump`, `variations`, `generator` and `wavefront` are made by the scripts in `tools/`).
  - `src/tests`: the test suites.
- `shell/`: the `partition` shell (M7), with `.github/workflows` for CI and macOS releases.
- `spikes/m0/`: the platform spike, with results in [docs/m0-findings.md](docs/m0-findings.md).

## Checks

```bash
rive rive --verify          # compile and type-check
rive inspect rive --summary # lint the scene
rive rive --test --aot      # run the test suites (the audio tests need compiled code)
```

Fonts: Iosevka (code) and Barlow Semi Condensed (labels), both under the SIL Open Font License (`rive/assets/fonts/`), subset to the characters the app uses.

The chrome (`rive/scene.rml`) is generated: after changing `tools/gen_scene.py` or adding an example song, run `python3 tools/gen_scene.py`.
