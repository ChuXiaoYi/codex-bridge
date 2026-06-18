import Foundation

struct RelayEvent: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let receivedAt: String?
    let reason: String?
    let notification: JSONValue?
    let event: JSONValue?

    var summary: String {
        if case let .object(values) = notification,
           case let .string(title)? = values["title"],
           case let .string(body)? = values["body"] {
            return "\(title): \(body)"
        }
        if let reason {
            return reason
        }
        if let event {
            return event.displayString
        }
        return receivedAt ?? type
    }
}

struct RelayConnectedEvent: Decodable {
    let type: String
    let recentEvents: [RelayEvent]
}
