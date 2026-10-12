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

    public init(id: String,
                authorType: AuthorType,
                kind: Kind,
                body: String,
                attachments: [Attachment] = [],
                createdAt: String) {
        self.id = id
        self.authorType = authorType
        self.kind = kind
        self.body = body
        self.attachments = attachments
        self.createdAt = createdAt
    }

    public enum AuthorType: String, Codable, Hashable {
        case contact, agent, bot, system
    }

    public enum Kind: String, Codable, Hashable {
        case text
        case image
        case file
        case event
        case attachmentOnly = "attachment_only"
        case internalNote = "internal_note"
    }

    private enum CodingKeys: String, CodingKey {
        case id, authorType, kind, body, attachments, createdAt
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
    }
}
