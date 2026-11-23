import AppKit
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import QuickEntryCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captured screenshot ready to attach in the floating composer and send to Antigravity.
public struct CapturedAttachment: Equatable {
    public let pngData: Data
    public let previewImage: NSImage
    public let metadata: CaptureMetadata

    public static func == (lhs: CapturedAttachment, rhs: CapturedAttachment) -> Bool {
        lhs.metadata == rhs.metadata && lhs.pngData.count == rhs.pngData.count
    }
}

/// Manages full-screen transparent overlay panels across all displays for clean
/// drag-to-select-region screenshot capture via ScreenCaptureKit.
/// (Window-hover highlighting is intentionally omitted so full-screen windows are never tinted.)
@MainActor
public final class CaptureOverlayController {
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var captureTask: Task<Void, Never>?
    private var maxLongEdgePx: Int = 2560

    /// True while the user is holding/dragging a selection rectangle on the overlay.
    public private(set) var isDragging: Bool = false
    /// True while an accepted region capture is finishing ScreenCaptureKit + PNG encoding.
    public private(set) var isCapturingRegion: Bool = false
    /// True whenever a screenshot interaction is actively underway and should not be cancelled by focus events.
    public var isActivelyCapturing: Bool { isDragging || isCapturingRegion }

    public var onCaptureCompleted: ((CapturedAttachment) -> Void)?
    public var onCaptureCancelled: (() -> Void)?
    public var onClickOutside: (() -> Void)?
    public var onCaptureError: ((String) -> Void)?

    public init() {}

    public static func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    public static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows drag-to-capture overlays on every connected display.
    public func beginCapture(maxLongEdgePx: Int = 2560, showHintPill: Bool = true) {
        self.maxLongEdgePx = maxLongEdgePx
        captureTask?.cancel()
        captureTask = nil
        isCapturingRegion = false
        dismiss()

        guard Self.isScreenRecordingGranted() else {
            Self.requestScreenRecordingPermission()
            onCaptureError?("Screen Recording permission is required to capture screenshots. Grant it in System Settings → Privacy & Security → Screen Recording.")
            return
        }

        presentOverlayPanels(showHintPill: showHintPill)
    }

    public func dismiss() {
        isDragging = false
        for win in overlayWindows {
            win.contentView?.isHidden = true
            win.alphaValue = 0
            win.orderOut(nil)
        }
        overlayWindows.removeAll()
        CATransaction.flush()
        NSCursor.arrow.set()
    }

    private func presentOverlayPanels(showHintPill: Bool) {
        for screen in NSScreen.screens {
            let panel = CaptureOverlayWindow(
                screen: screen,
                showHintPill: showHintPill,
                onDragStateChanged: { [weak self] dragging in
                    self?.isDragging = dragging
                },
                onSelectRegion: { [weak self] globalAppKitRect, targetScreen in
                    self?.capture(globalAppKitRect: globalAppKitRect, screen: targetScreen)
                },
                onClickOutside: { [weak self] in
                    self?.captureTask?.cancel()
                    self?.captureTask = nil
                    self?.isCapturingRegion = false
                    self?.dismiss()
                    self?.onClickOutside?()
                },
                onCancel: { [weak self] in
                    self?.captureTask?.cancel()
                    self?.captureTask = nil
                    self?.isCapturingRegion = false
                    self?.dismiss()
                    self?.onCaptureCancelled?()
                }
            )
            // Keep overlay slightly below the floating Quick Entry composer so typing always works immediately
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
            panel.orderFrontRegardless()
            overlayWindows.append(panel)
        }
    }

    private func capture(globalAppKitRect: CGRect, screen: NSScreen) {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            dismiss()
            onCaptureError?("Display not found for selection.")
            return
        }
        let backingScaleFactor = screen.backingScaleFactor
        let maxLongEdge = maxLongEdgePx
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let overlayWindowIDs = Set(overlayWindows.compactMap { win -> CGWindowID? in
            win.windowNumber > 0 ? CGWindowID(win.windowNumber) : nil
        })

