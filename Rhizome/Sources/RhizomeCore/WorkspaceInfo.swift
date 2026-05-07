import Foundation

public struct WorkspaceInfo: Codable, Equatable, Sendable {
    public let path: String
    public let topic: String
    public let description: String
    public let rawFiles: Int
    public let processed: Int
    public let unprocessed: Int
    public let needsDocumentReview: Int
    public let wikiPageCount: Int
    public let watches: Int
    public let watchesActive: Int
    public let watchesPaused: Int
    public let watchesFailing: Int

    public init(
        path: String,
        topic: String,
        description: String,
        rawFiles: Int,
        processed: Int,
        unprocessed: Int,
        needsDocumentReview: Int,
        wikiPageCount: Int,
        watches: Int = 0,
        watchesActive: Int = 0,
        watchesPaused: Int = 0,
        watchesFailing: Int = 0
    ) {
        self.path = path
        self.topic = topic
        self.description = description
        self.rawFiles = rawFiles
        self.processed = processed
        self.unprocessed = unprocessed
        self.needsDocumentReview = needsDocumentReview
        self.wikiPageCount = wikiPageCount
        self.watches = watches
        self.watchesActive = watchesActive
        self.watchesPaused = watchesPaused
        self.watchesFailing = watchesFailing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.topic = try container.decode(String.self, forKey: .topic)
        self.description = try container.decode(String.self, forKey: .description)
        self.rawFiles = try container.decode(Int.self, forKey: .rawFiles)
        self.processed = try container.decode(Int.self, forKey: .processed)
        self.unprocessed = try container.decode(Int.self, forKey: .unprocessed)
        self.needsDocumentReview = try container.decode(Int.self, forKey: .needsDocumentReview)
        self.wikiPageCount = try container.decode(Int.self, forKey: .wikiPageCount)
        self.watches = (try? container.decodeIfPresent(Int.self, forKey: .watches)) ?? 0
        self.watchesActive = (try? container.decodeIfPresent(Int.self, forKey: .watchesActive)) ?? 0
        self.watchesPaused = (try? container.decodeIfPresent(Int.self, forKey: .watchesPaused)) ?? 0
        self.watchesFailing = (try? container.decodeIfPresent(Int.self, forKey: .watchesFailing)) ?? 0
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
