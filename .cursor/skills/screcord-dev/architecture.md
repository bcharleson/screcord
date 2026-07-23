# screcord architecture

## Capture pipeline

```
SCShareableContent → SCContentFilter(display)
       ↓
SCStreamConfiguration
  width/height (even), fps, showsCursor, sourceRect?
  capturesAudio, sampleRate 48k, channelCount 2
  captureMicrophone (macOS 15+)
       ↓
SCStream outputs on sampleQueue
  .screen  → video AVAssetWriterInput (H.264)
  .audio   → system AAC input
  .microphone → mic AAC input (15+)
AVCaptureSession mic → retimed → mic AAC input (<15)
       ↓
AVAssetWriter (.mp4) → Desktop / -o path
```

## Timing

- Writer `startSession` uses first **complete** video buffer PTS.
- SCK system/mic audio share the stream timeline on macOS 15+.
- Legacy AVCapture mic buffers are retimed relative to `sessionStartPTS` via a mic PTS anchor.

## Display ordering

`DisplayResolver.ordered` puts `CGMainDisplayID()` first so `--display 0` is predictable.

## Region capture

`--region x,y,w,h` sets `SCStreamConfiguration.sourceRect` in **points**; output size = region × `--scale`.

## Why not BlackHole / ffmpeg?

ScreenCaptureKit taps system audio under Screen Recording permission. Prefer extending SCK/AVFoundation before adding loopback drivers or ffmpeg wrappers.

## Known sharp edges

- Force-kill (`kill -9`) can truncate MP4s.
- Mixing system+mic into **one** writer input corrupts files when formats differ.
- Permission is granted to the **parent terminal/IDE**, not always to the binary itself.
- SwiftPM default build system may fail on Command Line Tools–only hosts; Makefile uses `--build-system native`.
