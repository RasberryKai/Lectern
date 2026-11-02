#!/bin/sh
# Builds Lectern.app from the LecternApp SwiftPM target (release) for local use.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/.build/Lectern.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$ROOT_DIR"
swift build -c release --product LecternApp
BIN_DIR=$(swift build -c release --product LecternApp --show-bin-path)
EXECUTABLE="$BIN_DIR/LecternApp"
if [ ! -x "$EXECUTABLE" ]; then
  printf 'Missing app binary in %s\n' "$BIN_DIR" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$EXECUTABLE" "$CONTENTS_DIR/MacOS/LecternApp"
cp "$ROOT_DIR/Assets/Brand/Lectern.icns" "$CONTENTS_DIR/Resources/Lectern.icns"
# SwiftPM resource bundles (MathJax, bundled card rules). SwiftPM's generated Bundle.module
# accessor for executables looks next to Bundle.main.bundleURL, i.e. the .app root.
for bundle in "$BIN_DIR"/Lectern_*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP_DIR/"
done

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LecternApp</string>
  <key>CFBundleIdentifier</key><string>com.lectern.mac</string>
  <key>CFBundleName</key><string>Lectern</string>
  <key>CFBundleDisplayName</key><string>Lectern</string>
  <key>CFBundleIconFile</key><string>Lectern</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'Created %s\n' "$APP_DIR"
