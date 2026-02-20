# Building KiruCut

## Prerequisites
- macOS with Xcode command line tools installed
- Swift toolchain available (`swift --version`)

## Debug Build
Run from the repository root:

```bash
swift build
```

This compiles the app in debug mode and writes artifacts under `.build/`.

## Release App Bundle (`dist/KiruCut.app`)
To produce a fresh macOS app bundle in `dist/`:

```bash
./scripts/build_release_app.sh
```

This runs a release build, then creates:

- `dist/KiruCut.app`

## Quick Verification
Check that the app bundle exists:

```bash
ls -la dist/KiruCut.app
```

## Tests
Run the test suite from the repository root:

```bash
swift test
```

Current test coverage (in `Tests/KiruCutAppTests/KiruCutAppTests.swift`):
- Input loading remains responsive even when preview compatibility detection is slow.
- Cutting is rejected when output path matches input path.
- Large subprocess output handling does not hang `runProcess`.
