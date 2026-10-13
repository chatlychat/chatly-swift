import Foundation

/// Response from `POST /v1/widget/init`.
public struct InitResponse: Codable, Hashable {
    /// Visitor session — token, identifiers, channel/brand scope.
    public let session: Session
    /// Workspace-level branding context for the widget header.
    public let workspace: Workspace
    /// Free-form branding map (colors, logo URL, etc.).
    public let branding: [String: AnyCodable]?
    /// Where this workspace's Socket.IO gateway lives, per region.
    ///
    /// `null` on a deployment with no `REALTIME_PUBLIC_URL` and no region row,
    /// in which case there is no realtime to connect to and
    /// ``Chatly/connectRealtime(conversationId:)`` falls back to the
    /// `api.` → `realtime.` host convention the browser widget uses.
    public let realtimeUrl: String?

    public struct Session: Codable, Hashable {
        /// Signed visitor credential, persisted in the Keychain and sent in
        /// the body of every later call.
        public let token: String
        /// **Null until the visitor has actually started a conversation.**
        ///
        /// This was a non-optional `String`, and the server has always sent
        /// `contactId: resolvedContact?.id ?? null` — so `JSONDecoder` threw
        /// on the very first `init` of every fresh install, before the token
        /// was persisted, and `initSession()` could not succeed for a visitor
        /// who had never spoken. Every fixture in the suite had invented a
        /// non-null id, so the suite agreed with the bug.
        public let contactId: String?
        public let workspaceId: String
        public let brandId: String
        public let channelId: String
        /// `true` when the channel verified the `userHash` this session
        /// presented. Absent on older servers.
        public let identityVerified: Bool?
        /// Whether we already hold an email to reach this contact on, so the
        /// host app does not re-ask a returning visitor.
        public let hasReplyAddress: Bool?

        private enum CodingKeys: String, CodingKey {
            case token, contactId, workspaceId, brandId, channelId
            case identityVerified, hasReplyAddress
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.token = try c.decode(String.self, forKey: .token)
            self.contactId = try c.decodeIfPresent(String.self, forKey: .contactId)
            self.workspaceId = try c.decode(String.self, forKey: .workspaceId)
            self.brandId = try c.decode(String.self, forKey: .brandId)
            self.channelId = try c.decode(String.self, forKey: .channelId)
            self.identityVerified = try c.decodeIfPresent(Bool.self, forKey: .identityVerified)
            self.hasReplyAddress = try c.decodeIfPresent(Bool.self, forKey: .hasReplyAddress)
        }

        public init(token: String,
                    contactId: String?,
                    workspaceId: String,
                    brandId: String,
                    channelId: String,
                    identityVerified: Bool? = nil,
                    hasReplyAddress: Bool? = nil) {
            self.token = token
            self.contactId = contactId
            self.workspaceId = workspaceId
            self.brandId = brandId
            self.channelId = channelId
            self.identityVerified = identityVerified
            self.hasReplyAddress = hasReplyAddress
        }
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

/// Response from `POST /v1/widget/realtime/token`.
///
/// Conversation-scoped and HS256, with a 1h TTL
/// (`VISITOR_REALTIME_TOKEN_TTL_SECONDS`). **Not interchangeable with
/// `InitResponse.Session.token`** — the gateway accepts only this one, and
/// only when the handshake also says `kind: "visitor"`.
public struct RealtimeToken: Codable, Hashable {
    public let token: String
    public let expiresAt: String
}

/// Response from `POST /v1/widget/uploads/presign`.
///
/// Note the field name: the presign REQUEST calls the media type
/// `contentType` and the attachment on a message calls it `mimeType`. Both
/// are the same string, and sending `mimeType` here has the key dropped by
/// zod and then 400s on the missing `contentType`.
public struct PresignResponse: Codable, Hashable {
    public let uploadId: String
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let publicUrl: String
    public let expiresAt: String
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
