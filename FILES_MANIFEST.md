# Files & Runtime Footprint Manifest

This file tracks **every file in this repository** and **every path created on macOS at runtime** so you always know exactly what is on disk and can clean up cleanly in one command.

---

## 1. Source Code (Lives Only Inside This Git Repo)

Default location: `~/Projects/antigravity-quick-entry/`

| Path | Role |
| --- | --- |
| `Package.swift` | Swift Package manifest (`QuickEntryCore`, `AntigravityQuickEntry`, `QuickEntryCoreTests`) |
| `Sources/QuickEntryCore/AppPaths.swift` | Single source of truth for all runtime file paths, `AppSettings`, and `CaptureMetadata` |
| `Sources/QuickEntryCore/DoubleOptionDetector.swift` | Pure deterministic double-tap Option (`⌥ ⌥`) state machine |
| `Sources/QuickEntryCore/CoordinateGeometry.swift` | AppKit ↔ Quartz multi-display coordinate conversion & image long-edge capping |
| `Sources/AntigravityQuickEntry/main.swift` | Menu-bar-only (`NSApplication.ActivationPolicy.accessory`) entry point |
| `Sources/AntigravityQuickEntry/AppDelegate.swift` | macOS menu bar `NSStatusItem` (`✦`), live status/permission menu, Settings window |
| `Sources/AntigravityQuickEntry/AppState.swift` | Central `@MainActor` coordinator between hotkey, capture overlay, and Desktop handoff |
| `Sources/AntigravityQuickEntry/Hotkey/EventTapMonitor.swift` | Passive `CGEventTap` listener for `⌥ ⌥` and optional `⌥ Space` |
| `Sources/AntigravityQuickEntry/Capture/CaptureOverlayController.swift` | Multi-display `ScreenCaptureKit` drag-region capture overlay (border-free, no window tint) |
| `Sources/AntigravityQuickEntry/Desktop/DesktopAppHandoff.swift` | Direct Antigravity Desktop App handoff (clipboard + `⌘V`/`⌘N`/`↵`) |
| `Sources/AntigravityQuickEntry/Desktop/LaunchAgentManager.swift` | Optional macOS LaunchAgent installer/uninstaller for quiet login auto-start |
| `Sources/AntigravityQuickEntry/UI/QuickEntryPanel.swift` | Floating non-activating `NSPanel` (`.canJoinAllSpaces`, `.fullScreenAuxiliary`) |
| `Sources/AntigravityQuickEntry/UI/ComposerView.swift` | SwiftUI floating composer pill + Desktop target picker |
| `Sources/AntigravityQuickEntry/UI/SettingsView.swift` | Preferences, activation/auto-start toggles, permissions, and live "Files & Cleanup" inspector |
| `Tests/QuickEntryCoreTests/*.swift` | Automated `XCTest` unit tests (`swift test`) |
| `plugin/` | Optional companion Antigravity MCP plugin (`get_latest_screenshot`) + Node.js tests |
| `scripts/bundle-app.sh` | Builds release `.app` bundle on macOS (`--install`, `--autostart`) |
| `scripts/uninstall.sh` | Safe cleanup script (`--dry-run` by default, `--confirm` removes all runtime files + LaunchAgent) |

---

## 2. Runtime Files Created on Your Mac (Outside This Repo)

Nothing outside this repository is touched unless you build/run the app on macOS. When run on macOS, it **only** writes to:

| Path on macOS | Created When | Purpose | Removed by `uninstall.sh --confirm`? |
| --- | --- | --- | --- |
| `/Applications/AntigravityQuickEntry.app` | Running `./scripts/bundle-app.sh --install` | Installed macOS menu-bar app bundle | ✅ Yes |
| `~/Library/LaunchAgents/com.antigravity.quickentry.plist` | Enabling login auto-start (`--autostart` or Settings toggle) | Starts app quietly at login so it wakes whenever Antigravity runs | ✅ Yes (unloaded & deleted) |
| `~/Library/Application Support/AntigravityQuickEntry/` | First launch / saving settings | `settings.json` | ✅ Yes |
| `~/Library/Caches/AntigravityQuickEntry/` | Taking a screenshot | `latest.png` + `latest.json` (overwritten on each capture) | ✅ Yes |
| `~/Library/Preferences/com.antigravity.quickentry.plist` | macOS window/defaults state | Standard macOS AppKit preferences plist | ✅ Yes |
| `~/.antigravity/plugins/quick-capture/` | Only if you install the optional plugin | Companion MCP server (`get_latest_screenshot`) | ✅ Yes |

> **Never modified by this app:** Your `~/.gemini/` Antigravity credentials, `~/.local/bin/agy`, and existing Antigravity Desktop App / IDE files are **never** altered or deleted by this app or by `uninstall.sh`.

---

## 3. Clean-Up / Rollback Commands

Preview everything that would be removed (safe dry-run):
```bash
./scripts/uninstall.sh
```

Remove the installed app, settings, caches, and optional plugin:
```bash
./scripts/uninstall.sh --confirm
```

Also reset macOS Accessibility & Screen Recording permissions for this bundle ID:
```bash
./scripts/uninstall.sh --confirm --reset-permissions
```

Finally, if you also want to delete the source code itself:
```bash
rm -rf ~/Projects/antigravity-quick-entry
```
