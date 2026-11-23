import AppKit
import Combine
import Foundation
import QuickEntryCore

/// Central observable state shared between the menu bar, floating HUD, capture overlay, and Settings.
@MainActor
public final class AppState: ObservableObject {
    @Published public var settings: AppSettings
    @Published public var promptText: String = ""
    @Published public var attachedCapture: CapturedAttachment?
    @Published public var isHUDExpanded: Bool = false
    @Published public var isPanelVisible: Bool = false
    @Published public var isCaptureOverlayActive: Bool = false
    @Published public var captureError: String?
    @Published public var handoffError: String?
    @Published public var accessibilityGranted: Bool = false
    @Published public var screenRecordingGranted: Bool = false
    @Published public var lastSubmittedPrompt: String = ""
    @Published public var openDesktopWindows: [DetectedDesktopWindow] = []
    @Published public var selectedDesktopWindowPID: pid_t?
    @Published public private(set) var isAntigravityRunning: Bool = false
    @Published public var launchAtLoginEnabled: Bool = false

    public let acpClient = ACPProcessClient()
    public let captureController = CaptureOverlayController()
    public let hotkeyMonitor = EventTapMonitor()

    public var onShowPanel: (() -> Void)?
    public var onHidePanel: (() -> Void)?
    public var onResizePanel: ((Bool) -> Void)?
    public var onActivationStateChanged: ((Bool) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Whether the global shortcut (`⌥ ⌥`) should currently be armed.
    public var isQuickEntryActive: Bool {
        !settings.onlyActiveWhenAntigravityRunning || isAntigravityRunning
    }

    public init() {
        self.settings = AppSettings.load()
        self.launchAtLoginEnabled = LaunchAgentManager.isInstalled
        try? AppPaths.ensureDirectoriesExist()

        // Forward ACPClient updates to SwiftUI views observing AppState
        acpClient.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        configureCallbacks()
        observeWorkspaceLifecycle()
        refreshPermissions()
        applySettings()
    }

    private func configureCallbacks() {
        hotkeyMonitor.onTrigger = { [weak self] in
            self?.toggleQuickEntry()
        }

        captureController.onCaptureCompleted = { [weak self] attachment in
            guard let self else { return }
            self.isCaptureOverlayActive = false
            self.captureError = nil
            self.attachedCapture = attachment
            self.onShowPanel?()
        }

        captureController.onCaptureCancelled = { [weak self] in
            self?.isCaptureOverlayActive = false
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
        workspaceObservers = [onLaunch, onTerminate]
    }

    public func refreshPermissions() {
        accessibilityGranted = EventTapMonitor.isAccessibilityGranted(prompt: false)
        screenRecordingGranted = CaptureOverlayController.isScreenRecordingGranted()
        syncActivationState()
    }

    public func refreshOpenDesktopWindows() {
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
        acpClient.updateCustomBinaryPath(settings.customAgyPath)
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
        onShowPanel?()
        onResizePanel?(isHUDExpanded)

        if withCaptureOverlay && screenRecordingGranted {
            isCaptureOverlayActive = true
            captureController.beginCapture(maxLongEdgePx: settings.maxImageLongEdgePx)
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
        if isCaptureOverlayActive {
            isCaptureOverlayActive = false
            captureController.dismiss()
        }
        if acpClient.isStreaming {
            acpClient.cancelActiveTurn()
        }
        isPanelVisible = false
        onHidePanel?()
    }

    public func selectDeliveryTarget(_ target: DeliveryTarget, desktopPID: pid_t? = nil) {
        settings.deliveryTarget = target
        selectedDesktopWindowPID = desktopPID
        handoffError = nil
        if target.isDesktopHandoff {
            isHUDExpanded = false
            onResizePanel?(false)
        }
        applySettings()
    }

    public func selectSavedACPChat(_ session: SavedChatSession) {
        settings.deliveryTarget = .inlineACP
        settings.recordWorkspace(session.cwd)
        applySettings()
        acpClient.selectSession(session)
        isHUDExpanded = !session.transcriptPreview.isEmpty
        onResizePanel?(isHUDExpanded)
    }

    public func submitPrompt() {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachedCapture != nil else { return }

        if isCaptureOverlayActive {
            isCaptureOverlayActive = false
            captureController.dismiss()
        }

        handoffError = nil

        if settings.deliveryTarget.isDesktopHandoff {
            let textToSend = trimmed
            let captureToSend = attachedCapture
            let startNew = (settings.deliveryTarget == .desktopNewChat)
            let autoSubmit = settings.autoSubmitDesktopHandoff
            let targetPID = selectedDesktopWindowPID

            // Clear and hide Quick Entry so Antigravity Desktop App receives clean focus
            promptText = ""
            attachedCapture = nil
            isPanelVisible = false
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
                    self.onShowPanel?()
                }
            }
            return
        }

        // Inline HUD mode via `agy acp`
        let effectivePrompt = trimmed.isEmpty ? "Describe what is shown in this screenshot and highlight any issues." : trimmed
        let pngData = attachedCapture?.pngData
        let cwd = settings.selectedWorkspace

        lastSubmittedPrompt = effectivePrompt
        promptText = ""
        isHUDExpanded = true
        onResizePanel?(true)

        Task {
            await acpClient.sendPrompt(text: effectivePrompt, imagePNGData: pngData, cwd: cwd)
        }
    }

    public func startNewChat() {
        acpClient.resetSession()
        lastSubmittedPrompt = ""
        attachedCapture = nil
        isHUDExpanded = false
        onResizePanel?(false)
    }

    public func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordWorkspace(url.path)
            applySettings()
        }
    }

    public func shutdown() {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        captureController.dismiss()
        hotkeyMonitor.stop()
        acpClient.stop()
    }
}
