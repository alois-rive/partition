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
- **Tabs:** the rail on the left switches between Tracks (Cmd+1), Patterns (Cmd+2), Instruments (Cmd+3) and Song settings (Cmd+4 or Cmd+,, the cog at the bottom). Settings edits song.yaml as a form: title, tempo, signature, rows per beat, swing, master volume, and the track list. In Patterns and Instruments, a list adds, renames (F2) and deletes files; renaming updates every reference. Play there loops only the selected pattern, or an example phrase on the selected instrument.
- **Overview:** each column starts with a strip that draws every command as a line or shape. Cmd+E collapses a column to just its strip; **Collapse all** (Cmd+Shift+E) shows the whole song at once, with Cmd+= and Cmd+- to zoom.
- **Mute and solo:** Cmd+M mutes the current channel and Cmd+Shift+S solos it. The M and S buttons in each column header do the same.
- **Toolbar:** **Examples ▾** opens a dropdown of the 22 bundled songs, **New** starts an empty one, and **Export WAV** renders the song. Saving to disk needs the shell (below); in the plain previewer, edits stay in memory.

Render a song to WAV without a window:

```bash
rive rive --render-audio=song.wav --data=song/exampleId=techno --data=song/autoplay=true --advance=70s
```

## The `partition` shell

`shell/` is a Rust command line that opens songs from disk in a window and keeps them saved, and renders and checks them without one (spec §12). It runs the app on the Rive CLI, so `rive` must be installed and signed in.

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
  - `assets/examples`: the 22 bundled songs.
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
