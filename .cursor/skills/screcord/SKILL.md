---
name: screcord
description: >-
  Record the macOS screen with screcord (ScreenCaptureKit CLI): list displays,
  pick a screen/region, capture system audio and/or microphone, and save H.264
  AAC MP4s. Use when the user asks to record the screen, capture a demo,
  screencast, pick which display to record, or run screcord from an agent.
---

# screcord — record macOS screens

Zero-dependency Swift CLI. Prefer this over ⌘⇧5 when betas break native recording.

## Binary resolution

Try in order:

1. `screcord` on `PATH`
2. `$HOME/.local/bin/screcord`
3. Repo build: `make build` then `.build/release/screcord`

```bash
command -v screcord || echo "$HOME/.local/bin/screcord"
```

## Agent workflow

Copy and track:

```
Recording:
- [ ] 1. Resolve binary
- [ ] 2. screcord devices  (pick display index)
- [ ] 3. Confirm audio mode + output path
- [ ] 4. Start record (--duration for unattended; else tell user Ctrl+C)
- [ ] 5. Verify .mp4 exists and report path
```

### 1. List screens

```bash
screcord devices
```

- Index `[0]` is the **main** display (`[main/default]`).
- Match by resolution when the user says “the big monitor” / “laptop”.
- If displays are empty → Screen Recording permission missing for the **terminal app that launched** screcord.

### 2. Start recording

**Attended** (user stops with Ctrl+C):

```bash
screcord record --display 0 --audio both --countdown 3
```

**Unattended / agent-driven** (always pass `--duration`):

```bash
screcord record --display 0 --audio system --countdown 0 --duration 30 \
  -o "$HOME/Desktop/screcord-demo.mp4"
```

For long agent jobs, run in background and do not block the session forever without `--duration`.

### 3. Common recipes

| Goal | Command |
|------|---------|
| Main screen, system+mic | `screcord record` |
| System audio only, no cursor | `screcord record --audio system --no-cursor` |
| Mic only | `screcord record --audio mic` |
| Second display, 30s | `screcord record --display 1 --duration 30` |
| Region | `screcord record --region 0,0,1280,720` |
| Silent video smoke test | `screcord record --audio none --countdown 0 --duration 3 -o /tmp/screcord-smoke.mp4` |

### 4. Stop / output

- Stop: **Ctrl+C** or SIGTERM (finalizes MP4). Do not `kill -9`.
- Default output: `~/Desktop/screcord-YYYY-MM-DD-HHmmss.mp4`
- After recording, print the absolute path and file size.

## Permissions

If capture fails or device list is empty:

1. System Settings → Privacy & Security → **Screen & System Audio Recording** → enable the terminal/IDE
2. **Microphone** → same app (for `mic` / `both`)
3. Quit and relaunch that app, retry

## Decision rules

- User did not specify display → use `--display 0` (main), mention it.
- User wants a quick clip and will not babysit → require `--duration`.
- User wants voiceover → `--audio both` or `mic`.
- Avoid interactive countdown in CI/agent loops → `--countdown 0`.

## More detail

- Full CLI flags: [reference.md](reference.md)
