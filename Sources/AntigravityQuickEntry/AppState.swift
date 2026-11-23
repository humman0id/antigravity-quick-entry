import AppKit
import Combine
import Foundation
import QuickEntryCore

/// Central observable state shared between the menu bar, floating composer, capture overlay, and Settings.
@MainActor
public final class AppState: ObservableObject {
    @Published public var settings: AppSettings
    @Published public var promptText: String = ""
    @Published public var attachedCapture: CapturedAttachment?
    @Published public var isPanelVisible: Bool = false
    @Published public var isCaptureOverlayActive: Bool = false
    @Published public var captureError: String?
    @Published public var handoffError: String?
    @Published public var accessibilityGranted: Bool = false
    @Published public var screenRecordingGranted: Bool = false
    @Published public var openDesktopWindows: [DetectedDesktopWindow] = []
    @Published public var selectedDesktopWindowPID: pid_t?
    @Published public private(set) var isAntigravityRunning: Bool = false
    @Published public private(set) var isAntigravityFrontmost: Bool = false
    @Published public var launchAtLoginEnabled: Bool = false

    public let captureController = CaptureOverlayController()
    public let hotkeyMonitor = EventTapMonitor()

    public var onShowPanel: (() -> Void)?
    public var onHidePanel: (() -> Void)?
    public var onActivationStateChanged: ((Bool) -> Void)?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var menuObservers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?
    private var accessibilityPollTask: Task<Void, Never>?
    private var isTrackingMenu: Bool = false
    private var lastPanelShownUptime: TimeInterval = 0

    /// Whether the global shortcut (`⌥ ⌥`) should currently be armed.
    public var isQuickEntryActive: Bool {
        !settings.onlyActiveWhenAntigravityRunning || isAntigravityRunning
    }

    public init() {
        self.settings = AppSettings.load()
        self.launchAtLoginEnabled = LaunchAgentManager.isInstalled
        try? AppPaths.ensureDirectoriesExist()

        configureCallbacks()
        observeWorkspaceLifecycle()
        observeMenuTracking()
        refreshPermissions()
        applySettings()
    }

    private func configureCallbacks() {
        hotkeyMonitor.onTrigger = { [weak self] in
            self?.toggleQuickEntry()
        }

        captureController.onCaptureCompleted = { [weak self] attachment in
            guard let self, self.isPanelVisible else { return }
            self.captureError = nil
            self.attachedCapture = attachment
            self.lastPanelShownUptime = ProcessInfo.processInfo.systemUptime
            self.onShowPanel?()

            // Keep the transparent capture overlay silently armed after capturing so
            // dragging again immediately retakes the screenshot without exiting Quick Entry,
            // while a single click outside (without dragging) still dismisses Quick Entry.
            if self.screenRecordingGranted {
                self.isCaptureOverlayActive = true
                self.captureController.beginCapture(
                    maxLongEdgePx: self.settings.maxImageLongEdgePx,
                    showHintPill: false
                )
            } else {
                self.isCaptureOverlayActive = false
            }
        }

        captureController.onCaptureCancelled = { [weak self] in
            self?.isCaptureOverlayActive = false
        }

        captureController.onClickOutside = { [weak self] in
            self?.isCaptureOverlayActive = false
            self?.dismissQuickEntry()
        }

        captureController.onCaptureError = { [weak self] errorMsg in
            self?.isCaptureOverlayActive = false
            self?.captureError = errorMsg
        }
    }

