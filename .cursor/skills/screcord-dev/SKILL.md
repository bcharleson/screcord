---
name: screcord-dev
description: >-
  Develop and extend the screcord macOS screen recorder: ScreenCaptureKit +
  AVFoundation architecture, SwiftPM/Makefile builds, CLI flags, audio tracks,
  permissions, and contribution workflow. Use when changing screcord source,
  adding features, fixing capture bugs, or building the open-source repo.
---

# screcord-dev — build the recorder

## Stack (do not replace without strong reason)

- **Swift 5.9+** executable, **zero third-party packages**
- **ScreenCaptureKit** for display + system audio (+ mic on macOS 15+)
- **AVFoundation** `AVAssetWriter` for H.264/AAC MP4; mic fallback on macOS 13–14
- Manual CLI parsing in `CLI.swift` (no ArgumentParser)

## Repo map

| Path | Role |
|------|------|
| `Sources/screcord/ScrecordApp.swift` | `@main`, countdown, Ctrl+C / duration stop |
| `Sources/screcord/CLI.swift` | argv parsing + help text |
| `Sources/screcord/ScreenRecorder.swift` | SCStream + writer + sample handlers |
| `Sources/screcord/DeviceLister.swift` | `devices` command |
| `Sources/screcord/Permissions.swift` | mic auth |
| `Sources/screcord/Types.swift` | options, region, display ordering |
| `Resources/Info.plist` | mic usage string (linked into binary) |
| `Makefile` | release build with `--build-system native` + Info.plist sectcreate |

## Agent workflow when changing code

```
Dev:
- [ ] 1. Read architecture.md + touch only needed files
- [ ] 2. Implement focused change (keep files ~<300 lines)
- [ ] 3. make build
- [ ] 4. Smoke: screcord devices
- [ ] 5. Smoke: record --audio none --countdown 0 --duration 2 -o /tmp/screcord-smoke.mp4
- [ ] 6. Update CLI help + README/.cursor skills if UX changed
```

### Build

```bash
make build          # preferred (CLI Tools–safe)
make debug
make test-devices
```

Default `swift build` may fail without full Xcode XCBuild — always prefer `make`.

### Hard rules

1. **No new dependencies** unless the user explicitly asks.
2. Keep **separate** `AVAssetWriterInput`s for system vs mic audio (never mux mismatched formats into one input).
3. Only append **complete** screen frames (`SCFrameStatus.complete`).
4. Start the writer session on the **first video** sample PTS; drop earlier audio.
5. Finalize with `markAsFinished` + `finishWriting` — never leave Ctrl+C as raw kill.
6. Embed mic privacy via `Resources/Info.plist` + Makefile `sectcreate` (do not rely on a plist inside `Sources/`).
7. Display index `0` = `CGMainDisplayID()` via `DisplayResolver.ordered`.

## Feature extension guide

| Feature | Where to change |
|---------|-----------------|
| New CLI flag | `CLI.swift` + help string + `RecordOptions` |
| Capture config | `ScreenRecorder.makeStreamConfiguration` |
| Encode quality | `prepareWriter` / `makeAudioInput` |
| Device listing | `DeviceLister.swift` |
| Stop semantics | `ScrecordApp` + `StopSignal` |

Before adding GUI: keep CLI complete; any GUI should shell out to the same recorder core.

## Permissions testing

- Empty displays → Screen Recording denied for launching app
- Mic silent / prompt missing → rebuild with Makefile so Info.plist is embedded; check Microphone privacy

## Docs to keep in sync

If flags or defaults change, update:

1. `CLI.printHelp()`
2. `README.md`
3. `.cursor/skills/screcord/SKILL.md` + `reference.md`

## More detail

- Architecture notes: [architecture.md](architecture.md)
