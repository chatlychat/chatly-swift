import Foundation

/// One file or image attached to a message.
///
/// The id, url, mime type, size and filename are minted by the backend's
/// `/v1/widget/uploads` endpoint and echoed back on every message that carries
/// the attachment. Image attachments (image/* mime types) render as inline
/// thumbnails in the SDK's UI; everything else renders as a file chip.
public struct Attachment: Codable, Hashable, Identifiable {
    public let id: String
    public let url: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int

    /// `true` when the SDK should treat this as a renderable inline image.
    public var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    public init(id: String, url: String, filename: String, mimeType: String, sizeBytes: Int) {
        self.id = id
        self.url = url
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

/// A single message inside a conversation.
public struct MessageRow: Codable, Hashable, Identifiable {
    public let id: String
    public let authorType: AuthorType
    public let kind: Kind
    public let body: String
    public let attachments: [Attachment]
    public let createdAt: String
    /// The rich-block envelope, exactly as stored — `{ v: 1, blocks: [...] }`.
    ///
    /// UNVALIDATED and loosely typed on purpose, matching `MessageRow.blocks`
    /// in the React Native SDK. Validation happens at RENDER time, in
    /// ``ChatlyBlocks/read(_:)``: a server newer than this app will send block
    /// types it has never heard of, and the rule is to render what can be
    /// drawn rather than to refuse the message. Decoded with `try?` for the
    /// same reason — a malformed value here can never fail the decode of the
    /// message that carries it.
    public let blocks: AnyCodable?

    public init(id: String,
                authorType: AuthorType,
                kind: Kind,
                body: String,
                attachments: [Attachment] = [],
                createdAt: String,
                blocks: AnyCodable? = nil) {
        self.id = id
        self.authorType = authorType
        self.kind = kind
        self.body = body
        self.attachments = attachments
        self.createdAt = createdAt
        self.blocks = blocks
    }

    public enum AuthorType: String, Codable, Hashable {
        case contact, agent, bot, system
    }

    /// What shape the body is.
    ///
    /// Four cases, and the set used to be wrong in both directions. `image`,
    /// `file`, `event` and `internal_note` were cases here and are not
    /// members of the server's `message_kind` enum
    /// (`text | rich | note | system_event | attachment_only`), so nothing
    /// could ever decode to them — while `rich` and `system_event` were
    /// absent. `init(from:)` below swallows an unknown kind as `.text`, which
    /// is what made the gap invisible: every card arrived looking like a
    /// sentence.
    ///
    /// `note` is deliberately absent, and that narrowing is the correct one:
    /// an agent's internal comment never reaches a visitor. The realtime
    /// gateway's `VISITOR_VISIBLE_MESSAGE_KINDS` excludes it, and so does the
    /// history route's SQL — which additionally excludes `system_event`, so
    /// that one arrives live and is gone after a reload.
    public enum Kind: String, Codable, Hashable, CaseIterable {
        case text
        /// A formatted or card-bearing reply — `messages.kind = 'rich'`, the
        /// most common non-text kind on a visitor thread (every bot card is
        /// one). Render ``MessageRow/blocks`` when it is present.
        ///
        /// That sentence was a lie until 2026-10-27: this type had no
        /// `blocks` property and the field was absent from `CodingKeys`, so
        /// the envelope was DROPPED at decode and every card, product grid
        /// and fulfilment timeline arrived as bare `body` text with no error.
        /// It is now read by ``ChatlyBlocks/read(_:)`` and drawn by
        /// ``ChatlyBlocksView`` — all twelve block types the web widget and
        /// the React Native SDK render, minus the two spatial fields
        /// (`card.model`, `card_grid.placement`) that only a 3D world host
        /// reads. See ``ChatlyBlock`` for that subset.
        case rich
        case attachmentOnly = "attachment_only"
        /// The platform's own audit turn. Arrives on the socket; the history
        /// route does not serve it.
        case systemEvent = "system_event"
    }

    private enum CodingKeys: String, CodingKey {
        case id, authorType, kind, body, attachments, createdAt, blocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.authorType = try c.decode(AuthorType.self, forKey: .authorType)
        // `kind` is sometimes absent on payloads that pre-date the attachment
        // contract — fall back to `.text` so old conversations still render.
        self.kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .text
        self.body = try c.decode(String.self, forKey: .body)
        self.attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        self.createdAt = try c.decode(String.self, forKey: .createdAt)
        // `try?`, not `decodeIfPresent`: whatever shape a newer server (or an
        // importer) put here must not fail the message around it.
        self.blocks = try? c.decode(AnyCodable.self, forKey: .blocks)
    }
}
