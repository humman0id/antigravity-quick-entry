import Foundation

/// Single source of truth for every file and directory touched by Antigravity Quick Entry on macOS.
/// Keeping all paths centralized guarantees `scripts/uninstall.sh` and the Settings inspector
/// always reflect the exact on-disk footprint.
public enum AppPaths {
    public static let bundleIdentifier = "com.antigravity.quickentry"
    public static let appDisplayName = "AntigravityQuickEntry"

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Installed macOS application bundle path.
    public static var installedAppURL: URL {
        URL(fileURLWithPath: "/Applications/\(appDisplayName).app", isDirectory: true)
    }

    /// Persistent user settings & recent workspace list:
    /// `~/Library/Application Support/AntigravityQuickEntry/`
    public static var appSupportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(appDisplayName, isDirectory: true)
    }

    /// Ephemeral screenshot cache (auto-overwritten, safe to delete anytime):
    /// `~/Library/Caches/AntigravityQuickEntry/`
    public static var cacheDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(appDisplayName, isDirectory: true)
    }

    public static var settingsFileURL: URL {
        appSupportDirectory.appendingPathComponent("settings.json")
    }

    public static var latestScreenshotURL: URL {
        cacheDirectory.appendingPathComponent("latest.png")
    }

    public static var latestMetadataURL: URL {
        cacheDirectory.appendingPathComponent("latest.json")
    }

    /// Optional companion Antigravity plugin install location.
    public static var optionalPluginDirectory: URL {
        homeDirectory
            .appendingPathComponent(".antigravity", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("quick-capture", isDirectory: true)
    }

    /// Candidate locations for the official Google Antigravity CLI (`agy`).
    public static var defaultAgyCandidatePaths: [String] {
        [
            homeDirectory.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/usr/bin/agy"
        ]
    }

    /// Ensures required local directories exist on disk.
    public static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Human-readable manifest displayed in Settings -> Storage & Cleanup.
    public static var trackedPathsSummary: [TrackedPathItem] {
        [
            TrackedPathItem(label: "App Bundle", path: installedAppURL.path, purpose: "Compiled macOS menu-bar app"),
            TrackedPathItem(label: "Settings & Workspaces", path: appSupportDirectory.path, purpose: "settings.json and recent cwd paths"),
            TrackedPathItem(label: "Screenshot Cache", path: cacheDirectory.path, purpose: "latest.png and latest.json metadata"),
            TrackedPathItem(label: "Optional MCP Plugin", path: optionalPluginDirectory.path, purpose: "Companion get_latest_screenshot plugin (if installed)")
        ]
    }
}

public struct TrackedPathItem: Identifiable, Equatable, Sendable {
    public let label: String
    public let path: String
    public let purpose: String
    public var id: String { path }

    public init(label: String, path: String, purpose: String) {
        self.label = label
        self.path = path
        self.purpose = purpose
    }
}

public enum TriggerShortcutMode: String, Codable, CaseIterable, Sendable {
    case doubleOption = "double_option"
    case optionSpace = "option_space"

    public var displayName: String {
        switch self {
        case .doubleOption: return "Double-tap Option (⌥ ⌥)"
        case .optionSpace: return "Option + Space (⌥ Space)"
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var shortcutMode: TriggerShortcutMode
    public var maxDoubleTapIntervalMs: Int
    public var maxSingleTapDurationMs: Int
    public var customAgyPath: String
    public var selectedWorkspace: String
    public var recentWorkspaces: [String]
    public var maxImageLongEdgePx: Int

    public init(
        shortcutMode: TriggerShortcutMode = .doubleOption,
        maxDoubleTapIntervalMs: Int = 360,
        maxSingleTapDurationMs: Int = 260,
        customAgyPath: String = "",
        selectedWorkspace: String = FileManager.default.homeDirectoryForCurrentUser.path,
        recentWorkspaces: [String] = [],
        maxImageLongEdgePx: Int = 2560
    ) {
        self.shortcutMode = shortcutMode
        self.maxDoubleTapIntervalMs = maxDoubleTapIntervalMs
        self.maxSingleTapDurationMs = maxSingleTapDurationMs
        self.customAgyPath = customAgyPath
        self.selectedWorkspace = selectedWorkspace
        self.recentWorkspaces = recentWorkspaces
        self.maxImageLongEdgePx = maxImageLongEdgePx
    }

    public static func load(from url: URL = AppPaths.settingsFileURL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    public func save(to url: URL = AppPaths.settingsFileURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public mutating func recordWorkspace(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedWorkspace = trimmed
        recentWorkspaces.removeAll { $0 == trimmed }
        recentWorkspaces.insert(trimmed, at: 0)
        if recentWorkspaces.count > 8 {
            recentWorkspaces = Array(recentWorkspaces.prefix(8))
        }
    }
}

/// Metadata written alongside `latest.png` so the optional MCP plugin and HUD know capture context.
public struct CaptureMetadata: Codable, Equatable, Sendable {
    public let label: String
    public let kind: String // "window" | "region"
    public let widthPx: Int
    public let heightPx: Int
    public let appName: String?
    public let windowTitle: String?
    public let capturedAtISO8601: String

    public init(
        label: String,
        kind: String,
        widthPx: Int,
        heightPx: Int,
        appName: String? = nil,
        windowTitle: String? = nil,
        capturedAtISO8601: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.label = label
        self.kind = kind
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.appName = appName
        self.windowTitle = windowTitle
        self.capturedAtISO8601 = capturedAtISO8601
    }
}
