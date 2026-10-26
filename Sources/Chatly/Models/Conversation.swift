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
    ///
    /// ## `merged` was missing, and this was a HARD failure
    ///
    /// The server's `conversationStatusSchema` has five states and
    /// `POST /v1/widget/conversations/list` applies no status filter, so a
    /// visitor who opened the chat twice and had an agent merge the threads
    /// gets a row with `status: "merged"`. `ConversationSummary` used the
    /// synthesized `Decodable`, which means an unrecognised raw value throws
    /// — and it throws for the whole array, so `listConversations()` failed
    /// entirely rather than returning the other threads. The Messages tab
    /// went empty, with a `DecodingError` naming a coding path and not the
    /// cause.
    ///
    /// Hence ``unknown`` and the custom ``init(from:)``: a state added to the
    /// server after this build shipped must degrade to one unreadable row,
    /// never to an unreadable response. Switch on ``isResumable`` rather than
    /// testing `!= .closed`, which is the comparison that could not see
    /// `merged`.
    public enum Status: String, Codable, Hashable, CaseIterable {
        case open
        case snoozed
        case closed
        case pending
        /// Merged into another conversation. A tombstone: the messages live
        /// on the winner now, and the API answers a conflict rather than a
        /// no-op if you try to close it.
        case merged
        /// A state this build has never heard of. Never sent by the server
        /// under this name — it is what an unrecognised value decodes to.
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }

        /// Whether a visitor may keep writing into a thread in this state.
        ///
        /// One place, so a state added later is decided once rather than by
        /// whichever `!=` a caller happened to write. False for `merged`
        /// although it is not closed, and false for `unknown`, because the
        /// safe reading of a state we cannot name is "do not write to it".
        public var isResumable: Bool {
            self == .open || self == .pending || self == .snoozed
        }
    }
}
