# Contributing to screcord

Thanks for helping improve a small, reliable macOS screen recorder.

## Development

Requirements:

- macOS 13+
- Xcode or Command Line Tools with Swift 5.9+
- Apple Silicon or Intel (Apple Silicon recommended)

```bash
git clone https://github.com/bcharleson/screcord.git
cd screcord
make debug
.build/debug/screcord devices
```

## Guidelines

- Keep the CLI dependency-free (Swift + Apple frameworks only).
- Prefer ScreenCaptureKit + AVFoundation over third-party capture stacks.
- Keep source files focused and under ~300 lines when practical.
- Do not commit recordings (`.mp4`, `.mov`) or local build artifacts.
- Test on Apple Silicon when changing capture/audio paths.

## Pull requests

1. Fork and create a feature branch.
2. Make a focused change with a clear rationale.
3. Update `README.md` if usage or permissions change.
4. Open a PR with a short summary of what and why.
