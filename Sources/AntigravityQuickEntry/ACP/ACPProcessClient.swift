import Foundation
import QuickEntryCore

public enum ACPConnectionState: Equatable {
    case idle
    case starting
    case ready
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Connecting…"
        case .ready: return "agy acp ready"
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    public var isHealthy: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct ToolActivityItem: Identifiable, Equatable {
    public let id: String
    public var title: String
    public var status: String
}

/// Manages a long-lived `agy acp` subprocess over stdio JSON-RPC 2.0.
@MainActor
public final class ACPProcessClient: ObservableObject {
    @Published public private(set) var connectionState: ACPConnectionState = .idle
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var streamedText: String = ""
    @Published public private(set) var toolActivities: [ToolActivityItem] = []
    @Published public private(set) var pendingPermission: ACPPermissionRequest?
    @Published public private(set) var lastError: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stderrLines: [String] = []

    private var nextRpcId: Int = 1
    private var pendingResponses: [Int: CheckedContinuation<JSONValue?, Error>] = [:]
    private var activeSessionId: String?
    private var activeSessionCwd: String?
    private var configuredCustomPath: String = ""

    public init() {}

    public func updateCustomBinaryPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != configuredCustomPath {
            configuredCustomPath = trimmed
            stop()
        }
    }

    /// Resolves the `agy` binary path from settings, PATH, or standard install locations.
    public func resolveAgyExecutable() -> String? {
        let fm = FileManager.default
        if !configuredCustomPath.isEmpty && fm.isExecutableFile(atPath: configuredCustomPath) {
            return configuredCustomPath
        }
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let candidate = "\(dir)/agy"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        for candidate in AppPaths.defaultAgyCandidatePaths {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Starts `agy acp` and completes ACP `initialize` handshake if not already running.
    public func ensureStarted() async throws {
        if let proc = process, proc.isRunning, connectionState == .ready {
            return
        }

        stop()
        connectionState = .starting
        lastError = nil

        guard let agyPath = resolveAgyExecutable() else {
            let msg = "Could not find `agy` CLI. Install Antigravity CLI or set its path in Settings."
            connectionState = .failed(msg)
            lastError = msg
            throw NSError(domain: "ACPProcessClient", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agyPath)
        proc.arguments = ["acp"]

        // Ensure ~/.local/bin and Homebrew paths are available to child processes & MCP servers
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            AppPaths.homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] terminated in
            let exitCode = terminated.terminationStatus
            Task { @MainActor in
                self?.handleProcessTerminated(exitCode: exitCode)
            }
        }

        do {
            try proc.run()
        } catch {
            let msg = "Failed to launch `agy acp`: \(error.localizedDescription)"
            connectionState = .failed(msg)
            lastError = msg
            throw error
        }

        self.process = proc
        self.stdinPipe = inPipe

        startReadLoops(stdout: outPipe.fileHandleForReading, stderr: errPipe.fileHandleForReading)

        // Perform ACP initialize handshake
        let initId = allocateRpcId()
        let initPayload = try ACPCodec.encodeInitialize(id: initId)
        _ = try await sendRequest(id: initId, data: initPayload)
        connectionState = .ready
    }

    /// Starts a fresh conversation on the next prompt turn.
    public func resetSession() {
        activeSessionId = nil
        activeSessionCwd = nil
        streamedText = ""
        toolActivities = []
        pendingPermission = nil
        lastError = nil
    }

    /// Sends a multimodal prompt (optional PNG screenshot + text) to Antigravity in `cwd`.
    public func sendPrompt(text: String, imagePNGData: Data?, cwd: String) async {
        lastError = nil
        pendingPermission = nil
        toolActivities = []
        if !streamedText.isEmpty {
            streamedText += "\n\n---\n\n"
        }

        do {
            try await ensureStarted()

            if activeSessionId == nil || activeSessionCwd != cwd {
                let newId = allocateRpcId()
                let newPayload = try ACPCodec.encodeSessionNew(id: newId, cwd: cwd)
                let result = try await sendRequest(id: newId, data: newPayload)
                guard let sessionId = result?["sessionId"]?.stringValue else {
                    throw NSError(
                        domain: "ACPProcessClient",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "agy acp returned no sessionId from session/new."]
                    )
                }
                activeSessionId = sessionId
                activeSessionCwd = cwd
            }

            guard let sessionId = activeSessionId else { return }

            isStreaming = true
            let promptId = allocateRpcId()
            let promptPayload = try ACPCodec.encodeSessionPrompt(
                id: promptId,
                sessionId: sessionId,
                promptText: text,
                imagePNGData: imagePNGData
            )
            _ = try await sendRequest(id: promptId, data: promptPayload)
            isStreaming = false
            pendingPermission = nil
        } catch {
            isStreaming = false
            pendingPermission = nil
            let stderrContext = stderrLines.suffix(3).joined(separator: " ")
            lastError = stderrContext.isEmpty
                ? error.localizedDescription
                : "\(error.localizedDescription) (\(stderrContext))"
        }
    }

