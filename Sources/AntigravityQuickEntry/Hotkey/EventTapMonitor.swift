import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuickEntryCore

/// Monitors global macOS keyboard/mouse events via a passive `CGEventTap`
/// to trigger Quick Entry on double-tap Option (`⌥ ⌥`) or `Option + Space`.
public final class EventTapMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var detector = DoubleOptionDetector()
    private var shortcutMode: TriggerShortcutMode = .doubleOption
    private var wasOptionDown = false

    public var onTrigger: (() -> Void)?

    public init() {}

    deinit {
        stop()
    }

    public static func isAccessibilityGranted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func updateSettings(_ settings: AppSettings) {
        shortcutMode = settings.shortcutMode
        detector.maxTapDuration = Double(settings.maxSingleTapDurationMs) / 1000.0
        detector.maxDoubleTapInterval = Double(settings.maxDoubleTapIntervalMs) / 1000.0
        detector.reset()
        wasOptionDown = false
    }

    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let monitor = Unmanaged<EventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        detector.reset()
        wasOptionDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime

        switch shortcutMode {
        case .optionSpace:
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let onlyOption = flags.contains(.maskAlternate)
                    && !flags.contains(.maskCommand)
                    && !flags.contains(.maskControl)
                    && !flags.contains(.maskShift)
                if keyCode == 49 && onlyOption { // 49 = Space
                    fireTriggerOnMain()
                }
            }

        case .doubleOption:
            switch type {
            case .leftMouseDown, .rightMouseDown, .keyDown:
                wasOptionDown = false
                _ = detector.feed(.interruption, at: now)

            case .flagsChanged:
                let flags = event.flags
                let hasOption = flags.contains(.maskAlternate)
                let hasOtherModifier = flags.contains(.maskCommand)
                    || flags.contains(.maskControl)
                    || flags.contains(.maskShift)

                if hasOtherModifier {
                    wasOptionDown = false
                    _ = detector.feed(.interruption, at: now)
                    return
                }

                if hasOption && !wasOptionDown {
                    wasOptionDown = true
                    _ = detector.feed(.optionDown, at: now)
                } else if !hasOption && wasOptionDown {
                    wasOptionDown = false
                    if detector.feed(.optionUp, at: now) {
                        fireTriggerOnMain()
                    }
                }

            default:
                break
            }
        }
    }

    private func fireTriggerOnMain() {
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?()
        }
    }
}
