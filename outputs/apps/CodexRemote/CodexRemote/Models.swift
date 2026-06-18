import Foundation

struct ThreadListResponse: Decodable {
    let data: [CodexThread]
    let nextCursor: String?
}

struct CodexThread: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let preview: String
    let previewTruncated: Bool
    let cwd: String?
    let status: JSONValue?
    let ephemeral: Bool
    let updatedAt: TimeInterval?

    var statusLabel: String {
        guard let status else { return "unknown" }
        if case let .object(values) = status, let type = values["type"] {
            return type.displayString
        }
        return status.displayString
    }
}

struct CreateThreadRequest: Encodable {
    let text: String
    let ephemeral: Bool
    let threadSource: String
}

struct SendMessageRequest: Encodable {
    let text: String
    let responsesapiClientMetadata: [String: String]
}

struct RelayDeviceRegistration: Encodable {
    let token: String
    let platform: String
    let appName: String
}

enum JSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            return value.keys.sorted().joined(separator: ", ")
        case .array(let value):
            return "\(value.count) items"
        case .null:
            return "null"
        }
    }
}
