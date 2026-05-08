#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/V2SDebug.app"
BUILD_DIR="$ROOT_DIR/.build/arm64-apple-macosx/debug"

cd "$ROOT_DIR"
swift build

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>v2s</string>
    <key>CFBundleIdentifier</key>
    <string>com.franklioxygen.v2s.debug</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>v2s Debug</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.28-debug</string>
    <key>CFBundleVersion</key>
    <string>32</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>v2s captures audio from other apps to generate live subtitles.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>v2s uses the microphone to generate subtitles from live speech.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>v2s uses speech recognition to transcribe audio into subtitles.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>v2s captures the current screen only when you ask GPT to use the visible context.</string>
</dict>
</plist>
PLIST

ditto "$BUILD_DIR/v2s" "$APP_DIR/Contents/MacOS/v2s"
ditto "$BUILD_DIR/Sparkle.framework" "$APP_DIR/Contents/MacOS/Sparkle.framework"
ditto "$BUILD_DIR/v2s_v2s.bundle" "$APP_DIR/Contents/Resources/v2s_v2s.bundle"

codesign --force --deep --sign - "$APP_DIR"
pkill -f "$APP_DIR/Contents/MacOS/v2s" 2>/dev/null || true
open "$APP_DIR"
