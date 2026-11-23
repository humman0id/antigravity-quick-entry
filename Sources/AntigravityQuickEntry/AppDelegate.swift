import AppKit
import QuickEntryCore
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var appState: AppState!
    private var quickEntryPanel: QuickEntryPanel!
    private var settingsWindow: NSWindow?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        appState = AppState()

        let composerRoot = AnyView(ComposerView(state: appState))
        quickEntryPanel = QuickEntryPanel(rootView: composerRoot)
        quickEntryPanel.onEscapePressed = { [weak self] in
            self?.appState.dismissQuickEntry()
        }

        appState.onShowPanel = { [weak self] in
            guard let self else { return }
            self.quickEntryPanel.showBottomCenterOnActiveScreen(expanded: self.appState.isHUDExpanded)
        }
        appState.onHidePanel = { [weak self] in
            self?.quickEntryPanel.orderOut(nil)
        }
        appState.onResizePanel = { [weak self] expanded in
            self?.quickEntryPanel.updateHeight(expanded: expanded)
        }

        setupMenuBarItem()

        if !EventTapMonitor.isAccessibilityGranted(prompt: true) {
            // Accessibility prompt shown once; user can also re-check from menu bar or Settings.
        } else {
            _ = appState.hotkeyMonitor.start()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appState?.shutdown()
    }

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "✦"
            button.toolTip = "Antigravity Quick Entry (Double-tap ⌥)"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    public func menuWillOpen(_ menu: NSMenu) {
        appState.refreshPermissions()
        menu.removeAllItems()

        let openItem = NSMenuItem(
            title: "Open Quick Entry (\(appState.settings.shortcutMode == .doubleOption ? "⌥ ⌥" : "⌥ Space"))",
            action: #selector(handleOpenQuickEntry),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let acpStatusItem = NSMenuItem(
            title: "Antigravity: \(appState.acpClient.connectionState.label)",
            action: nil,
            keyEquivalent: ""
        )
        acpStatusItem.isEnabled = false
        menu.addItem(acpStatusItem)

        let axTitle = appState.accessibilityGranted
            ? "Accessibility: Granted ✓"
            : "Accessibility: Missing (Click to open Settings)"
        let axItem = NSMenuItem(
            title: axTitle,
            action: appState.accessibilityGranted ? nil : #selector(handleOpenAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self
        menu.addItem(axItem)

        let srTitle = appState.screenRecordingGranted
            ? "Screen Recording: Granted ✓"
            : "Screen Recording: Missing (Click to open Settings)"
        let srItem = NSMenuItem(
            title: srTitle,
            action: appState.screenRecordingGranted ? nil : #selector(handleOpenScreenRecording),
            keyEquivalent: ""
        )
        srItem.target = self
        menu.addItem(srItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings & Files…", action: #selector(handleOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let revealItem = NSMenuItem(title: "Reveal App Support Folder", action: #selector(handleRevealSupportFolder), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Antigravity Quick Entry", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleOpenQuickEntry() {
        appState.summonQuickEntry(withCaptureOverlay: true)
    }

    @objc private func handleOpenAccessibility() {
        EventTapMonitor.openAccessibilitySettings()
    }

    @objc private func handleOpenScreenRecording() {
        CaptureOverlayController.openScreenRecordingSettings()
    }

    @objc private func handleOpenSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: appState))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Antigravity Quick Entry Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleRevealSupportFolder() {
        try? AppPaths.ensureDirectoriesExist()
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.appSupportDirectory])
    }

    @objc private func handleQuit() {
        appState.shutdown()
        NSApp.terminate(nil)
    }
}
