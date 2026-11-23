import AppKit
import QuickEntryCore
import SwiftUI

/// Compact floating Quick Entry composer + expandable streaming Antigravity HUD.
public struct ComposerView: View {
    @ObservedObject var state: AppState
    @FocusState private var isPromptFocused: Bool

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            if state.isHUDExpanded {
                streamingDrawer
                Divider().opacity(0.35)
            }
            composerBar
        }
        .onChange(of: state.isPanelVisible) { _, visible in
            if visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isPromptFocused = true
                }
            }
        }
        .onChange(of: state.promptText) { _, newValue in
            if !newValue.isEmpty {
                state.handleUserStartedTyping()
            }
        }
    }

    // MARK: - Expanded Streaming HUD Drawer

    private var streamingDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top bar
            HStack(spacing: 8) {
                Text("✦ Antigravity")
                    .font(.system(size: 13, weight: .semibold))
                statusPill
                Spacer()
                if state.acpClient.isStreaming {
                    Button("Stop") {
                        state.acpClient.cancelActiveTurn()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("New Chat") {
                    state.startNewChat()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Button {
                    state.dismissQuickEntry()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss (Esc)")
            }

            // Streamed response body
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !state.lastSubmittedPrompt.isEmpty {
                            HStack(spacing: 6) {
                                if state.attachedCapture != nil {
                                    Text("📷 PNG")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.18))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                Text(state.lastSubmittedPrompt)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }

                        if !state.acpClient.toolActivities.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(state.acpClient.toolActivities) { tool in
                                    HStack(spacing: 6) {
                                        Image(systemName: "wrench.and.screwdriver")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Text(tool.title)
                                            .font(.system(size: 11, design: .monospaced))
                                        Spacer()
                                        Text(tool.status)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }

                        if let err = state.acpClient.lastError {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        if !state.acpClient.streamedText.isEmpty {
                            Text(state.acpClient.streamedText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if state.acpClient.isStreaming {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for Antigravity…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let perm = state.acpClient.pendingPermission {
                            permissionCard(perm)
                        }

                        Color.clear.frame(height: 1).id("bottom-anchor")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.acpClient.streamedText) { _, _ in
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
        }
        .padding(14)
        .frame(maxHeight: 330)
    }

    private var statusPill: some View {
        let text: String
        let color: Color
        if state.acpClient.pendingPermission != nil {
            text = "approval needed"
            color = .orange
        } else if state.acpClient.isStreaming {
            text = "streaming…"
            color = .accentColor
        } else if case .failed = state.acpClient.connectionState {
            text = "error"
            color = .red
        } else {
            text = "ready"
            color = .green
        }

        return Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func permissionCard(_ req: ACPPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Permission Required")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(req.toolTitle)
                    .font(.system(size: 11, design: .monospaced))
            }

            Text(req.rawDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                ForEach(req.options) { opt in
                    if opt.isAllow {
                        Button(opt.name) {
                            state.acpClient.respondToPermission(optionId: opt.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button(opt.name) {
                            state.acpClient.respondToPermission(optionId: opt.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Compact Floating Composer Bar

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let captureError = state.captureError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text(captureError)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Settings") {
                        CaptureOverlayController.openScreenRecordingSettings()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }

            // Top utility row: attachment chip + capture button + workspace cwd picker
            HStack(spacing: 8) {
                if let capture = state.attachedCapture {
                    HStack(spacing: 6) {
                        Image(nsImage: capture.previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(capture.metadata.label)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: 190, alignment: .leading)

                        Button {
                            state.attachedCapture = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button {
                    state.startRecapture()
                } label: {
                    Label(state.attachedCapture == nil ? "Capture" : "Retake", systemImage: "viewfinder")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                // Workspace folder menu
                Menu {
                    Button("Choose Folder…") {
                        state.chooseWorkspaceFolder()
                    }
                    Divider()
                    ForEach(workspaceOptions, id: \.self) { path in
                        Button(abbreviate(path)) {
                            state.settings.recordWorkspace(path)
                            state.applySettings()
                        }
                    }
                } label: {
                    Label(abbreviate(state.settings.selectedWorkspace), systemImage: "folder")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 210, alignment: .trailing)
            }

            // Prompt input row
            HStack(spacing: 8) {
                TextField("Ask Antigravity about your screen…", text: $state.promptText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isPromptFocused)
                    .onSubmit {
                        state.submitPrompt()
                    }

                Button {
                    state.submitPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.4))
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
    }

    private var workspaceOptions: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in [state.settings.selectedWorkspace] + state.settings.recentWorkspaces {
            if !path.isEmpty && seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }

    private var canSubmit: Bool {
        !state.acpClient.isStreaming &&
        (!state.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.attachedCapture != nil)
    }

    private func abbreviate(_ path: String) -> String {
        let home = AppPaths.homeDirectory.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
