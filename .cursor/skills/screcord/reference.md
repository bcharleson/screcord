# screcord CLI reference

## Commands

| Command | Purpose |
|---------|---------|
| `screcord devices` | List displays + microphones |
| `screcord record [options]` | Start recording |
| `screcord [options]` | Shorthand for `record` |
| `screcord help` | Help |
| `screcord version` | Version string |

## Options

| Flag | Default | Notes |
|------|---------|-------|
| `-d, --display <n>` | `0` | Index from `devices` (main first) |
| `-r, --region x,y,w,h` | full display | Points, not pixels |
| `-a, --audio <mode>` | `both` | `none` \| `system` \| `mic` \| `both` |
| `--no-cursor` / `--cursor` | cursor on | Pointer visibility |
| `--fps <n>` | `30` | 1–60 |
| `--bitrate <bps>` | `8000000` | Video |
| `--audio-bitrate <bps>` | `192000` | AAC |
| `-c, --countdown <sec>` | `3` | Pre-roll |
| `-t, --duration <sec>` | off | Auto-stop |
| `-o, --output <path>` | Desktop timestamped | Must end usable as `.mp4` |
| `--scale <1\|2\|3>` | `2` | Retina scale; width capped ~3840 |

## Output format

- Container: MP4
- Video: H.264 High, NV12 source (`420YpCbCr8BiPlanarVideoRange`)
- Audio: AAC 48 kHz stereo (separate tracks for system vs mic when both enabled)
- System audio: ScreenCaptureKit (no BlackHole)
- Mic: ScreenCaptureKit on macOS 15+; AVFoundation fallback on 13–14

## Install / build

```bash
# from repo root
make build                 # .build/release/screcord
make install               # /usr/local/bin (may need sudo)
PREFIX="$HOME/.local" make install
./Scripts/install.sh
```

Requires macOS 13+. Apple Silicon recommended.
