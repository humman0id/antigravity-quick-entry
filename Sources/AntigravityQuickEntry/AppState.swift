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
    @Published public var accessibilityGranted: Bool = false
    @Published public var screenRecordingGranted: Bool = false
    @Published public var lastSubmittedPrompt: String = ""

    public let acpClient = ACPProcessClient()
    public let captureController = CaptureOverlayController()
    public let hotkeyMonitor = EventTapMonitor()

    public var onShowPanel: (() -> Void)?
    public var onHidePanel: (() -> Void)?
    public var onResizePanel: ((Bool) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    public init() {
        self.settings = AppSettings.load()
        try? AppPaths.ensureDirectoriesExist()

        // Forward ACPClient updates to SwiftUI views observing AppState
        acpClient.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        configureCallbacks()
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

    public func refreshPermissions() {
        accessibilityGranted = EventTapMonitor.isAccessibilityGranted(prompt: false)
        screenRecordingGranted = CaptureOverlayController.isScreenRecordingGranted()
        if accessibilityGranted {
            _ = hotkeyMonitor.start()
        }
    }

    public func applySettings() {
        hotkeyMonitor.updateSettings(settings)
        acpClient.updateCustomBinaryPath(settings.customAgyPath)
        try? settings.save()
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
        captureError = nil
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

    public func submitPrompt() {
        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachedCapture != nil else { return }

        if isCaptureOverlayActive {
            isCaptureOverlayActive = false
            captureController.dismiss()
        }

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
        captureController.dismiss()
        hotkeyMonitor.stop()
        acpClient.stop()
    }
}
