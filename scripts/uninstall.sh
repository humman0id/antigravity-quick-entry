#!/usr/bin/env bash
set -euo pipefail

# Cleanly removes every runtime artifact created by Antigravity Quick Entry on macOS.
# Defaults to --dry-run so nothing is deleted accidentally.
#
# Usage:
#   ./scripts/uninstall.sh                                # preview all tracked paths
#   ./scripts/uninstall.sh --confirm                      # remove app, settings, cache, optional plugin
#   ./scripts/uninstall.sh --confirm --reset-permissions  # also reset macOS TCC Accessibility/ScreenCapture

APP_NAME="AntigravityQuickEntry"
BUNDLE_ID="com.antigravity.quickentry"
CONFIRM=false
RESET_PERMS=false

for arg in "$@"; do
  case "$arg" in
    --confirm) CONFIRM=true ;;
    --reset-permissions) RESET_PERMS=true ;;
    --dry-run) CONFIRM=false ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--dry-run] [--confirm] [--reset-permissions]" >&2
      exit 1
      ;;
  esac
done

LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"

PATHS=(
  "/Applications/${APP_NAME}.app"
  "${LAUNCH_AGENT}"
  "${HOME}/Library/Application Support/${APP_NAME}"
  "${HOME}/Library/Caches/${APP_NAME}"
  "${HOME}/Library/Preferences/${BUNDLE_ID}.plist"
  "${HOME}/.antigravity/plugins/quick-capture"
)

echo "============================================================"
echo " Antigravity Quick Entry — Cleanup Manifest"
echo " Mode: $( [[ "$CONFIRM" == "true" ]] && echo "DELETE (--confirm)" || echo "DRY RUN (preview only)" )"
echo "============================================================"

for p in "${PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    echo " [EXISTS]  $p"
  else
    echo " [absent]  $p"
  fi
done

echo ""
if [[ "$CONFIRM" != "true" ]]; then
  echo "No files were deleted. Re-run with --confirm to remove the existing paths above."
  echo "Your source code repository ($(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)) is NEVER deleted by this script."
  exit 0
fi

if [[ -e "$LAUNCH_AGENT" && "$(uname -s)" == "Darwin" ]]; then
  echo "==> Unloading LaunchAgent..."
  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || true
fi

echo "==> Stopping any running ${APP_NAME} process..."
pkill -x "$APP_NAME" 2>/dev/null || true

for p in "${PATHS[@]}"; do
  if [[ -e "$p" ]]; then
    echo "==> Removing: $p"
    rm -rf "$p"
  fi
done

if [[ "$RESET_PERMS" == "true" && "$(uname -s)" == "Darwin" ]]; then
  echo "==> Resetting macOS TCC permissions for ${BUNDLE_ID}..."
  tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
  tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
fi

echo "==> Cleanup complete! (Your git repository was left untouched.)"
