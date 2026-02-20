# KiruCut

kiru (切る) == to cut

Simple native macOS app that runs an `ffmpeg` stream-copy trim:

`ffmpeg -ss <start> -i <input> -c copy -map 0 -t <duration> <output>`

Cuts are lossless stream-copy trims. The app computes `duration` as `endTime - startTime`.
KiruCut also shows a predicted cut range before running, based on `ffprobe` packet timing.

This product bundles FFmpeg and FFprobe (LGPL build) in the app bundle by default.

## Requirements

- macOS 15 (Sequoia)
- Xcode 16 (Swift 6 toolchain)
- Apple Silicon Mac (`arm64`) for the provided release build output
- No system FFmpeg install is required for end users (the release app bundles tools).
- Optional: installed `ffmpeg` + `ffprobe` if you enable **Use installed ffmpeg** in Settings.

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

Note:

- The release build script copies installed `ffmpeg`/`ffprobe` into the app bundle (`Contents/Resources/bin`) for redistribution.

## Run

- Double-click `dist/KiruCut.app`, or
- Launch from terminal:

```bash
open dist/KiruCut.app
```

Gatekeeper note:

- This local build is not code-signed or notarized by default.
- You may need to bypass Gatekeeper (right-click app -> **Open**, or **System Settings > Privacy & Security > Open Anyway**).

## Usage

1. Select input video.
2. Select output path.
3. Set start time and end time (`seconds` or `mm:ss`).
4. Click **Cut Video**.

Notes:

- If end time is longer than the file, KiruCut resets it to the video end.
- If output exists, KiruCut asks before replacing it.
- Tools source can be switched in Settings:
  - Default: bundled `ffmpeg`/`ffprobe`
  - Optional: installed `ffmpeg`/`ffprobe` from your system
- Prediction is approximate and container-dependent; actual output timing can differ by a few frames.
- Status text shows success/error details.
