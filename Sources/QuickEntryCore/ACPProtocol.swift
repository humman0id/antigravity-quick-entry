import Foundation

/// Minimal dynamic JSON value for resilient Agent Client Protocol (ACP) JSON-RPC 2.0 decoding.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

/// Content blocks passed in ACP `session/prompt`.
public enum ACPContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case image(mimeType: String, base64Data: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, mimeType, data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let mimeType, let base64Data):
            try container.encode("image", forKey: .type)
            try container.encode(mimeType, forKey: .mimeType)
            try container.encode(base64Data, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(
                mimeType: try container.decode(String.self, forKey: .mimeType),
                base64Data: try container.decode(String.self, forKey: .data)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported ACPContentBlock type: \(type)"
            )
        }
    }
}

/// Permission option offered by `agy acp` in `session/request_permission`.
public struct ACPPermissionOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isAllow: Bool {
        kind.lowercased().contains("allow") || id.lowercased().contains("allow")
    }
}

/// Tool permission request emitted by `agy acp` requiring an interactive client response.
public struct ACPPermissionRequest: Equatable, Identifiable, Sendable {
    public let rpcId: JSONValue
    public let sessionId: String
    public let toolTitle: String
    public let toolKind: String
    public let rawDescription: String
    public let options: [ACPPermissionOption]

    public var id: String {
        switch rpcId {
        case .int(let i): return "rpc-\(i)"
        case .string(let s): return "rpc-\(s)"
        default: return UUID().uuidString
        }
    }

    public init(
        rpcId: JSONValue,
        sessionId: String,
        toolTitle: String,
        toolKind: String,
        rawDescription: String,
        options: [ACPPermissionOption]
    ) {
        self.rpcId = rpcId
        self.sessionId = sessionId
        self.toolTitle = toolTitle
        self.toolKind = toolKind
        self.rawDescription = rawDescription
        self.options = options
    }
}

/// Normalized incoming events parsed from `agy acp` stdout NDJSON lines.
public enum ACPIncomingEvent: Equatable, Sendable {
    case response(id: Int, result: JSONValue?, errorMessage: String?)
    case textDelta(sessionId: String, text: String)
    case thoughtDelta(sessionId: String, text: String)
    case toolCallUpdate(sessionId: String, toolCallId: String, title: String, status: String)
    case permissionRequest(ACPPermissionRequest)
    case unknown(rawMethod: String?)
}

