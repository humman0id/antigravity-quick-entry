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

    /// Optional macOS LaunchAgent plist so Quick Entry starts quietly at login
    /// and automatically wakes up whenever Antigravity Desktop App is running.
    public static var launchAgentPlistURL: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    /// Candidate macOS app bundle paths for the Antigravity Desktop App.
    public static var defaultDesktopAppPaths: [String] {
        [
            "/Applications/Antigravity.app",
            "/Applications/Google Antigravity.app",
            homeDirectory.appendingPathComponent("Applications/Antigravity.app").path
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
            TrackedPathItem(label: "Login Auto-Start Agent", path: launchAgentPlistURL.path, purpose: "Optional LaunchAgent plist (starts quietly at login)"),
            TrackedPathItem(label: "Settings", path: appSupportDirectory.path, purpose: "settings.json"),
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

/// Where Quick Entry sends your screenshot + prompt inside Antigravity Desktop App.
public enum DeliveryTarget: String, Codable, CaseIterable, Sendable {
    /// Pastes screenshot + prompt directly into the active chat in Antigravity Desktop App.
    case desktopCurrentChat = "desktop_current"
    /// Opens a new chat (`⌘N`) in Antigravity Desktop App and pastes screenshot + prompt.
    case desktopNewChat = "desktop_new"

    public var shortLabel: String {
        switch self {
        case .desktopCurrentChat: return "Desktop · Current Chat"
        case .desktopNewChat: return "Desktop · New Chat"
        }
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
    public var deliveryTarget: DeliveryTarget
    public var autoSubmitDesktopHandoff: Bool
    public var onlyActiveWhenAntigravityRunning: Bool
    public var maxDoubleTapIntervalMs: Int
    public var maxSingleTapDurationMs: Int
    public var maxImageLongEdgePx: Int

    public init(
        shortcutMode: TriggerShortcutMode = .doubleOption,
        deliveryTarget: DeliveryTarget = .desktopCurrentChat,
        autoSubmitDesktopHandoff: Bool = true,
        onlyActiveWhenAntigravityRunning: Bool = true,
        maxDoubleTapIntervalMs: Int = 360,
        maxSingleTapDurationMs: Int = 260,
        maxImageLongEdgePx: Int = 2560
    ) {
        self.shortcutMode = shortcutMode
        self.deliveryTarget = deliveryTarget
        self.autoSubmitDesktopHandoff = autoSubmitDesktopHandoff
        self.onlyActiveWhenAntigravityRunning = onlyActiveWhenAntigravityRunning
        self.maxDoubleTapIntervalMs = maxDoubleTapIntervalMs
        self.maxSingleTapDurationMs = maxSingleTapDurationMs
        self.maxImageLongEdgePx = maxImageLongEdgePx
    }

    private enum CodingKeys: String, CodingKey {
        case shortcutMode
        case deliveryTarget
        case autoSubmitDesktopHandoff
        case onlyActiveWhenAntigravityRunning
        case maxDoubleTapIntervalMs
        case maxSingleTapDurationMs
        case maxImageLongEdgePx
    }

    // Resilient decoding so older settings.json files (including removed inline_acp target) upgrade smoothly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.shortcutMode = (try? c.decodeIfPresent(TriggerShortcutMode.self, forKey: .shortcutMode)) ?? .doubleOption
        self.deliveryTarget = (try? c.decodeIfPresent(DeliveryTarget.self, forKey: .deliveryTarget)) ?? .desktopCurrentChat
        self.autoSubmitDesktopHandoff = try c.decodeIfPresent(Bool.self, forKey: .autoSubmitDesktopHandoff) ?? true
        self.onlyActiveWhenAntigravityRunning = try c.decodeIfPresent(Bool.self, forKey: .onlyActiveWhenAntigravityRunning) ?? true
        self.maxDoubleTapIntervalMs = try c.decodeIfPresent(Int.self, forKey: .maxDoubleTapIntervalMs) ?? 360
        self.maxSingleTapDurationMs = try c.decodeIfPresent(Int.self, forKey: .maxSingleTapDurationMs) ?? 260
        self.maxImageLongEdgePx = try c.decodeIfPresent(Int.self, forKey: .maxImageLongEdgePx) ?? 2560
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
}

/// Metadata written alongside `latest.png` so the optional MCP plugin knows capture context.
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
