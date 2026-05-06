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

    public init(
        path: String,
        topic: String,
        description: String,
        rawFiles: Int,
        processed: Int,
        unprocessed: Int,
        needsDocumentReview: Int,
        wikiPageCount: Int
    ) {
        self.path = path
        self.topic = topic
        self.description = description
        self.rawFiles = rawFiles
        self.processed = processed
        self.unprocessed = unprocessed
        self.needsDocumentReview = needsDocumentReview
        self.wikiPageCount = wikiPageCount
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