/// Pure JSON-RPC 2.0 builder & parser for `agy acp`.
public enum ACPCodec {
    public static func encodeInitialize(id: Int) throws -> Data {
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .int(1),
                "clientInfo": .object([
                    "name": .string("AntigravityQuickEntry"),
                    "version": .string("0.1.0")
                ]),
                "clientCapabilities": .object([:])
            ])
        ]
        return try encodeLine(payload)
    }

    public static func encodeSessionNew(id: Int, cwd: String) throws -> Data {
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string("session/new"),
            "params": .object([
                "cwd": .string(cwd),
                "mcpServers": .array([])
            ])
        ]
        return try encodeLine(payload)
    }

    public static func encodeSessionList(id: Int) throws -> Data {
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string("session/list"),
            "params": .object([:])
        ]
        return try encodeLine(payload)
    }

    public static func encodeSessionResume(id: Int, sessionId: String, cwd: String) throws -> Data {
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string("session/resume"),
            "params": .object([
                "sessionId": .string(sessionId),
                "cwd": .string(cwd),
                "mcpServers": .array([])
            ])
        ]
        return try encodeLine(payload)
    }

    public static func parseSessionListResult(_ result: JSONValue?) -> [SavedChatSession] {
        let rawList = result?["sessions"]?.arrayValue ?? result?.arrayValue ?? []
        var parsed: [SavedChatSession] = []
        for item in rawList {
            guard let sid = item["sessionId"]?.stringValue ?? item["id"]?.stringValue else { continue }
            let title = item["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = item["cwd"]?.stringValue ?? AppPaths.homeDirectory.path
            let displayTitle = (title?.isEmpty == false) ? title! : "Chat \(sid.prefix(8))"
            parsed.append(SavedChatSession(id: sid, title: displayTitle, cwd: cwd))
        }
        return parsed
    }

    public static func encodeSessionPrompt(
        id: Int,
        sessionId: String,
        promptText: String,
        imagePNGData: Data?
    ) throws -> Data {
        var blocks: [JSONValue] = []
        if let png = imagePNGData {
            blocks.append(.object([
                "type": .string("image"),
                "mimeType": .string("image/png"),
                "data": .string(png.base64EncodedString())
            ]))
        }
        blocks.append(.object([
            "type": .string("text"),
            "text": .string(promptText)
        ]))

        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string("session/prompt"),
            "params": .object([
                "sessionId": .string(sessionId),
                "prompt": .array(blocks)
            ])
        ]
        return try encodeLine(payload)
    }

    public static func encodeSessionCancel(sessionId: String) throws -> Data {
        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string("session/cancel"),
            "params": .object([
                "sessionId": .string(sessionId)
            ])
        ]
        return try encodeLine(payload)
    }

    public static func encodePermissionResponse(
        rpcId: JSONValue,
        selectedOptionId: String?
    ) throws -> Data {
        let outcome: JSONValue
        if let optionId = selectedOptionId {
            outcome = .object([
                "outcome": .string("selected"),
                "optionId": .string(optionId)
            ])
        } else {
            outcome = .object([
                "outcome": .string("cancelled")
            ])
        }

        let payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": rpcId,
            "result": .object([
                "outcome": outcome
            ])
        ]
        return try encodeLine(payload)
    }

    public static func decodeLine(_ line: String) throws -> ACPIncomingEvent {
        guard let data = line.data(using: .utf8) else {
            return .unknown(rawMethod: nil)
        }
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let obj = root.objectValue else {
            return .unknown(rawMethod: nil)
        }

        let method = obj["method"]?.stringValue
        let idValue = obj["id"]

        // 1. Server-initiated request (has both `method` and `id`)
        if let method = method, let rpcId = idValue {
            if method == "session/request_permission" {
                return .permissionRequest(parsePermissionRequest(rpcId: rpcId, params: obj["params"]))
            }
            return .unknown(rawMethod: method)
        }

        // 2. Notification (has `method`, no `id`)
        if let method = method {
            if method == "session/update" {
                return parseSessionUpdate(params: obj["params"])
            }
            return .unknown(rawMethod: method)
        }

        // 3. Response to client request (has `id`, no `method`)
        if let intId = idValue?.intValue {
            if let errObj = obj["error"]?.objectValue {
                let message = errObj["message"]?.stringValue ?? "Unknown JSON-RPC error"
                return .response(id: intId, result: nil, errorMessage: message)
            }
            return .response(id: intId, result: obj["result"], errorMessage: nil)
        }

        return .unknown(rawMethod: nil)
    }

    private static func parseSessionUpdate(params: JSONValue?) -> ACPIncomingEvent {
        let sessionId = params?["sessionId"]?.stringValue ?? ""
        let update = params?["update"] ?? params
        let kind = update?["sessionUpdate"]?.stringValue ?? update?["type"]?.stringValue ?? ""

        switch kind {
        case "agent_message_chunk":
            let text = update?["content"]?["text"]?.stringValue
                ?? update?["delta"]?.stringValue
                ?? update?["text"]?.stringValue
                ?? ""
            return .textDelta(sessionId: sessionId, text: text)

        case "agent_thought_chunk":
            let text = update?["content"]?["text"]?.stringValue
                ?? update?["text"]?.stringValue
                ?? ""
            return .thoughtDelta(sessionId: sessionId, text: text)

        case "tool_call", "tool_call_update":
            let callId = update?["toolCallId"]?.stringValue ?? UUID().uuidString
            let title = update?["title"]?.stringValue
                ?? update?["kind"]?.stringValue
                ?? "Tool call"
            let status = update?["status"]?.stringValue ?? "running"
            return .toolCallUpdate(sessionId: sessionId, toolCallId: callId, title: title, status: status)

        default:
            return .unknown(rawMethod: "session/update:\(kind)")
        }
    }

    private static func parsePermissionRequest(rpcId: JSONValue, params: JSONValue?) -> ACPPermissionRequest {
        let sessionId = params?["sessionId"]?.stringValue ?? ""
        let toolCall = params?["toolCall"]
        let title = toolCall?["title"]?.stringValue
            ?? toolCall?["name"]?.stringValue
            ?? "Tool Permission"
        let kind = toolCall?["kind"]?.stringValue ?? "tool"

        var parsedOptions: [ACPPermissionOption] = []
        if let rawOpts = params?["options"]?.arrayValue {
            for item in rawOpts {
                if let optId = item["optionId"]?.stringValue ?? item["id"]?.stringValue {
                    let name = item["name"]?.stringValue ?? optId
                    let optKind = item["kind"]?.stringValue ?? optId
                    parsedOptions.append(ACPPermissionOption(id: optId, name: name, kind: optKind))
                }
            }
        }
        if parsedOptions.isEmpty {
            parsedOptions = [
                ACPPermissionOption(id: "allow_once", name: "Allow once", kind: "allow_once"),
                ACPPermissionOption(id: "reject_once", name: "Reject", kind: "reject_once")
            ]
        }

        let rawInput = toolCall?["rawInput"]
        let desc: String
        if let rawObj = rawInput, let data = try? JSONEncoder().encode(rawObj), let s = String(data: data, encoding: .utf8) {
            desc = s
        } else {
            desc = title
        }

        return ACPPermissionRequest(
            rpcId: rpcId,
            sessionId: sessionId,
            toolTitle: title,
            toolKind: kind,
            rawDescription: desc,
            options: parsedOptions
        )
    }

    private static func encodeLine(_ object: [String: JSONValue]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A) // newline delimiter
        return data
    }
}
