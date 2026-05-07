import Foundation

/// One watch as emitted by `compile watch list/add/show --json-output`.
///
/// The Python sidecar is the source of truth for the schema; if you need to change
/// a key, change ``compile.watch.Watch`` first and bump the matching CLI tests.
public struct WatchRecord: Codable, Equatable, Identifiable, Sendable {
    public let watchID: String
    public let title: String
    public let relativePath: String
    public let url: String
    public let frequency: String
    public let intent: String
    public let watchStatus: String
    public let lastStatus: String?
    public let lastRun: String?
    public let nextRun: String?
    public let runCount: Int
    public let consecutiveFailures: Int
    public let lastError: String?

    public var id: String { watchID }

    enum CodingKeys: String, CodingKey {
        case watchID = "watch_id"
        case title
        case relativePath = "relative_path"
        case url
        case frequency
        case intent
        case watchStatus = "watch_status"
        case lastStatus = "last_status"
        case lastRun = "last_run"
        case nextRun = "next_run"
        case runCount = "run_count"
        case consecutiveFailures = "consecutive_failures"
        case lastError = "last_error"
    }
}

/// One event emitted per watch processed during a `compile watch tick --json-stream`
/// invocation. Used by the menu-bar app to surface progress.
public struct WatchTickEvent: Codable, Equatable, Sendable {
    public let watchID: String
    public let title: String
    public let relativePath: String
    public let status: String           // ok | unchanged | failed | skipped
    public let error: String?
    public let autoPaused: Bool?
    public let rawPath: String?

    enum CodingKeys: String, CodingKey {
        case watchID = "watch_id"
        case title
        case relativePath = "relative_path"
        case status
        case error
        case autoPaused = "auto_paused"
        case rawPath = "raw_path"
    }
}
