# screcord CLI reference (v1.2)

## Commands

`devices` · `windows` · `identify [--seconds 3]` · `record` · `help` · `version`

## Presets

`tutorial` · `broll` · `clean-ui` · `motion`

## Key flags

| Flag | Notes |
|------|-------|
| `--display <n\|name\|main>` | Prefer name/main over raw index |
| `--window <title>` / `--app <name>` | Single window/app |
| `--audio none\|system\|mic\|both` | |
| `--meters` / `--no-meters` / `--headless` | Loudness UI |
| `--idle-stop <sec>` | Stop after silence |
| `--slug <name>` | Timestamped Desktop filename tag |
| `--webcam` | Companion `*-cam.mp4` |
| `--highlight-clicks` | Click ripples |
| `--exclude-self` / `--include-self` | Filter terminal from capture |
| `--duration` / `--countdown` / `--fps` / `--bitrate` | |

## Output

- Screen: H.264 + AAC `.mp4`
- Markers: `*.chapters.json`
- Webcam companion: `*-cam.mp4`
