import AppKit
import QuickEntryCore
import SwiftUI

/// Compact floating Quick Entry composer for Antigravity Desktop App.
public struct ComposerView: View {
    @ObservedObject var state: AppState
    @FocusState private var isPromptFocused: Bool
    @State private var isHoveringRemoveCapture: Bool = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        composerBar
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .modifier(PanelDragModifier())
            .onChange(of: state.isPanelVisible) { _, visible in
            if visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isPromptFocused = true
                }
            }
        }
        .onChange(of: state.attachedCapture) { _, capture in
            if capture != nil && state.isPanelVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isPromptFocused = true
                }
            } else {
                isHoveringRemoveCapture = false
            }
        }
        .onChange(of: state.promptText) { _, newValue in
            if !newValue.isEmpty {
                state.handleUserStartedTyping()
            }
        }
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

            if let handoffError = state.handoffError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                    Text(handoffError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                }
            }

            // Top utility row: attachment chip + capture button + Desktop target picker
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
                            .frame(maxWidth: 150, alignment: .leading)

                        Button {
                            state.attachedCapture = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 20, height: 20)
                                .background(
                                    Circle()
                                        .fill(isHoveringRemoveCapture ? Color.primary.opacity(0.14) : Color.clear)
                                )
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isHoveringRemoveCapture ? .primary : .secondary)
                        .onHover { hovering in
                            isHoveringRemoveCapture = hovering
                        }
                        .help("Remove screenshot")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 3)
                    .padding(.vertical, 3)
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

                chatTargetMenu
            }

            // Prompt input row
            HStack(spacing: 8) {
                TextField(promptPlaceholder, text: $state.promptText)
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

    private var chatTargetMenu: some View {
        Menu {
            Section("Antigravity Desktop") {
                Toggle(isOn: Binding(
                    get: {
                        state.settings.deliveryTarget == .desktopCurrentChat
                            && state.selectedDesktopWindowPID == nil
                    },
                    set: { _ in
                        state.selectDeliveryTarget(.desktopCurrentChat)
                    }
                )) {
                    Label("Current Chat", systemImage: "macwindow")
                }

                Toggle(isOn: Binding(
                    get: {
                        state.settings.deliveryTarget == .desktopNewChat
                            && state.selectedDesktopWindowPID == nil
                    },
                    set: { _ in
                        state.selectDeliveryTarget(.desktopNewChat)
                    }
                )) {
                    Label("New Chat (⌘N)", systemImage: "square.and.pencil")
                }

                if state.openDesktopWindows.count > 1 && !state.isAntigravityFrontmost {
                    Menu("Choose Open Window") {
                        ForEach(state.openDesktopWindows) { win in
                            Toggle(isOn: Binding(
                                get: {
                                    state.settings.deliveryTarget == .desktopCurrentChat
                                        && state.selectedDesktopWindowPID == win.pid
                                },
                                set: { _ in
                                    state.selectDeliveryTarget(.desktopCurrentChat, desktopPID: win.pid)
                                }
                            )) {
                                Text(win.displayLabel)
                            }
                        }
                    }
                }

                Divider()

                Toggle("Auto-press Enter after paste", isOn: Binding(
                    get: { state.settings.autoSubmitDesktopHandoff },
                    set: { state.settings.autoSubmitDesktopHandoff = $0; state.applySettings() }
                ))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: activeTargetIcon)
                Text(activeTargetLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: 210, alignment: .trailing)
    }

    private var activeTargetLabel: String {
        switch state.settings.deliveryTarget {
        case .desktopCurrentChat:
            if let pid = state.selectedDesktopWindowPID,
               let win = state.openDesktopWindows.first(where: { $0.pid == pid }) {
                return win.displayLabel
            }
            return "Desktop · Current Chat"
        case .desktopNewChat:
            return "Desktop · New Chat"
        }
    }

    private var activeTargetIcon: String {
        switch state.settings.deliveryTarget {
        case .desktopCurrentChat: return "macwindow"
        case .desktopNewChat: return "square.and.pencil"
        }
    }

    private var promptPlaceholder: String {
        switch state.settings.deliveryTarget {
        case .desktopCurrentChat:
            return "Send to active Antigravity Desktop chat…"
        case .desktopNewChat:
            return "Start a new Antigravity Desktop chat…"
        }
    }

    private var canSubmit: Bool {
        !state.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.attachedCapture != nil
    }
}

/// Allows dragging the floating Quick Entry panel from any non-control surface using global mouse deltas,
/// without letting AppKit hijack button clicks (such as the remove-screenshot `×` button).
private struct PanelDragModifier: ViewModifier {
    @State private var dragStartMouse: CGPoint?
    @State private var dragStartOrigin: CGPoint?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { _ in
                    guard let window = NSApp.windows.first(where: { $0 is QuickEntryPanel && $0.isVisible }) else {
                        return
                    }
                    let mouse = NSEvent.mouseLocation
                    if dragStartMouse == nil {
                        dragStartMouse = mouse
                        dragStartOrigin = window.frame.origin
                    }
                    guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
                    window.setFrameOrigin(NSPoint(
                        x: startOrigin.x + (mouse.x - startMouse.x),
                        y: startOrigin.y + (mouse.y - startMouse.y)
                    ))
                }
                .onEnded { _ in
                    dragStartMouse = nil
                    dragStartOrigin = nil
                }
        )
    }
}