        // Hide and flush all overlay panels immediately before fetching shareable content or capturing.
        isCapturingRegion = true
        dismiss()

        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCapturingRegion = false }
            do {
                // Allow WindowServer to commit the overlay order-out (~3 frames at 60Hz)
                // so no selection stroke or fill can linger in the compositor.
                try await Task.sleep(nanoseconds: 50_000_000)
                try Task.checkCancellation()

                // Fetch fresh SCShareableContent AFTER the overlay is dismissed.
                // Using onScreenWindowsOnly: false ensures any transitioning window of our PID
                // is still included in exclusion filters.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Task.checkCancellation()

                let quartzRect = CoordinateGeometry.appKitToQuartz(
                    rect: globalAppKitRect,
                    primaryDisplayHeight: primaryHeight
                )
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw NSError(domain: "CaptureOverlayController", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found for selection."])
                }

                let localSourceRect = CoordinateGeometry.quartzToDisplayLocal(
                    rect: quartzRect,
                    displayFrame: scDisplay.frame
                )
                guard localSourceRect.width >= 4 && localSourceRect.height >= 4 else { return }

                let dims = CoordinateGeometry.scaledPixelSize(
                    pointSize: localSourceRect.size,
                    backingScaleFactor: backingScaleFactor,
                    maxLongEdge: maxLongEdge
                )

                // Exclude our entire application (overlay panels, floating composer, settings) at
                // the compositor level, falling back to explicit window exclusion if needed.
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownApps = content.applications.filter { $0.processID == ownPID }
                let ownSCWindows = content.windows.filter {
                    $0.owningApplication?.processID == ownPID || overlayWindowIDs.contains($0.windowID)
                }

                let filter: SCContentFilter
                if !ownApps.isEmpty {
                    filter = SCContentFilter(
                        display: scDisplay,
                        excludingApplications: ownApps,
                        exceptingWindows: []
                    )
                } else {
                    filter = SCContentFilter(
                        display: scDisplay,
                        excludingWindows: ownSCWindows
                    )
                }

                let config = SCStreamConfiguration()
                config.sourceRect = localSourceRect
                config.width = dims.width
                config.height = dims.height
                config.showsCursor = false
                config.scalesToFit = true

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                try Task.checkCancellation()

                let label = "Region \(cgImage.width)×\(cgImage.height) px"
                let (pngData, metadata) = try await Self.encodeAndPersistPNG(from: cgImage, label: label)
                try Task.checkCancellation()

                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                let attachment = CapturedAttachment(pngData: pngData, previewImage: nsImage, metadata: metadata)
                onCaptureCompleted?(attachment)
            } catch is CancellationError {
                return
            } catch {
                onCaptureError?("Region capture failed: \(error.localizedDescription)")
            }
        }
    }

    /// Encodes `cgImage` to PNG using ImageIO and writes cache files off `@MainActor`.
    private nonisolated static func encodeAndPersistPNG(
        from cgImage: CGImage,
        label: String
    ) async throws -> (Data, CaptureMetadata) {
        try await Task.detached(priority: .userInitiated) {
            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                throw NSError(domain: "CaptureOverlayController", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize PNG encoder."])
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw NSError(domain: "CaptureOverlayController", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG screenshot."])
            }
            let pngData = mutableData as Data

            let metadata = CaptureMetadata(
                label: label,
                kind: "region",
                widthPx: cgImage.width,
                heightPx: cgImage.height
            )

            // Persist latest capture to ~/Library/Caches/AntigravityQuickEntry/ for optional companion MCP plugin
            try? AppPaths.ensureDirectoriesExist()
            try? pngData.write(to: AppPaths.latestScreenshotURL, options: .atomic)
            if let metaData = try? JSONEncoder().encode(metadata) {
                try? metaData.write(to: AppPaths.latestMetadataURL, options: .atomic)
            }

            return (pngData, metadata)
        }.value
    }
}

// MARK: - Per-Display Transparent Region Capture Panel & Drawing View

