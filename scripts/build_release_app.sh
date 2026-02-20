#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="KiruCut"
BUILD_DIR="$ROOT_DIR/.build"
RELEASE_DIR="$BUILD_DIR/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BIN_DIR="$RESOURCES_DIR/bin"

find_installed_tool() {
    local name="$1"
    local candidate

    for candidate in \
        "/opt/homebrew/bin/$name" \
        "/usr/local/bin/$name" \
        "/usr/bin/$name"
    do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi

    return 1
}

swift build -c release --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BIN_DIR"
cp "$RELEASE_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

FFMPEG_PATH="$(find_installed_tool ffmpeg || true)"
FFPROBE_PATH="$(find_installed_tool ffprobe || true)"

if [[ -z "$FFMPEG_PATH" || -z "$FFPROBE_PATH" ]]; then
    echo "Error: ffmpeg and ffprobe must be installed before building the release app bundle."
    echo "Install them with: brew install ffmpeg"
    exit 1
fi

cp "$FFMPEG_PATH" "$BIN_DIR/ffmpeg"
cp "$FFPROBE_PATH" "$BIN_DIR/ffprobe"
chmod +x "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Created: $APP_DIR"
