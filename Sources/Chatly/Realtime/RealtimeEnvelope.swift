import Foundation

/// Wire-protocol version. Mirrors `REALTIME_PROTOCOL_VERSION` in
/// `packages/shared/src/realtime/index.ts`.
public let ChatlyRealtimeProtocolVersion: Int = 1

/// Strongly-typed event kinds carried by ``RealtimeEnvelope``.
///
/// Mirrors `realtimeEventTypeSchema` in `packages/shared/src/realtime/index.ts`.
/// Unknown values decode to ``RealtimeEventType/unknown(_:)`` so an older SDK
/// will not crash when the server adds a new event.
public enum RealtimeEventType: RawRepresentable, Codable, Hashable {
    // System / lifecycle
    case sessionConnected
    case sessionDisconnected
    case sessionPing
    case sessionPong
    case sessionError

    // Subscriptions
    case subscribe
    case unsubscribe
    case replayCompleted

    // Presence
    case presenceOnline
    case presenceOffline
    case presenceAway

    // Conversation
    case conversationCreated
    case conversationUpdated
    case conversationAssigned
    case conversationClosed
    case conversationReopened

    // Messages
    case messageCreated
    case messageUpdated
    case messageDeleted
    case messageRead
    case messageDelivered

    // Composer
    case typingStart
    case typingStop

    // Visitor
    case visitorIdentified
    case visitorPageView

    // Triggers
    case triggerFired

    // AI
    case aiCopilotSuggestion
    case aiAgentMessage

    /// Forward-compat catch-all for event types added server-side after this
    /// SDK was published.
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "session.connected": self = .sessionConnected
        case "session.disconnected": self = .sessionDisconnected
        case "session.ping": self = .sessionPing
        case "session.pong": self = .sessionPong
        case "session.error": self = .sessionError
        case "subscribe": self = .subscribe
        case "unsubscribe": self = .unsubscribe
        case "replay.completed": self = .replayCompleted
        case "presence.online": self = .presenceOnline
        case "presence.offline": self = .presenceOffline
        case "presence.away": self = .presenceAway
        case "conversation.created": self = .conversationCreated
        case "conversation.updated": self = .conversationUpdated
        case "conversation.assigned": self = .conversationAssigned
        case "conversation.closed": self = .conversationClosed
        case "conversation.reopened": self = .conversationReopened
        case "message.created": self = .messageCreated
        case "message.updated": self = .messageUpdated
        case "message.deleted": self = .messageDeleted
        case "message.read": self = .messageRead
        case "message.delivered": self = .messageDelivered
        case "typing.start": self = .typingStart
        case "typing.stop": self = .typingStop
        case "visitor.identified": self = .visitorIdentified
        case "visitor.page_view": self = .visitorPageView
        case "trigger.fired": self = .triggerFired
        case "ai.copilot.suggestion": self = .aiCopilotSuggestion
        case "ai.agent.message": self = .aiAgentMessage
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .sessionConnected: return "session.connected"
        case .sessionDisconnected: return "session.disconnected"
        case .sessionPing: return "session.ping"
        case .sessionPong: return "session.pong"
        case .sessionError: return "session.error"
        case .subscribe: return "subscribe"
        case .unsubscribe: return "unsubscribe"
        case .replayCompleted: return "replay.completed"
        case .presenceOnline: return "presence.online"
        case .presenceOffline: return "presence.offline"
        case .presenceAway: return "presence.away"
        case .conversationCreated: return "conversation.created"
        case .conversationUpdated: return "conversation.updated"
        case .conversationAssigned: return "conversation.assigned"
        case .conversationClosed: return "conversation.closed"
        case .conversationReopened: return "conversation.reopened"
        case .messageCreated: return "message.created"
        case .messageUpdated: return "message.updated"
        case .messageDeleted: return "message.deleted"
        case .messageRead: return "message.read"
        case .messageDelivered: return "message.delivered"
        case .typingStart: return "typing.start"
        case .typingStop: return "typing.stop"
        case .visitorIdentified: return "visitor.identified"
        case .visitorPageView: return "visitor.page_view"
        case .triggerFired: return "trigger.fired"
        case .aiCopilotSuggestion: return "ai.copilot.suggestion"
        case .aiAgentMessage: return "ai.agent.message"
        case .unknown(let raw): return raw
        }
    }
}

/// Versioned envelope sent over the realtime channel.
///
/// Mirrors `realtimeEnvelopeSchema` in `packages/shared/src/realtime/index.ts`.
/// The payload is intentionally untyped (``AnyCodable``); callers should decode
/// the inner shape per ``type``.
public struct RealtimeEnvelope: Codable, Hashable {
    /// Wire-protocol version. Must equal ``ChatlyRealtimeProtocolVersion``.
    public let v: Int
    /// Event kind.
    public let type: RealtimeEventType
    /// Server-assigned UUID v7 — also used as the replay cursor.
    public let id: String
    /// Server epoch milliseconds at emission time.
    public let ts: Int64
    /// Tenant scope.
    public let workspaceId: String
    /// Event-specific body. Use ``decodePayload(as:)`` to project it.
    public let payload: AnyCodable

    private enum CodingKeys: String, CodingKey {
        case v, type, id, ts, payload
        case workspaceId = "workspace_id"
    }

    /// Designated initializer.
    public init(
        v: Int = ChatlyRealtimeProtocolVersion,
        type: RealtimeEventType,
        id: String,
        ts: Int64,
        workspaceId: String,
        payload: AnyCodable
    ) {
        self.v = v
        self.type = type
        self.id = id
        self.ts = ts
        self.workspaceId = workspaceId
        self.payload = payload
    }

    /// Re-encodes ``payload`` and decodes it as the requested ``Decodable``
    /// type. Returns `nil` if the payload shape does not match.
    public func decodePayload<T: Decodable>(as _: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Type-erased JSON value used for the envelope payload.
///
/// Wraps any JSON-shaped value so ``RealtimeEnvelope`` can round-trip without
/// knowing the per-event payload schema.
public struct AnyCodable: Codable, Hashable {
    /// Boxed JSON value (`String`, `Double`, `Bool`, `[Any]`, `[String: Any]`,
    /// or `NSNull`).
    public let value: Any

    /// Wraps an arbitrary value. Non-JSON values will fail when re-encoded.
    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int64.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            self.value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let i as Int64:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        let l = (try? JSONEncoder().encode(lhs)) ?? Data()
        let r = (try? JSONEncoder().encode(rhs)) ?? Data()
        return l == r
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine((try? JSONEncoder().encode(self)) ?? Data())
    }
}
