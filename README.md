# KiruCut (macOS SwiftUI)

Simple native macOS app that runs an `ffmpeg` stream-copy trim:

`ffmpeg -ss <start> -i <input> -c copy -map 0 -t <duration> <output>`

Cuts are lossless stream-copy trims. The app computes `duration` as `endTime - startTime`.
KiruCut also shows a predicted cut range before running, based on `ffprobe` packet timing.

## Requirements

- macOS 15 (Sequoia)
- Xcode 16 (Swift 6 toolchain)
- `ffmpeg` available in `PATH` (example: `brew install ffmpeg`)
  - App also checks common install paths directly, including `/opt/homebrew/bin/ffmpeg`.

## Build

From project root:

```bash
swift build
```

Release `.app` bundle:

```bash
./scripts/build_release_app.sh
```

Output:

- `dist/KiruCut.app`

## Run

- Double-click `dist/KiruCut.app`, or
- Launch from terminal:

```bash
open dist/KiruCut.app
```

## Usage

1. Select input video.
2. Select output path.
3. Set start time and end time (`seconds` or `mm:ss`).
4. Click **Cut Video**.

Notes:

- If end time is longer than the file, KiruCut resets it to the video end.
- If output exists, KiruCut asks before replacing it.
- Prediction is approximate and container-dependent; actual output timing can differ by a few frames.
- Status text shows success/error details.
