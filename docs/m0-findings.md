# M0 findings

Spike project: `spikes/m0` (Rive CLI 1.8.0). It is reproducible with the
commands shown under each check. All runs are headless on macOS (Apple
silicon).

## Summary

| Check (spec §17) | Result |
|---|---|
| Blob lookup names | ✅ Resolved: declared `<BlobAsset name>` only |
| Key codes | ✅ GLFW codes, with modifiers |
| `<FocusData/>` focus in an RML layout | ✅ Keys reach the scripted layout |
| Text input (`textEvent`) | ⚠️ Not checked: `--key` does not produce text events. Needs the live window |
| View-model trigger from outside | ✅ `--data=go=1` fires a listener added with `addListener` |
| Job → `Blob` → `PropertyBlob` | ✅ Works inside the script. The host side is checked in M7 |
| Processor at 64+ voices under AOT | ✅ Large margin. The interpreter is not viable for the real engine |
| `--render-audio` output | ✅ 32-bit float stereo WAV, 48 kHz, deterministic |
| Layout lifecycle | ⚠️ `init` runs twice. Spec §2.2 item 8 |

## Details

### Blob assets

In an RML project, `context.blob(name)` finds only assets declared as
`<BlobAsset file="songs/example-a.song" name="example-a"/>`, and only by
`name`. The path (`songs/example-a`) returns null. So does an undeclared file
at the project root (`top`, `top.txt`). Spec §15 now says this.

```
m0: blob 'example-a' -> 47 bytes, first line '%partition-bundle 1'
m0: blob 'songs/example-a' -> null
m0: blob 'top' -> null
m0: blob 'top.txt' -> null
```

### Keyboard and focus

`rive spikes/m0 --data-dump=- --key=a --key=backspace --key=enter:down+meta --key=tab --advance=30`

The player focuses the first `FocusData`, which is a direct child of the
`ScriptedLayout`. Codes follow GLFW:

| Key | `key` |
|---|---|
| `a` | 65 |
| backspace | 259 |
| enter | 257 |
| tab | 258 |

`meta`, `shift`, `control` and `alt` arrive as flags, and phases come as
`down`, `repeat` and `up`.

Synthesized keys produce no `textEvent`. Typing into the editor therefore
cannot be tested headless through `--key`. The editor tests in M5 must drive
the text path directly, or run in the live window.

### View model

The trigger `go`, fired with `--data=go=1`, reaches a listener added in `init`
through `vm.getTrigger("go").addListener(...)`.

A `@job` rendered one second of sine into a `Blob` (192 000 bytes). The main
lane then set it on a `ViewModelPropertyAssetBlob` through
`PropertyBlob.value`, and reading it back gave 192 000 bytes. `--data-dump`
lists blob properties by type only, as the docs say. Whether an embedding host
can read the bytes is still the open risk in spec §18.3, which M7 checks.

### Layout lifecycle

In every headless mode, `init` runs twice. The first instance has no bound view
model, and `dispose` runs on it immediately. The second instance is bound.

```
m0: no view model bound
m0: dispose
m0: listening on trigger go
m0: dispose        (end of run)
```

The app must stop its processors in `dispose`, or the throwaway instance
leaves a second processor in the mix.

### Audio processor load

The stress processor runs N naive saw oscillators, each with a one-pole filter
and no allocation. The command was
`rive spikes/m0 --render-audio --data=voices=N --advance=10s [--aot]`. The
render column below is wall time for 10 s of audio, without the build.

| Voices | Tier | Render of 10 s audio |
|---|---|---|
| 64 | interpreter | ≈ 1.26 s (13 % of real time) |
| 64 | AOT `-O3` | ≈ 0.04 s |
| 256 | interpreter | ≈ 4.9 s (49 % of real time) |
| 256 | AOT `-O3` | ≈ 0.16 s (1.6 % of real time) |

A real voice (oscillators, filter, envelopes) costs roughly 10× this toy one.
AOT leaves a large margin at 64 voices, while the interpreter would overrun.
This confirms spec §2.2 item 6: always run with `--aot`.

The output was a 32-bit float stereo WAV at 48 kHz (format 3), with a peak of
0.43. The level was as expected.

## Measured in M1/M2 (for §9.7)

The song was 16 channels × 2000 rows, about 42 000 events. Each figure is a
`rive rive --test` timing.

| Step | Interpreter | AOT |
|---|---|---|
| First parse and check | 528 ms | 246 ms |
| Compile score | 98 ms | 19 ms |
| Edit one channel (re-parse that file, reuse the other checks) | 26 ms | 3 ms |
| Recompile after the edit | 95 ms | 15 ms |

Under AOT, an edit costs 18 ms, within the 30 ms target. On the interpreter it
is about 120 ms, which fits the 200 ms frame budget but not the target. This is
why §9.1 moves large compiles to a `@job` in M4.
