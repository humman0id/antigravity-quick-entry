import AppKit
import SwiftUI

/// Floating non-activating macOS `NSPanel` that appears over any app or full-screen Space
/// without stealing menu-bar activation or switching desktops.
@MainActor
public final class QuickEntryPanel: NSPanel {
    public var onEscapePressed: (() -> Void)?
    public var onResignKey: (() -> Void)?

    private static let panelWidth: CGFloat = 640
    private static let panelHeight: CGFloat = 104

    public init(rootView: AnyView) {
        let initialRect = NSRect(
            x: 0,
            y: 0,
            width: Self.panelWidth,
            height: Self.panelHeight
        )
        super.init(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let visualEffect = NSVisualEffectView(frame: initialRect)
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 18
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let hosting = FirstMouseHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        contentView = visualEffect
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    public override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscapePressed?()
            return
        }
        super.keyDown(with: event)
    }

    /// Positions the floating bar bottom-center on whichever display currently holds the mouse cursor.
    /// If already visible (e.g. user moved it out of the way before capturing), keeps its current position.
    public func showOrFocus() {
        if isVisible {
            makeKeyAndOrderFront(nil)
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let x = visibleFrame.midX - (Self.panelWidth / 2.0)
        let y = visibleFrame.minY + 36.0

        setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight), display: true)
        makeKeyAndOrderFront(nil)
    }
}

/// Ensures SwiftUI controls inside our non-activating panel respond on the very first click
/// without AppKit treating click-down jitter as a window drag.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}
