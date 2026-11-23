import Foundation
import QuickEntryCore

/// Installs or removes a user LaunchAgent plist (`~/Library/LaunchAgents/com.antigravity.quickentry.plist`)
/// so Antigravity Quick Entry starts quietly at login and automatically wakes up whenever Antigravity runs.
public enum LaunchAgentManager {
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.launchAgentPlistURL.path)
    }

    public static func install() throws {
        let executablePath = preferredExecutablePath()
        let plistURL = AppPaths.launchAgentPlistURL

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(AppPaths.bundleIdentifier)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """

        try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    public static func uninstall() throws {
        let plistURL = AppPaths.launchAgentPlistURL
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func preferredExecutablePath() -> String {
        let installedExec = AppPaths.installedAppURL
            .appendingPathComponent("Contents/MacOS/\(AppPaths.appDisplayName)")
            .path
        if FileManager.default.isExecutableFile(atPath: installedExec) {
            return installedExec
        }
        return Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
    }
}
