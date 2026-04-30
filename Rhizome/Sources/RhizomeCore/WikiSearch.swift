import Foundation

public struct SearchHit: Codable, Equatable, Sendable {
    public let title: String
    public let relativePath: String
    public let pageType: String
    public let summary: String
    public let score: Int
    public let reasons: [String]
    public let snippet: String

    enum CodingKeys: String, CodingKey {
        case title
        case relativePath = "relative_path"
        case pageType = "page_type"
        case summary
        case score
        case reasons
        case snippet
    }
}

public struct WikiPage: Decodable, Equatable, Sendable {
    public let title: String
    public let relativePath: String
    public let pageType: String
    public let body: String?
    public let summary: String?
    public let wordCount: Int

    enum CodingKeys: String, CodingKey {
        case title
        case relativePath = "relative_path"
        case pageType = "page_type"
        case body
        case frontmatter
        case wordCount = "word_count"
    }

    private struct Frontmatter: Codable {
        let summary: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        pageType = try container.decode(String.self, forKey: .pageType)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
        summary = try container.decodeIfPresent(Frontmatter.self, forKey: .frontmatter)?.summary
    }
}

public struct WikiNeighborhood: Decodable, Equatable, Sendable {
    public let page: WikiPage
    public let backlinks: [String]
    public let outboundPages: [String]
    public let outboundFiles: [String]
    public let supportingSourcePages: [String]
    public let relatedPages: [String]
    public let citedSourcePages: [String]
    public let unresolvedTargets: [String]

    enum CodingKeys: String, CodingKey {
        case page
        case backlinks
        case outboundPages = "outbound_pages"
        case outboundFiles = "outbound_files"
        case supportingSourcePages = "supporting_source_pages"
        case relatedPages = "related_pages"
        case citedSourcePages = "cited_source_pages"
        case unresolvedTargets = "unresolved_targets"
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    public let id: String
    public let role: Role
    public let text: String
    public let references: [SearchHit]

    public init(id: String = UUID().uuidString, role: Role, text: String, references: [SearchHit] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.references = references
    }
}
