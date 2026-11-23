import AppKit
import QuickEntryCore
import SwiftUI

/// Settings window showing shortcut options, macOS permissions,
/// and a full transparent manifest of every file path touched on disk.
public struct SettingsView: View {
    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            storageAndCleanupTab
                .tabItem { Label("Files & Cleanup", systemImage: "folder.badge.gearshape") }
        }
        .padding(16)
        .frame(width: 530, height: 470)
    }

    private var generalTab: some View {
        Form {
            Section("Activation & Auto-Start") {
                Toggle("Only active while Antigravity is running", isOn: $state.settings.onlyActiveWhenAntigravityRunning)
                    .onChange(of: state.settings.onlyActiveWhenAntigravityRunning) { _, _ in
                        state.applySettings()
                    }

                Toggle("Start quietly at login (LaunchAgent)", isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { state.setLaunchAtLogin($0) }
                ))

                Text(state.isAntigravityRunning
                     ? "Antigravity is currently running — Quick Entry is active."
                     : "Antigravity is not running — hotkey sleeps automatically until you open Antigravity.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Quick Entry Shortcut") {
                Picker("Trigger", selection: $state.settings.shortcutMode) {
                    ForEach(TriggerShortcutMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: state.settings.shortcutMode) { _, _ in
                    state.applySettings()
                }

                if state.settings.shortcutMode == .doubleOption {
                    HStack {
                        Text("Double-tap window")
                        Slider(
                            value: Binding(
                                get: { Double(state.settings.maxDoubleTapIntervalMs) },
                                set: { state.settings.maxDoubleTapIntervalMs = Int($0); state.applySettings() }
                            ),
                            in: 200...550,
                            step: 20
                        )
                        Text("\(state.settings.maxDoubleTapIntervalMs) ms")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }

            Section("macOS Permissions") {
                HStack {
                    Label(
                        state.accessibilityGranted ? "Accessibility: Granted" : "Accessibility: Required for global ⌥ ⌥",
                        systemImage: state.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(state.accessibilityGranted ? .green : .orange)
                    Spacer()
                    Button("Open Settings") {
                        EventTapMonitor.openAccessibilitySettings()
                    }
                }

                HStack {
                    Label(
                        state.screenRecordingGranted ? "Screen Recording: Granted" : "Screen Recording: Required for screenshots",
                        systemImage: state.screenRecordingGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(state.screenRecordingGranted ? .green : .orange)
                    Spacer()
                    Button("Open Settings") {
                        CaptureOverlayController.openScreenRecordingSettings()
                    }
                }

                Button("Re-check Permissions") {
                    state.refreshPermissions()
                }
            }

            Section("Delivery Target") {
                Picker("Send prompts to", selection: $state.settings.deliveryTarget) {
                    ForEach(DeliveryTarget.allCases, id: \.self) { target in
                        Text(target.shortLabel).tag(target)
                    }
                }
                .onChange(of: state.settings.deliveryTarget) { _, _ in
                    state.applySettings()
                }

                Toggle("Auto-press Enter after pasting into Desktop App", isOn: $state.settings.autoSubmitDesktopHandoff)
                    .onChange(of: state.settings.autoSubmitDesktopHandoff) { _, _ in
                        state.applySettings()
                    }
            }
        }
        .formStyle(.grouped)
    }

    private var storageAndCleanupTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every file created by Antigravity Quick Entry lives in these exact locations:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            List(AppPaths.trackedPathsSummary) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.label)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Reveal") {
                            let url = URL(fileURLWithPath: item.path)
                            if FileManager.default.fileExists(atPath: item.path) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            } else {
                                NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(item.purpose)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("To remove everything cleanly, run scripts/uninstall.sh --confirm from your repo.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Cache") {
                    try? FileManager.default.removeItem(at: AppPaths.latestScreenshotURL)
                    try? FileManager.default.removeItem(at: AppPaths.latestMetadataURL)
                }
            }
        }
    }
}