    private func observeWorkspaceLifecycle() {
        let nc = NSWorkspace.shared.notificationCenter
        let onLaunch = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncActivationState()
            }
        }
        let onTerminate = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncActivationState()
            }
        }
        let onActivate = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activatedApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedPID = activatedApp?.processIdentifier
            let ownPID = ProcessInfo.processInfo.processIdentifier
            Task { @MainActor in
                self?.isAntigravityFrontmost = DesktopAppHandoff.isAntigravityFrontmost()
                if activatedPID != ownPID {
                    self?.handlePanelUnfocused()
                }
            }
        }
        workspaceObservers = [onLaunch, onTerminate, onActivate]
    }

    private func observeMenuTracking() {
        let nc = NotificationCenter.default
        let onBegin = nc.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isTrackingMenu = true
            }
        }
        let onEnd = nc.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.isTrackingMenu = false
            }
        }
        menuObservers = [onBegin, onEnd]
    }

    public func refreshPermissions() {
        accessibilityGranted = EventTapMonitor.isAccessibilityGranted(prompt: false)
        screenRecordingGranted = CaptureOverlayController.isScreenRecordingGranted()
        syncActivationState()
        updateAccessibilityWatcher()
    }

    /// Quietly polls Accessibility trust while ungranted so `⌥ ⌥` arms immediately
    /// after toggling the switch in System Settings without needing a manual re-check.
    private func updateAccessibilityWatcher() {
        if accessibilityGranted {
            accessibilityPollTask?.cancel()
            accessibilityPollTask = nil
            return
        }
        guard accessibilityPollTask == nil else { return }
        accessibilityPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { break }
                if EventTapMonitor.isAccessibilityGranted(prompt: false) {
                    self.refreshPermissions()
                    break
                }
            }
        }
    }

    public func refreshOpenDesktopWindows() {
        isAntigravityFrontmost = DesktopAppHandoff.isAntigravityFrontmost()
        openDesktopWindows = DesktopAppHandoff.listOpenDesktopWindows()
        if let pid = selectedDesktopWindowPID,
           !openDesktopWindows.contains(where: { $0.pid == pid }) {
            selectedDesktopWindowPID = nil
        }
    }

    /// Arms the global hotkey only when Antigravity is running (unless the user disables that gating).
    public func syncActivationState() {
        isAntigravityRunning = !DesktopAppHandoff.findRunningAntigravityApps().isEmpty
        refreshOpenDesktopWindows()

        let active = isQuickEntryActive
        if active && accessibilityGranted {
            _ = hotkeyMonitor.start()
        } else {
            hotkeyMonitor.stop()
            if !active && isPanelVisible {
                dismissQuickEntry()
            }
        }
        onActivationStateChanged?(active)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try LaunchAgentManager.install()
            } else {
                try LaunchAgentManager.uninstall()
            }
            launchAtLoginEnabled = LaunchAgentManager.isInstalled
        } catch {
            launchAtLoginEnabled = LaunchAgentManager.isInstalled
        }
    }

    public func applySettings() {
        hotkeyMonitor.updateSettings(settings)
        try? settings.save()
        syncActivationState()
    }

    public func toggleQuickEntry() {
        if isPanelVisible {
            dismissQuickEntry()
        } else {
            summonQuickEntry(withCaptureOverlay: true)
        }
    }

    public func summonQuickEntry(withCaptureOverlay: Bool) {
        refreshPermissions()
        refreshOpenDesktopWindows()
        captureError = nil
        handoffError = nil
        isPanelVisible = true
        lastPanelShownUptime = ProcessInfo.processInfo.systemUptime
        installOutsideClickMonitor()
        onShowPanel?()

        if withCaptureOverlay && screenRecordingGranted {
            isCaptureOverlayActive = true
            captureController.beginCapture(maxLongEdgePx: settings.maxImageLongEdgePx)
        }
    }

    /// Closes Quick Entry when the user clicks away or switches apps (`⌘Tab`),
    /// while preserving the panel during active drag-to-screenshot capture, dropdown menus, or modal dialogs.
    public func handlePanelUnfocused(bypassGracePeriod: Bool = false) {
        guard isPanelVisible else { return }
        guard !captureController.isActivelyCapturing else { return }
        guard !isTrackingMenu && NSApp.modalWindow == nil else { return }
        if !bypassGracePeriod {
            guard ProcessInfo.processInfo.systemUptime - lastPanelShownUptime >= 0.18 else { return }
        }
        dismissQuickEntry()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // Global monitors only receive mouse-down events delivered to OTHER applications,
        // so clicks inside QuickEntryPanel or CaptureOverlayWindow never trigger this.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.handlePanelUnfocused(bypassGracePeriod: true)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    public func startRecapture() {
        refreshPermissions()
        captureError = nil
        isCaptureOverlayActive = true
        captureController.beginCapture(maxLongEdgePx: settings.maxImageLongEdgePx)
    }

    /// Automatically dismisses the screenshot overlay if the user starts typing a text-only prompt.
    public func handleUserStartedTyping() {
        if isCaptureOverlayActive {
            isCaptureOverlayActive = false
            captureController.dismiss()
        }
    }

    public func dismissQuickEntry() {
        removeOutsideClickMonitor()
        if isCaptureOverlayActive {
            isCaptureOverlayActive = false
            captureController.dismiss()
        }
        isPanelVisible = false
        onHidePanel?()
    }

    public func selectDeliveryTarget(_ target: DeliveryTarget, desktopPID: pid_t? = nil) {
        settings.deliveryTarget = target
        selectedDesktopWindowPID = desktopPID
        handoffError = nil
        applySettings()
    }

    public func submitPrompt() {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachedCapture != nil else { return }

        if isCaptureOverlayActive {
            isCaptureOverlayActive = false
            captureController.dismiss()
        }

        handoffError = nil

        let textToSend = trimmed
        let captureToSend = attachedCapture
        let startNew = (settings.deliveryTarget == .desktopNewChat)
        let autoSubmit = settings.autoSubmitDesktopHandoff
        let targetPID = selectedDesktopWindowPID

        // Clear and hide Quick Entry so Antigravity Desktop App receives clean focus
        promptText = ""
        attachedCapture = nil
        isPanelVisible = false
        removeOutsideClickMonitor()
        onHidePanel?()

        Task {
            if let err = await DesktopAppHandoff.handoff(
                promptText: textToSend,
                attachment: captureToSend,
                preferredPID: targetPID,
                startNewChat: startNew,
                autoSubmit: autoSubmit
            ) {
                self.handoffError = err
                self.promptText = textToSend
                self.attachedCapture = captureToSend
                self.isPanelVisible = true
                self.lastPanelShownUptime = ProcessInfo.processInfo.systemUptime
                self.installOutsideClickMonitor()
                self.onShowPanel?()
            }
        }
    }

    public func shutdown() {
        removeOutsideClickMonitor()
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in menuObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        menuObservers.removeAll()
        captureController.dismiss()
        hotkeyMonitor.stop()
    }
}
