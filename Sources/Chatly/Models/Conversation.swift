import Foundation

/// Lightweight conversation row used in `conversations/list`.
public struct ConversationSummary: Codable, Hashable, Identifiable {
    public let id: String
    public let status: Status
    public let subject: String?
    public let lastMessagePreview: String?
    public let lastMessageAt: String?
    public let unreadContactCount: Int
    public let createdAt: String

    /// Server-side status machine for a thread.
    public enum Status: String, Codable, Hashable {
        case open
        case snoozed
        case closed
        case pending
    }
}
