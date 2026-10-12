import Foundation

/// Rendered KB article returned by `kb/article`.
public struct KbArticle: Codable, Hashable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    /// Raw markdown body.
    public let body: String
    /// Server-rendered HTML, if available.
    public let bodyHtml: String?
    public let updatedAt: String
}