private final class CaptureOverlayWindow: NSPanel {
    init(
        screen: NSScreen,
        showHintPill: Bool,
        onDragStateChanged: @escaping (Bool) -> Void,
        onSelectRegion: @escaping (CGRect, NSScreen) -> Void,
        onClickOutside: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        setFrame(screen.frame, display: true)

        let view = CaptureOverlayCanvasView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screen: screen,
            showHintPill: showHintPill,
            onDragStateChanged: onDragStateChanged,
            onSelectRegion: onSelectRegion,
            onClickOutside: onClickOutside,
            onCancel: onCancel
        )
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaptureOverlayCanvasView: NSView {
    private let screen: NSScreen
    private let showHintPill: Bool
    private let onDragStateChanged: (Bool) -> Void
    private let onSelectRegion: (CGRect, NSScreen) -> Void
    private let onClickOutside: () -> Void
    private let onCancel: () -> Void

    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?
    private var trackingArea: NSTrackingArea?

    init(
        frame: NSRect,
        screen: NSScreen,
        showHintPill: Bool,
        onDragStateChanged: @escaping (Bool) -> Void,
        onSelectRegion: @escaping (CGRect, NSScreen) -> Void,
        onClickOutside: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.showHintPill = showHintPill
        self.onDragStateChanged = onDragStateChanged
        self.onSelectRegion = onSelectRegion
        self.onClickOutside = onClickOutside
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        let localPt = convert(event.locationInWindow, from: nil)
        dragOrigin = localPt
        dragCurrent = localPt
        onDragStateChanged(true)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragOrigin else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragOrigin = nil
        dragCurrent = nil
        onDragStateChanged(false)

        let localRect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        if localRect.width >= 10 && localRect.height >= 10 {
            let globalAppKitRect = CGRect(
                x: screen.frame.minX + localRect.minX,
                y: screen.frame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
            isHidden = true
            onSelectRegion(globalAppKitRect, screen)
        } else {
            // A quick click outside the Quick Entry panel (without dragging a region) dismisses it.
            onClickOutside()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onDragStateChanged(false)
        onCancel()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let start = dragOrigin, let end = dragCurrent {
            let sel = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            if sel.width >= 6 && sel.height >= 6 {
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: sel, xRadius: 4, yRadius: 4).fill()

                NSColor.controlAccentColor.setStroke()
                let border = NSBezierPath(roundedRect: sel, xRadius: 4, yRadius: 4)
                border.lineWidth = 2.0
                border.stroke()

                drawPill(
                    text: "\(Int(sel.width * screen.backingScaleFactor)) × \(Int(sel.height * screen.backingScaleFactor)) px",
                    near: CGPoint(x: sel.maxX - 96, y: max(12, sel.minY - 28))
                )
                return
            }
        }

        if showHintPill {
            drawCenteredTopPill(text: "Drag to capture a region · Esc or right-click to cancel")
        }
    }

    private var topSafeInset: CGFloat {
        max(screen.safeAreaInsets.top, max(0, screen.frame.maxY - screen.visibleFrame.maxY))
    }

    private func drawCenteredTopPill(text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pillWidth = size.width + 24
        let pillHeight = size.height + 12
        let topClearance = topSafeInset + 24
        let origin = CGPoint(
            x: (bounds.width - pillWidth) / 2.0,
            y: bounds.maxY - topClearance - pillHeight
        )
        drawPill(text: text, near: origin)
    }

    private func drawPill(text: String, near origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let nsText = text as NSString
        let size = nsText.size(withAttributes: attrs)
        let pillHeight = size.height + 12
        let maxY = bounds.maxY - topSafeInset - pillHeight - 16
        let pillRect = CGRect(
            x: min(max(12, origin.x), bounds.maxX - size.width - 36),
            y: min(max(12, origin.y), max(12, maxY)),
            width: size.width + 24,
            height: pillHeight
        )
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2).fill()
        nsText.draw(at: CGPoint(x: pillRect.minX + 12, y: pillRect.minY + 6), withAttributes: attrs)
    }
}
