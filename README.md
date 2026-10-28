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
- **Mute and solo:** Cmd+M mutes the current channel and Cmd+Shift+S solos it. The M and S buttons in each column header do the same.
- **Toolbar:** **Examples ▾** opens a dropdown of the 22 bundled songs, **New** starts an empty one, and **Export WAV** renders the song. Saving to disk needs a host (spec §12); in the previewer, edits stay in memory.

Render a song to WAV without a window:

```bash
rive rive --render-audio=song.wav --data=song/exampleId=techno --data=song/autoplay=true --advance=70s
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
- `spikes/m0/`: the platform spike, with results in [docs/m0-findings.md](docs/m0-findings.md).

## Checks

```bash
rive rive --verify          # compile and type-check
rive inspect rive --summary # lint the scene
rive rive --test --aot      # run the test suites (the audio tests need compiled code)
```

JetBrains Mono is bundled under the SIL Open Font License (`rive/assets/fonts/OFL-JetBrainsMono.txt`).
