#!/usr/bin/env bash
set -euo pipefail

# Builds AntigravityQuickEntry on macOS and packages it into a menu-bar `.app` bundle.
# Usage:
#   ./scripts/bundle-app.sh             # builds into ./dist/AntigravityQuickEntry.app
#   ./scripts/bundle-app.sh --install   # also copies to /Applications/AntigravityQuickEntry.app

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: bundle-app.sh must be run on macOS (detected $(uname -s))." >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AntigravityQuickEntry"
BUNDLE_ID="com.antigravity.quickentry"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
INSTALL_TO_APPS=false

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL_TO_APPS=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

echo "==> Building release Swift binary..."
cd "$REPO_ROOT"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: Built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "$BIN_PATH" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Antigravity Quick Entry</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Antigravity Quick Entry captures regions or windows you select so you can send visual context to Antigravity.</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc code signing bundle (helps macOS TCC remember permissions)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Built: ${APP_BUNDLE}"

if [[ "$INSTALL_TO_APPS" == "true" ]]; then
  TARGET="/Applications/${APP_NAME}.app"
  echo "==> Installing to ${TARGET}..."
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$TARGET"
  cp -R "$APP_BUNDLE" "$TARGET"
  echo "==> Installed! Launch with: open \"${TARGET}\""
else
  echo "==> Launch directly with: open \"${APP_BUNDLE}\""
  echo "    Or install to /Applications with: ./scripts/bundle-app.sh --install"
fi