    /// Responds to an active `session/request_permission` prompt from `agy acp`.
    public func respondToPermission(optionId: String?) {
        guard let req = pendingPermission else { return }
        pendingPermission = nil
        do {
            let data = try ACPCodec.encodePermissionResponse(rpcId: req.rpcId, selectedOptionId: optionId)
            try writeToStdin(data)
        } catch {
            lastError = "Failed to send permission response: \(error.localizedDescription)"
        }
    }

    /// Cancels an in-flight prompt turn.
    public func cancelActiveTurn() {
        guard isStreaming, let sessionId = activeSessionId else { return }
        pendingPermission = nil
        do {
            let data = try ACPCodec.encodeSessionCancel(sessionId: sessionId)
            try writeToStdin(data)
        } catch {
            lastError = "Cancel failed: \(error.localizedDescription)"
        }
    }

    /// Cleanly terminates the `agy acp` subprocess.
    public func stop() {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        activeSessionId = nil
        activeSessionCwd = nil
        isStreaming = false
        pendingPermission = nil
        failAllPendingRequests(message: "ACP connection closed")
        connectionState = .idle
    }

    // MARK: - Private JSON-RPC Plumbing

    private func allocateRpcId() -> Int {
        defer { nextRpcId += 1 }
        return nextRpcId
    }

    private func writeToStdin(_ data: Data) throws {
        guard let handle = stdinPipe?.fileHandleForWriting else {
            throw NSError(domain: "ACPProcessClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "ACP stdin pipe is closed."])
        }
        try handle.write(contentsOf: data)
    }

    private func sendRequest(id: Int, data: Data) async throws -> JSONValue? {
        try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            do {
                try writeToStdin(data)
            } catch {
                pendingResponses.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func startReadLoops(stdout: FileHandle, stderr: FileHandle) {
        stdoutTask = Task.detached { [weak self] in
            do {
                for try await line in stdout.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if let event = try? ACPCodec.decodeLine(trimmed) {
                        await self?.handleIncomingEvent(event)
                    }
                }
            } catch {
                // Stream closed when process exits
            }
        }

        stderrTask = Task.detached { [weak self] in
            do {
                for try await line in stderr.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    await self?.appendStderrLine(trimmed)
                }
            } catch {
                // Ignore EOF
            }
        }
    }

    private func appendStderrLine(_ line: String) {
        stderrLines.append(line)
        if stderrLines.count > 20 {
            stderrLines.removeFirst()
        }
    }

    private func handleIncomingEvent(_ event: ACPIncomingEvent) {
        switch event {
        case .response(let id, let result, let errorMessage):
            guard let continuation = pendingResponses.removeValue(forKey: id) else { return }
            if let errorMessage {
                continuation.resume(throwing: NSError(
                    domain: "ACPProcessClient",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                ))
            } else {
                continuation.resume(returning: result)
            }

        case .textDelta(_, let text):
            streamedText += text

        case .thoughtDelta:
            break

        case .toolCallUpdate(_, let callId, let title, let status):
            if let idx = toolActivities.firstIndex(where: { $0.id == callId }) {
                toolActivities[idx].title = title
                toolActivities[idx].status = status
            } else {
                toolActivities.append(ToolActivityItem(id: callId, title: title, status: status))
            }

        case .permissionRequest(let req):
            pendingPermission = req

        case .unknown:
            break
        }
    }

    private func handleProcessTerminated(exitCode: Int32) {
        isStreaming = false
        pendingPermission = nil
        activeSessionId = nil
        process = nil
        stdinPipe = nil
        if connectionState != .idle {
            let tail = stderrLines.suffix(2).joined(separator: " ")
            let msg = tail.isEmpty ? "agy acp exited (code \(exitCode))" : tail
            connectionState = .failed(msg)
            failAllPendingRequests(message: msg)
        }
    }

    private func failAllPendingRequests(message: String) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        let err = NSError(domain: "ACPProcessClient", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
        for (_, cont) in pending {
            cont.resume(throwing: err)
        }
    }
}
