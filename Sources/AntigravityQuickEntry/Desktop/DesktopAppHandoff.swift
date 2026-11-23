import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuickEntryCore

/// Represents an open Antigravity Desktop App (or Antigravity IDE) window detected on macOS.
public struct DetectedDesktopWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let pid: pid_t
    public let appName: String
    public let windowTitle: String

    public var displayLabel: String {
        if windowTitle.isEmpty || windowTitle == appName {
            return appName
        }
        return "\(appName) — \(windowTitle)"
    }
}

/// Sends screenshots and prompts directly into the running Antigravity Desktop App
/// without requiring the `agy` CLI. Uses Accessibility key events (`⌘V`, `⌘N`, `↵`)
/// that are already authorized by Quick Entry's Accessibility permission.
@MainActor
public enum DesktopAppHandoff {
    public static func findRunningAntigravityApps() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != ownPID,
                  !app.isTerminated,
                  app.activationPolicy == .regular else {
                return false
            }
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            if bid == AppPaths.bundleIdentifier.lowercased() { return false }
            return name.contains("antigravity") || bid.contains("antigravity") || bid.contains("jetski")
        }
    }

    /// Returns true if the currently frontmost macOS application is Antigravity Desktop App.
    public static func isAntigravityFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard front.processIdentifier != ownPID,
              !front.isTerminated,
              front.activationPolicy == .regular else {
            return false
        }
        let name = (front.localizedName ?? "").lowercased()
        let bid = (front.bundleIdentifier ?? "").lowercased()
        if bid == AppPaths.bundleIdentifier.lowercased() { return false }
        return name.contains("antigravity") || bid.contains("antigravity") || bid.contains("jetski")
    }

    /// Lists currently open Antigravity Desktop / IDE windows so the user can target a specific window.
    public static func listOpenDesktopWindows() -> [DetectedDesktopWindow] {
        let apps = findRunningAntigravityApps()
        guard !apps.isEmpty else { return [] }
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })

        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return apps.map {
                DetectedDesktopWindow(
                    id: "pid-\($0.processIdentifier)",
                    pid: $0.processIdentifier,
                    appName: $0.localizedName ?? "Antigravity",
                    windowTitle: ""
                )
            }
        }

        var results: [DetectedDesktopWindow] = []
        for dict in infoList {
            guard let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNum.int32Value)
            guard let app = appsByPID[pid] else { continue }
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            if let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: boundsDict),
               rect.width < 200 || rect.height < 120 {
                continue
            }
            let winNum = (dict[kCGWindowNumber as String] as? NSNumber)?.intValue ?? Int(pid)
            let title = (dict[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            results.append(
                DetectedDesktopWindow(
                    id: "win-\(winNum)",
                    pid: pid,
                    appName: app.localizedName ?? "Antigravity",
                    windowTitle: title
                )
            )
        }

        if results.isEmpty {
            return apps.map {
                DetectedDesktopWindow(
                    id: "pid-\($0.processIdentifier)",
                    pid: $0.processIdentifier,
                    appName: $0.localizedName ?? "Antigravity",
                    windowTitle: ""
                )
            }
        }
        return results
    }

    /// Activates Antigravity Desktop App and injects the screenshot + prompt into the chosen chat.
    public static func handoff(
        promptText: String,
        attachment: CapturedAttachment?,
        preferredPID: pid_t?,
        startNewChat: Bool,
        autoSubmit: Bool
    ) async -> String? {
        let targetApp: NSRunningApplication?
        if let pid = preferredPID,
           let matched = findRunningAntigravityApps().first(where: { $0.processIdentifier == pid }) {
            targetApp = matched
        } else if let running = findRunningAntigravityApps().first {
            targetApp = running
        } else {
            targetApp = await launchDesktopAppIfInstalled()
        }

        guard let app = targetApp else {
            return "Could not find Antigravity Desktop App running or in /Applications."
        }

        let wasAlreadyActive = app.isActive
        app.unhide()
        NSApp.yieldActivation(to: app)
        app.activate()
        if wasAlreadyActive {
            // When Antigravity was already frontmost behind our non-activating panel,
            // wait briefly for WindowServer to return key-window status after panel orderOut.
            try? await Task.sleep(nanoseconds: 160_000_000)
        } else {
            await waitUntilActive(app, timeoutMs: 900)
            // Brief settle after activation so Chromium/Electron restores input focus cleanly
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        await ensureWindowAndInputFocused(pid: app.processIdentifier, focusChatInput: !startNewChat)

        if startNewChat {
            await sendKey(keyCode: 45, flags: .maskCommand) // ⌘N
            try? await Task.sleep(nanoseconds: 360_000_000)
        }

        if let attachment {
            writeImageToPasteboard(pngData: attachment.pngData, image: attachment.previewImage)
            await sendKey(keyCode: 9, flags: .maskCommand) // ⌘V
            try? await Task.sleep(nanoseconds: 520_000_000)
        }

        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            writeTextToPasteboard(trimmed)
            await sendKey(keyCode: 9, flags: .maskCommand) // ⌘V
            try? await Task.sleep(nanoseconds: 180_000_000)
        }

        if autoSubmit {
            await sendKey(keyCode: 36, flags: []) // Return
        }

        return nil
    }

    private static func waitUntilActive(_ app: NSRunningApplication, timeoutMs: Int) async {
        let deadline = ProcessInfo.processInfo.systemUptime + (Double(timeoutMs) / 1000.0)
        while !app.isActive && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Raises Antigravity's active window and, for Current Chat handoff, focuses the bottom-most
    /// editable chat input (`AXTextArea`) if keyboard focus was elsewhere (e.g. transcript/artifact).
    private static func ensureWindowAndInputFocused(pid: pid_t, focusChatInput: Bool) async {
        let axApp = AXUIElementCreateApplication(pid)

        // Ensure the main/focused window is raised and key after QuickEntryPanel orders out.
        if let win = activeWindowElement(for: axApp) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        }

        guard focusChatInput else { return }

        // Fast path: if Antigravity already has keyboard focus in an editable text area, keep it.
        if let focused = copyAXElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString),
           isEditableTextInput(focused) {
            return
        }

        // Electron/Chromium populates its web Accessibility tree lazily when AXEnhancedUserInterface is enabled.
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 70_000_000)

        if let focused = copyAXElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString),
           isEditableTextInput(focused) {
            return
        }

        guard let win = activeWindowElement(for: axApp) else { return }
        if let composerInput = findBottomMostEditableTextArea(in: win) {
            AXUIElementSetAttributeValue(composerInput, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
    }

    private static func activeWindowElement(for axApp: AXUIElement) -> AXUIElement? {
        if let focused = copyAXElementAttribute(axApp, kAXFocusedWindowAttribute as CFString) {
            return focused
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return nil
        }
        return windows.first
    }

    private static func copyAXElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let ref = value,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return (ref as! AXUIElement)
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyBoolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func copyFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pVal = posRef, CFGetTypeID(pVal) == AXValueGetTypeID(),
              let sVal = sizeRef, CFGetTypeID(sVal) == AXValueGetTypeID() else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func isEditableTextInput(_ element: AXUIElement) -> Bool {
        guard let role = copyStringAttribute(element, kAXRoleAttribute as CFString) else { return false }
        guard role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) else {
            return false
        }
        if let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString),
           subrole == (kAXSearchFieldSubrole as String) {
            return false
        }
        if copyBoolAttribute(element, kAXEnabledAttribute as CFString) == false {
            return false
        }
        var valueSettable = DarwinBoolean(false)
        let canSetValue = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success
            && valueSettable.boolValue
        let editableFlag = copyBoolAttribute(element, "AXEditable" as CFString) ?? false
        return canSetValue || editableFlag || role == (kAXTextAreaRole as String)
    }

    /// Bounded BFS over the Antigravity window AX tree (reverse child order to reach bottom composer fast)
    /// to locate the bottom-most editable chat composer.
    private static func findBottomMostEditableTextArea(in root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var head = 0
        var visited = 0
        let maxNodes = 3000
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15

        var bestElement: AXUIElement?
        var bestBottomY: CGFloat = -.greatestFiniteMagnitude

        while head < queue.count && visited < maxNodes && ProcessInfo.processInfo.systemUptime < deadline {
            let current = queue[head]
            head += 1
            visited += 1

            if let role = copyStringAttribute(current, kAXRoleAttribute as CFString),
               role == (kAXTextAreaRole as String),
               isEditableTextInput(current),
               let frame = copyFrame(current),
               frame.width >= 150,
               frame.height >= 18 {
                let bottomY = frame.maxY
                if bottomY > bestBottomY {
                    bestBottomY = bottomY
                    bestElement = current
                }
                continue
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children.reversed() where queue.count < maxNodes {
                    queue.append(child)
                }
            }
        }
        return bestElement
    }

    private static func launchDesktopAppIfInstalled() async -> NSRunningApplication? {
        let fm = FileManager.default
        guard let path = AppPaths.defaultDesktopAppPaths.first(where: { fm.fileExists(atPath: $0) }) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let launched = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return launched ?? findRunningAntigravityApps().first
    }

    private static func writeImageToPasteboard(pngData: Data, image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        pb.setData(pngData, forType: .png)
    }

    private static func writeTextToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func sendKey(keyCode: CGKeyCode, flags: CGEventFlags) async {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 15_000_000)
        up.post(tap: .cghidEventTap)
    }
}
