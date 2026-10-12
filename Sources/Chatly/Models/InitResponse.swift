import Foundation

/// Response from `POST /v1/widget/init`.
public struct InitResponse: Codable, Hashable {
    /// Visitor session — token, identifiers, channel/brand scope.
    public let session: Session
    /// Workspace-level branding context for the widget header.
    public let workspace: Workspace
    /// Free-form branding map (colors, logo URL, etc.).
    public let branding: [String: AnyCodable]?

    public struct Session: Codable, Hashable {
        /// Bearer token persisted in Keychain for subsequent calls.
        public let token: String
        public let contactId: String
        public let workspaceId: String
        public let brandId: String
        public let channelId: String
    }

    public struct Workspace: Codable, Hashable {
        public let id: String
        public let name: String
    }
}

/// Response from `POST /v1/widget/conversations`.
public struct StartResponse: Codable, Hashable {
    public let conversation: ConversationRef
    public let message: MessageRef

    public struct ConversationRef: Codable, Hashable {
        public let id: String
    }

    public struct MessageRef: Codable, Hashable {
        public let id: String
        public let body: String
        public let createdAt: String
    }
}

/// Identity payload sent to `init`. Mirrors the widget `WidgetIdentity` type.
public struct WidgetIdentity: Codable, Hashable {
    public let externalId: String
    public let email: String?
    public let name: String?
    /// HMAC signature when identity verification is enabled.
    public let userHash: String?
    public let attributes: [String: AnyCodable]?

    public init(
        externalId: String,
        email: String? = nil,
        name: String? = nil,
        userHash: String? = nil,
        attributes: [String: AnyCodable]? = nil
    ) {
        self.externalId = externalId
        self.email = email
        self.name = name
        self.userHash = userHash
        self.attributes = attributes
    }
}
