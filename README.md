# Antigravity Quick Entry (macOS MVP)

A lightweight native macOS menu-bar app that brings Claude Desktop's **Quick Entry** workflow (`⌥ ⌥` + instant drag/window screenshot capture + floating prompt HUD) to **Google Antigravity** via its official Agent Client Protocol server (`agy acp`).

## Prerequisites (on your Mac)

- **macOS 14.0+** (Sonoma or newer, for `SCScreenshotManager`)
- **Xcode Command Line Tools** (`xcode-select --install`, Swift 5.9+)
- **Google Antigravity CLI (`agy` v1.5.5+)** installed and signed in (`agy`)

## Quick Start on macOS

### 1. Run Unit Tests
```bash
cd ~/Projects/antigravity-quick-entry
swift test
node --test plugin/mcp-server/test.mjs
```

### 2. Build & Launch the Menu-Bar App
```bash
./scripts/bundle-app.sh
open dist/AntigravityQuickEntry.app
```
Or install directly into `/Applications`:
```bash
./scripts/bundle-app.sh --install
open /Applications/AntigravityQuickEntry.app
```

### 3. Grant macOS Permissions
Click the **`✦`** icon in your macOS menu bar (or open **Settings & Files…**):
1. **Accessibility** — required for passive `CGEventTap` global `⌥ ⌥` detection.
2. **Screen Recording** — required for `ScreenCaptureKit` region/window capture.

### 4. Use It
- **Double-tap `Option` (`⌥ ⌥`)** from any app or full-screen Space.
- **Click any window** or **drag a rectangle** to attach a screenshot (or start typing immediately to skip capture).
- Pick your project workspace (`cwd`) and hit **Enter** — Antigravity streams its reply right inside the floating HUD and asks for approval inline before editing files or running commands.
- Press **`Esc`** anytime to cancel/dismiss.

## Optional: Companion Antigravity Plugin (`get_latest_screenshot`)

If you also want existing Antigravity Desktop App / IDE / CLI chats to pull your latest Quick Entry screenshot on demand:
```bash
agy plugin install ~/Projects/antigravity-quick-entry/plugin
```

## Tracking & Full Clean-Up

Every single file in this repo and every path touched on macOS is documented in [`FILES_MANIFEST.md`](./FILES_MANIFEST.md).

To preview and cleanly remove all runtime files at any time:
```bash
./scripts/uninstall.sh                # dry-run preview
./scripts/uninstall.sh --confirm      # removes app, settings, cache, optional plugin
./scripts/uninstall.sh --confirm --reset-permissions
```
