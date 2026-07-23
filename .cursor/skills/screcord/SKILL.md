---
name: screcord
description: >-
  Record macOS screens for YouTube tutorials and B-roll with screcord: identify
  displays, presets, window/app capture, live audio meters, pause/markers,
  webcam companion files, and headless agent recordings. Use when recording
  screen, screencast, tutorial capture, or running screcord.
---

# screcord — YouTube / tutorial capture

CLI-first, headless-friendly ScreenCaptureKit recorder. Prefer this over ⌘⇧5.

## Resolve binary

```bash
command -v screcord || echo "$HOME/.local/bin/screcord"
# or: make build && .build/release/screcord
```

## Pick the right screen (don’t guess)

```bash
screcord devices          # names + left/right of main
screcord identify         # flash big [0]/[1] badges on each monitor
screcord record --display main
screcord record --display "Studio Display"
```

## Presets (tutorials & B-roll)

| Preset | Use for |
|--------|---------|
| `--preset tutorial` | Talking + screen, mic+system, cursor on |
| `--preset broll` | Clean B-roll, system audio, no cursor, high bitrate |
| `--preset clean-ui` | UI demos without pointer |
| `--preset motion` | 60fps silky UI motion |

```bash
screcord record --preset tutorial --slug auth-flow
screcord record --preset broll --display main --duration 20
```

## Agent / headless workflow

```
- [ ] screcord devices / identify (if human present)
- [ ] Choose preset + --slug
- [ ] Unattended: --headless --duration N (required for agents)
- [ ] Watch meters / probe output for silent failures
- [ ] Report output path + probe summary
```

```bash
screcord record --preset broll --headless --duration 30 \
  --display 0 --slug demo -o "$HOME/Desktop/demo.mp4"
```

`Scripts/agent-record.sh` also works (requires `--duration`).

## Avoid silent takes

- Live meters on TTY by default: `♪ sys:… mic:…`
- `--meters` / `--no-meters`
- `--idle-stop 90` auto-stops after silence
- Post-record **Probe** prints duration/resolution/audio presence

## Window / app capture

```bash
screcord windows
screcord record --window "Notion" --preset clean-ui
screcord record --app Safari --audio system
```

## During attended recording (TTY)

- `p` pause/resume (jump-cut, paused time removed)
- `m` chapter marker → `*.chapters.json` + YouTube timestamps
- `q` / Ctrl+C stop

## Extra

- `--webcam` → companion `*-cam.mp4` for PIP in the editor (not burned in)
- `--highlight-clicks` (needs Accessibility)
- `--exclude-self` default on (hides terminal/Cursor from display capture)

## Reference

- Flags: [reference.md](reference.md)
