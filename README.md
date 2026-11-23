# Antigravity Quick Entry (macOS MVP)

A lightweight native macOS menu-bar app that brings Claude Desktop's **Quick Entry** workflow (`⌥ ⌥` + instant drag-region screenshot capture + floating prompt bar) to **Google Antigravity Desktop App**.

## Highlights

- **Automatically active while Antigravity is running:** Watches macOS app launch/quit events so `⌥ ⌥` arms itself when Antigravity Desktop App opens and sleeps automatically when you quit Antigravity.
- **Direct Desktop App handoff:** Sends your screenshot and prompt directly into Antigravity Desktop App (**Current Chat**, **New Chat `⌘N`**, or a chosen open window).
- **Clean drag-region capture:** No full-screen blue window tint and border-free PNG captures across any Space or full-screen app.

## Prerequisites (on your Mac)

- **macOS 14.0+** (Sonoma or newer)
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Google Antigravity Desktop App**

## Fresh Setup on macOS

### 1. Build & Install (with Optional Login Auto-Start)
```bash
cd ~/Projects/antigravity-quick-entry

# Recommended: installs into /Applications AND starts quietly at login
# so it wakes up automatically whenever Antigravity is open:
./scripts/bundle-app.sh --install --autostart
open /Applications/AntigravityQuickEntry.app
```
*(Or build locally without installing to `/Applications`: `./scripts/bundle-app.sh && open dist/AntigravityQuickEntry.app`)*

### 2. Grant macOS Permissions
Click the **`✦`** icon in your macOS menu bar → **Settings & Files…**:
1. **Accessibility** — required for passive `CGEventTap` global `⌥ ⌥` detection and Desktop App handoff.
2. **Screen Recording** — required for `ScreenCaptureKit` drag-region capture.

### 3. Use It
- Make sure **Antigravity Desktop App** is running (`✦` turns bright when active, dims when sleeping).
- **Double-tap `Option` (`⌥ ⌥`)** from any app or full-screen Space.
- **Drag a rectangle** to attach a screenshot (or start typing immediately to skip capture).
- Use the target picker to send to **Desktop · Current Chat** or **Desktop · New Chat (`⌘N`)**, then press **Enter**.
- Press **`Esc`** (or right-click during drag) anytime to cancel/dismiss.

## Tracking & Full Clean-Up

Every single file in this repo and every path touched on macOS is documented in [`FILES_MANIFEST.md`](./FILES_MANIFEST.md).

To preview and cleanly wipe all runtime files, LaunchAgent, and macOS TCC permissions:
```bash
./scripts/uninstall.sh                                # dry-run preview
./scripts/uninstall.sh --confirm --reset-permissions  # full clean uninstall
```
