# screcord

**Reliable macOS screen recorder** built on Apple’s modern capture stack — [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) + [AVFoundation](https://developer.apple.com/av-foundation/).

A lightweight CLI alternative when the built-in **⌘⇧5** recorder misbehaves (common on macOS betas), or when you need predictable H.264/AAC `.mp4` output with system audio and microphone.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](#requirements)

## Why screcord?

| | ⌘⇧5 / Screenshot app | screcord |
|---|---|---|
| System audio | Often flaky / limited | Native via ScreenCaptureKit (no BlackHole) |
| Output control | Limited | H.264 + AAC `.mp4`, bitrate/fps knobs |
| Automation | Weak | First-class CLI |
| Beta stability | Frequently broken | Thin wrapper over the modern API |
| Dependencies | — | **Zero** third-party packages |

## Features

- Full display, region, **window**, or **app** capture
- `screcord identify` — flash big index badges on each monitor
- Display names + placement (`left of main`, etc.) and `--display main|"Name"`
- Presets: `tutorial` · `broll` · `clean-ui` · `motion`
- Audio modes: `none` · `system` · `mic` · `both`
- **Live loudness meters** in the terminal (catch silent takes)
- Pause / resume (`p`), chapter markers (`m`) → YouTube timestamp JSON
- `--idle-stop` after silence · `--slug` filenames · post-record probe
- Optional `--webcam` companion file for PIP in your editor
- `--highlight-clicks` · `--exclude-self` (hide terminal from the take)
- Clean stop via **Ctrl+C** / `q` / `--duration`
- Defaults: **30 fps**, high bitrate H.264, AAC 192 kbps
- Zero third-party dependencies · agent skills in `.cursor/skills/`

## Requirements

- macOS **13 Ventura** or later (Apple Silicon recommended)
- Swift 5.9+ (Xcode or Command Line Tools)
- Permissions:
  - **Screen & System Audio Recording** for your terminal app
  - **Microphone** when using `--audio mic` or `--audio both`

## Install

### From source (recommended)

```bash
git clone https://github.com/bcharleson/screcord.git
cd screcord
make install          # installs to /usr/local/bin/screcord
# or: PREFIX="$HOME/.local" make install
```

Or use the helper script:

```bash
./Scripts/install.sh
```

### Build only

```bash
make build
./.build/release/screcord --help
```

> **Note:** On machines with Command Line Tools only (no full Xcode), the Makefile uses SwiftPM’s `native` build system. That is intentional and reliable.

## Permissions (first run)

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**
2. Enable your terminal (**Terminal**, **iTerm2**, **Warp**, **VS Code**, **Cursor**, etc.)
3. For mic capture: **Privacy & Security → Microphone** → enable the same app
4. Quit and relaunch the terminal, then re-run `screcord`

The microphone privacy string is embedded in the binary via `Resources/Info.plist`.

## Usage

```bash
# See which screen is which
screcord devices
screcord identify

# Tutorial take (mic + system, cursor on)
screcord record --preset tutorial --slug auth-flow

# Clean B-roll
screcord record --preset broll --display main

# Single window
screcord windows
screcord record --window "Notion" --preset clean-ui

# Agent / unattended
screcord record --preset broll --headless --duration 30 --slug demo
```

While recording in a TTY: **`p`** pause · **`m`** marker · **`q`** / **Ctrl+C** stop.

Live meters look like: `♪ sys: -12.0dB [########....]  mic: -28.0dB [###.........]`

### Options

Run `screcord help` for the full list. Highlights:

| Option | Description |
|---|---|
| `--preset tutorial\|broll\|clean-ui\|motion` | Opinionated defaults for YouTube work |
| `-d, --display <n\|name\|main>` | Pick screen by index or name |
| `-w, --window` / `--app` | Window or app capture |
| `--meters` / `--no-meters` / `--headless` | Loudness UI |
| `--idle-stop <sec>` | Auto-stop after silence |
| `--slug <name>` | Tag Desktop filenames |
| `--webcam` | Companion `*-cam.mp4` for editor PIP |
| `--highlight-clicks` | Click ripples (Accessibility) |

## How it works

```
ScreenCaptureKit (SCStream)
  ├─ screen frames  ──► AVAssetWriterInput (H.264)
  ├─ system audio   ──► AVAssetWriterInput (AAC)      [optional]
  └─ microphone     ──► AVAssetWriterInput (AAC)      [macOS 15+]
AVFoundation mic fallback ──► separate AAC track      [macOS 13–14]
                              └─► .mp4 on disk
```

- **No virtual audio drivers** (BlackHole / Loopback) for system sound
- On macOS 15+, microphone is captured natively by ScreenCaptureKit
- On macOS 13–14, microphone uses AVFoundation and is written as a separate audio track
- Video source pixel format is **NV12** (`420YpCbCr8BiPlanarVideoRange`), encoded with H.264 High profile

## Uninstall

```bash
make uninstall
# or: rm /usr/local/bin/screcord
```

## Troubleshooting

**No displays / empty device list**  
Screen Recording permission is missing for the *app that launched* `screcord` (usually your terminal). Grant it, relaunch the terminal, try again.

**Silent system audio**  
Confirm `--audio system` or `--audio both`, and that Screen **& System Audio** Recording is enabled (macOS Sequoia+ naming).

**Microphone permission prompt never appears**  
Rebuild/install with `make install` so `Info.plist` is embedded, then grant Microphone access to your terminal.

**Broken / unplayable file**  
Always stop with Ctrl+C (or `--duration`) so `AVAssetWriter` can finalize. Force-killing the process can leave a truncated container.

**Default `swift build` fails with XCBuild / property list errors**  
Use `make build` (passes `--build-system native`) or install full Xcode.

## Project layout

```
screcord/
├── Package.swift
├── Makefile
├── Resources/Info.plist
├── Scripts/install.sh
└── Sources/screcord/
    ├── ScrecordApp.swift      # entry + Ctrl+C handling
    ├── CLI.swift              # argument parsing
    ├── ScreenRecorder.swift   # ScreenCaptureKit + AVAssetWriter
    ├── DeviceLister.swift
    ├── Permissions.swift
    └── Types.swift
```

## Agent-native

This repo is set up for Cursor (and similar) agents:

| Path | Purpose |
|------|---------|
| [`AGENTS.md`](AGENTS.md) | Entrypoint for coding agents |
| [`.cursor/skills/screcord/`](.cursor/skills/screcord/) | Skill: record screens / pick displays |
| [`.cursor/skills/screcord-dev/`](.cursor/skills/screcord-dev/) | Skill: extend the Swift recorder |
| [`.cursor/rules/screcord.mdc`](.cursor/rules/screcord.mdc) | Always-on project conventions |
| [`Scripts/agent-record.sh`](Scripts/agent-record.sh) | Unattended recordings (`--duration` required) |

Example agent capture:

```bash
./Scripts/agent-record.sh --duration 15 --display 0 --audio system \
  --output ~/Desktop/agent-demo.mp4
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs welcome.

## License

[MIT](LICENSE) © 2026 Brandon Charleson
