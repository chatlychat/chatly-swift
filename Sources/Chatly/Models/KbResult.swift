import Foundation

/// One hit from `kb/search`.
public struct KbResult: Codable, Hashable, Identifiable {
    public let id: String
    public let slug: String
    public let title: String
    public let excerpt: String
}
