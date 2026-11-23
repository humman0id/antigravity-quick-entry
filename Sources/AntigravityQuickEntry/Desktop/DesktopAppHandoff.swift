import AppKit
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
            guard app.processIdentifier != ownPID else { return false }
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            if bid == AppPaths.bundleIdentifier.lowercased() { return false }
            return name.contains("antigravity") || bid.contains("antigravity") || bid.contains("jetski")
        }
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

        app.unhide()
        app.activate()
        try? await Task.sleep(nanoseconds: 220_000_000)

        if startNewChat {
            sendKey(keyCode: 45, flags: .maskCommand) // ⌘N
            try? await Task.sleep(nanoseconds: 320_000_000)
        }

        if let attachment {
            writeImageToPasteboard(pngData: attachment.pngData, image: attachment.previewImage)
            sendKey(keyCode: 9, flags: .maskCommand) // ⌘V
            try? await Task.sleep(nanoseconds: 380_000_000)
        }

        let trimmed = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            writeTextToPasteboard(trimmed)
            sendKey(keyCode: 9, flags: .maskCommand) // ⌘V
            try? await Task.sleep(nanoseconds: 160_000_000)
        }

        if autoSubmit {
            sendKey(keyCode: 36, flags: []) // Return
        }

        return nil
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

    private static func sendKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
