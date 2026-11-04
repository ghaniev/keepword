#!/bin/sh
# Builds Keepword.app. Info.plist carries the mic + system-audio usage strings,
# without which macOS refuses the process tap.
# SIGN_IDENTITY="Developer ID Application: …" signs with hardened runtime for distribution (see release.sh);
# by default the app is ad-hoc signed for local use.
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
swift build -c release
APP=Keepword.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetNotes "$APP/Contents/MacOS/"
# llama.cpp ships as a framework; bundle it and point the binary at Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
cp -R .build/release/llama.framework "$APP/Contents/Frameworks/"
# Swift 6.2 links libswiftCompatibilitySpan: macOS 26 has it in /usr/lib/swift (searched first),
# macOS 15 falls back to the copy bundled in Frameworks.
install_name_tool -add_rpath "/usr/lib/swift" "$APP/Contents/MacOS/MeetNotes"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MeetNotes"
cp "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib" \
  "$APP/Contents/Frameworks/"
# Translations (ru.lproj): UI strings, plurals and permission prompts. English is the source language.
mkdir -p "$APP/Contents/Resources" && cp -R Resources/*.lproj "$APP/Contents/Resources/"
# App icon: Resources/assets/meetnote_icn.webp → AppIcon.icns (all sizes macOS asks for).
ICONSET="$(mktemp -d)/AppIcon.iconset" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -s format png -z $s $s Resources/assets/meetnote_icn.webp --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -s format png -z $((s * 2)) $((s * 2)) Resources/assets/meetnote_icn.webp --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.anizh.meetnotes</string>
  <key>CFBundleName</key><string>Keepword</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MeetNotes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Keepword Deep Link</string>
    <key>CFBundleURLSchemes</key><array><string>meetnotes</string></array></dict></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Keepword records your microphone to transcribe your side of the call.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Keepword records your Mac's audio output so other people on the call appear in the transcript. Everything stays on this Mac.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Keepword shows your upcoming meetings and offers to record calls when they start.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Keepword sends your action items to the Reminders app.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Keepword captures screenshots during calls when you press the screenshot button.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Keepword talks to a local AI server (Ollama / LM Studio).</string>
</dict></plist>
PLIST
# macOS ties privacy permissions (microphone, screen) to the signature. With the ad-hoc one, after a rebuild
# re-enable Keepword in System Settings → Privacy & Security → Microphone if the mic records silence.
# Dependency resource bundles (FluidAudio TTS lexicon, swift-transformers fallback tokenizer configs) aren't
# bundled: the app never reaches them, and SwiftPM looks for them in the .app root, which codesign rejects.
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP/Contents/Frameworks/llama.framework" "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
  codesign --force --sign - "$APP"
else
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$APP/Contents/Frameworks/llama.framework" "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
  codesign --force --timestamp --options runtime --entitlements Resources/MeetNotes.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --deep "$APP"
fi
echo "Built $(pwd)/$APP"
