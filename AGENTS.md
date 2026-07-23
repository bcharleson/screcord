# AGENTS.md — screcord

Agent entrypoint for this repository.

## What this is

`screcord` is a macOS CLI that records the screen (and optional system audio / microphone) to H.264 + AAC `.mp4` using **ScreenCaptureKit** and **AVFoundation**. No BlackHole, no ffmpeg required for the default path.

## Read these skills

| Skill | When |
|-------|------|
| [`.cursor/skills/screcord/SKILL.md`](.cursor/skills/screcord/SKILL.md) | User wants to **record**, pick a display, or run demos |
| [`.cursor/skills/screcord-dev/SKILL.md`](.cursor/skills/screcord-dev/SKILL.md) | Changing **source**, fixing capture, adding flags/features |

## Quick commands

```bash
make build
screcord devices
screcord identify --seconds 2
screcord record --preset broll --headless --duration 5 --slug smoke
# Debug capture pipeline: SCRECORD_DEBUG=1 screcord record ...
```

## Non-negotiables

1. Zero third-party package dependencies unless explicitly requested
2. Prefer `make build` / `make install`
3. Never force-kill an in-progress recording if you can send SIGINT
4. Keep agent-facing docs in sync when CLI behavior changes

## Layout

```
Sources/screcord/     Swift sources
Resources/Info.plist  Embedded privacy strings
Makefile              Release build + install
.cursor/skills/       Agent skills
.cursor/rules/        Always-on project rule
```
