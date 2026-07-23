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

- Full display or rectangular region capture
- Audio modes: `none` · `system` · `mic` · `both`
- Show / hide mouse cursor
- Countdown before recording
- Clean stop via **Ctrl+C** (or `--duration`)
- Defaults: **30 fps**, high bitrate H.264, NV12 → yuv420p-friendly encode, AAC 192 kbps
- Timestamped filenames on your Desktop
- List displays + microphones

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
# List displays and microphones
screcord devices

# Record full primary display (system + mic), countdown 3s
screcord record

# System audio only, no cursor
screcord record --audio system --no-cursor

# Microphone only, 5s countdown
screcord record --audio mic --countdown 5

# Region + 60 fps + custom output
screcord record --region 0,0,1280,720 --fps 60 -o ~/Movies/demo.mp4

# Second display, auto-stop after 30 seconds
screcord record --display 1 --duration 30

# Shorthand (record is the default when options are passed)
screcord --audio both --no-cursor
```

Stop an interactive recording with **Ctrl+C**. The file is finalized cleanly (no truncated MP4).

### Options

| Option | Default | Description |
|---|---|---|
| `-d, --display <n>` | `0` | Display index from `screcord devices` |
| `-r, --region x,y,w,h` | full display | Capture region in **points** |
| `-a, --audio <mode>` | `both` | `none` \| `system` \| `mic` \| `both` |
| `--no-cursor` / `--cursor` | cursor on | Hide or show the pointer |
| `--fps <n>` | `30` | 1–60 |
| `--bitrate <bps>` | `8000000` | Video bitrate |
| `--audio-bitrate <bps>` | `192000` | AAC bitrate |
| `-c, --countdown <sec>` | `3` | Pre-roll countdown |
| `-t, --duration <sec>` | off | Auto-stop after N seconds |
| `-o, --output <path>` | `~/Desktop/screcord-TIMESTAMP.mp4` | Output path |
| `--scale <1\|2\|3>` | `2` | Pixel scale (Retina-friendly) |

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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Issues and PRs welcome.

## License

[MIT](LICENSE) © 2026 Brandon Charleson
