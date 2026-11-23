import AppKit
import CoreGraphics
import Foundation
import QuickEntryCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captured screenshot ready to attach in the floating composer and transmit via ACP.
public struct CapturedAttachment: Equatable {
    public let pngData: Data
    public let previewImage: NSImage
    public let metadata: CaptureMetadata

    public static func == (lhs: CapturedAttachment, rhs: CapturedAttachment) -> Bool {
        lhs.metadata == rhs.metadata && lhs.pngData.count == rhs.pngData.count
    }
}

/// Manages full-screen transparent overlay panels across all displays for instant
/// click-a-window or drag-a-region screenshot capture via ScreenCaptureKit.
@MainActor
public final class CaptureOverlayController {
    private var overlayWindows: [CaptureOverlayWindow] = []
    private var shareableContent: SCShareableContent?
    private var candidateWindows: [SCWindow] = []
    private var maxLongEdgePx: Int = 2560

    public var onCaptureCompleted: ((CapturedAttachment) -> Void)?
    public var onCaptureCancelled: (() -> Void)?
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

    /// Shows capture overlays on every connected screen.
    public func beginCapture(maxLongEdgePx: Int = 2560) {
        self.maxLongEdgePx = maxLongEdgePx
        dismiss()

        guard Self.isScreenRecordingGranted() else {
            Self.requestScreenRecordingPermission()
            onCaptureError?("Screen Recording permission is required to capture screenshots. Grant it in System Settings → Privacy & Security → Screen Recording.")
            return
        }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let validWindows = content.windows.filter { win in
                    guard let app = win.owningApplication else { return false }
                    return app.processID != ownPID
                        && win.isOnScreen
                        && win.windowLayer == 0
                        && win.frame.width >= 40
                        && win.frame.height >= 40
                }

                self.shareableContent = content
                self.candidateWindows = validWindows
                self.presentOverlayPanels()
            } catch {
                self.onCaptureError?("Failed to list screen windows: \(error.localizedDescription)")
            }
        }
    }

    public func dismiss() {
        for win in overlayWindows {
            win.orderOut(nil)
        }
        overlayWindows.removeAll()
        NSCursor.arrow.set()
    }

    private func presentOverlayPanels() {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height

        for screen in NSScreen.screens {
            let panel = CaptureOverlayWindow(
                screen: screen,
                primaryDisplayHeight: primaryHeight,
                candidateWindows: candidateWindows,
                onSelectWindow: { [weak self] scWindow in
                    self?.capture(window: scWindow)
                },
                onSelectRegion: { [weak self] globalAppKitRect, targetScreen in
                    self?.capture(globalAppKitRect: globalAppKitRect, screen: targetScreen)
                },
                onCancel: { [weak self] in
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

    private func capture(window: SCWindow) {
        dismiss()
        Task {
            do {
                let scale = NSScreen.main?.backingScaleFactor ?? 2.0
                let dims = CoordinateGeometry.scaledPixelSize(
                    pointSize: window.frame.size,
                    backingScaleFactor: scale,
                    maxLongEdge: maxLongEdgePx
                )
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = dims.width
                config.height = dims.height
                config.showsCursor = false
                config.scalesToFit = true

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                let appName = window.owningApplication?.applicationName ?? "Window"
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (title?.isEmpty == false) ? "\(appName) — \(title!)" : appName

                let attachment = try buildAttachment(
                    from: cgImage,
                    kind: "window",
                    label: label,
                    appName: appName,
                    windowTitle: title
                )
                onCaptureCompleted?(attachment)
            } catch {
                onCaptureError?("Window capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func capture(globalAppKitRect: CGRect, screen: NSScreen) {
        dismiss()
        guard let content = shareableContent else { return }

        Task {
            do {
                let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
                let quartzRect = CoordinateGeometry.appKitToQuartz(
                    rect: globalAppKitRect,
                    primaryDisplayHeight: primaryHeight
                )
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw NSError(domain: "CaptureOverlayController", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display not found for selection."])
                }

                let localSourceRect = CoordinateGeometry.quartzToDisplayLocal(
                    rect: quartzRect,
                    displayFrame: scDisplay.frame
                )
                guard localSourceRect.width >= 4 && localSourceRect.height >= 4 else { return }

                let dims = CoordinateGeometry.scaledPixelSize(
                    pointSize: localSourceRect.size,
                    backingScaleFactor: screen.backingScaleFactor,
                    maxLongEdge: maxLongEdgePx
                )

                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownSCWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
                let filter = SCContentFilter(display: scDisplay, excludingWindows: ownSCWindows)

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

                let attachment = try buildAttachment(
                    from: cgImage,
                    kind: "region",
                    label: "Region \(cgImage.width)×\(cgImage.height) px",
                    appName: nil,
                    windowTitle: nil
                )
                onCaptureCompleted?(attachment)
            } catch {
                onCaptureError?("Region capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func buildAttachment(
        from cgImage: CGImage,
        kind: String,
        label: String,
        appName: String?,
        windowTitle: String?
    ) throws -> CapturedAttachment {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CaptureOverlayController", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG screenshot."])
        }

        let metadata = CaptureMetadata(
            label: label,
            kind: kind,
            widthPx: cgImage.width,
            heightPx: cgImage.height,
            appName: appName,
            windowTitle: windowTitle
        )

        // Persist latest capture to ~/Library/Caches/AntigravityQuickEntry/ for optional companion MCP plugin
        try? AppPaths.ensureDirectoriesExist()
        try? pngData.write(to: AppPaths.latestScreenshotURL, options: .atomic)
        if let metaData = try? JSONEncoder().encode(metadata) {
            try? metaData.write(to: AppPaths.latestMetadataURL, options: .atomic)
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return CapturedAttachment(pngData: pngData, previewImage: nsImage, metadata: metadata)
    }
}

// MARK: - Per-Display Transparent Capture Panel & Drawing View

private final class CaptureOverlayWindow: NSPanel {
    init(
        screen: NSScreen,
        primaryDisplayHeight: CGFloat,
        candidateWindows: [SCWindow],
        onSelectWindow: @escaping (SCWindow) -> Void,
        onSelectRegion: @escaping (CGRect, NSScreen) -> Void,
        onCancel: @escaping () -> Void
    ) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        setFrame(screen.frame, display: true)

        let view = CaptureOverlayCanvasView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screen: screen,
            primaryDisplayHeight: primaryDisplayHeight,
            candidateWindows: candidateWindows,
            onSelectWindow: onSelectWindow,
            onSelectRegion: onSelectRegion,
            onCancel: onCancel
        )
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaptureOverlayCanvasView: NSView {
    private let screen: NSScreen
    private let primaryDisplayHeight: CGFloat
    private let candidateWindows: [SCWindow]
    private let onSelectWindow: (SCWindow) -> Void
    private let onSelectRegion: (CGRect, NSScreen) -> Void
    private let onCancel: () -> Void

    private var hoveredWindow: SCWindow?
    private var hoveredLocalRect: CGRect?
    private var dragOrigin: CGPoint?
    private var dragCurrent: CGPoint?
    private var trackingArea: NSTrackingArea?

    init(
        frame: NSRect,
        screen: NSScreen,
        primaryDisplayHeight: CGFloat,
        candidateWindows: [SCWindow],
        onSelectWindow: @escaping (SCWindow) -> Void,
        onSelectRegion: @escaping (CGRect, NSScreen) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.primaryDisplayHeight = primaryDisplayHeight
        self.candidateWindows = candidateWindows
        self.onSelectWindow = onSelectWindow
        self.onSelectRegion = onSelectRegion
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
        let localPt = convert(event.locationInWindow, from: nil)
        let globalAppKitPt = CGPoint(
            x: screen.frame.minX + localPt.x,
            y: screen.frame.minY + localPt.y
        )
        let quartzPt = CGPoint(
            x: globalAppKitPt.x,
            y: primaryDisplayHeight - globalAppKitPt.y
        )

        if let match = candidateWindows.first(where: { $0.frame.contains(quartzPt) }) {
            hoveredWindow = match
            let appKitWinRect = CoordinateGeometry.quartzToAppKit(
                rect: match.frame,
                primaryDisplayHeight: primaryDisplayHeight
            )
            hoveredLocalRect = CGRect(
                x: appKitWinRect.minX - screen.frame.minX,
                y: appKitWinRect.minY - screen.frame.minY,
                width: appKitWinRect.width,
                height: appKitWinRect.height
            )
        } else {
            hoveredWindow = nil
            hoveredLocalRect = nil
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let localPt = convert(event.locationInWindow, from: nil)
        dragOrigin = localPt
        dragCurrent = localPt
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
            onSelectRegion(globalAppKitRect, screen)
        } else if let win = hoveredWindow {
            onSelectWindow(win)
        } else {
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle dim scrim so the active selection stands out
        NSColor.black.withAlphaComponent(0.10).setFill()
        dirtyRect.fill()

        if let start = dragOrigin, let end = dragCurrent {
            let sel = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            if sel.width >= 6 && sel.height >= 6 {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
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

        if let winRect = hoveredLocalRect, let win = hoveredWindow {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: winRect, xRadius: 10, yRadius: 10).fill()

            NSColor.controlAccentColor.setStroke()
            let stroke = NSBezierPath(roundedRect: winRect, xRadius: 10, yRadius: 10)
            stroke.lineWidth = 2.5
            stroke.stroke()

            let appName = win.owningApplication?.applicationName ?? "Window"
            drawPill(
                text: "Click to capture \(appName) · or drag to crop",
                near: CGPoint(x: max(16, bounds.midX - 150), y: bounds.maxY - 56)
            )
        } else {
            drawPill(
                text: "Drag to screenshot or click a window · Esc or right-click to cancel",
                near: CGPoint(x: max(16, bounds.midX - 210), y: bounds.maxY - 56)
            )
        }
    }

    private func drawPill(text: String, near origin: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let nsText = text as NSString
        let size = nsText.size(withAttributes: attrs)
        let pillRect = CGRect(
            x: min(max(12, origin.x), bounds.maxX - size.width - 36),
            y: min(max(12, origin.y), bounds.maxY - size.height - 20),
            width: size.width + 24,
            height: size.height + 12
        )
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2).fill()
        nsText.draw(at: CGPoint(x: pillRect.minX + 12, y: pillRect.minY + 6), withAttributes: attrs)
    }
}
