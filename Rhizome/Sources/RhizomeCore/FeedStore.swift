import Foundation
import Observation

public struct FeedItem: Identifiable, Equatable, Codable, Sendable {
    public enum Status: String, Equatable, Codable, Sendable {
        case dispatched
        case failed
    }

    public let id: String
    public var source: String
    public var stagedRelativePath: String?
    public var prompt: String?
    public var status: Status
    public var stage: String
    public var errorMessage: String?
    public var createdAt: Date

    public init(
        id: String,
        source: String,
        stagedRelativePath: String? = nil,
        prompt: String? = nil,
        status: Status = .dispatched,
        stage: String = "Dispatched",
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.stagedRelativePath = stagedRelativePath
        self.prompt = prompt
        self.status = status
        self.stage = stage
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}

public struct IngestRequest: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case file(URL)
        case remoteURL(String)
        case query(String)
    }

    public let id: String
    public let source: Source

    public init(id: String = UUID().uuidString, source: Source) {
        self.id = id
        self.source = source
    }

    public var displaySource: String {
        switch source {
        case .file(let url):
            return url.lastPathComponent
        case .remoteURL(let value):
            return value
        case .query(let value):
            return value
        }
    }
}

@MainActor
public protocol IngestDispatcher: AnyObject {
    func dispatch(prompt: String, workspaceURL: URL) throws
}

@MainActor
@Observable
public final class FeedStore {
    public private(set) var items: [FeedItem] = []

    private let dispatcher: IngestDispatcher
    private let logger: AppLogger
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let storageKeyPrefix = "feedItems."
    private var activeWorkspaceURL: URL?

    public init(
        dispatcher: IngestDispatcher,
        logger: AppLogger,
        defaults: UserDefaults = .standard
    ) {
        self.dispatcher = dispatcher
        self.logger = logger
        self.defaults = defaults
    }

    public func bindWorkspace(_ workspaceURL: URL) {
        activeWorkspaceURL = workspaceURL
        loadItems(for: workspaceURL)
    }

    @discardableResult
    public func recordLocalQuery(_ question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard activeWorkspaceURL != nil else {
            failAllWithoutWorkspace([IngestRequest(source: .query(trimmed))])
            return items.last?.id
        }

        let item = FeedItem(
            id: UUID().uuidString,
            source: trimmed,
            prompt: trimmed,
            stage: "Asked"
        )
        items.append(item)
        persistItems()
        return item.id
    }

    /// Convenience for tests and simple callers — stages files and dispatches one
    /// draft session per request, with no trailing text.
    public func enqueue(_ requests: [IngestRequest]) {
        guard let workspaceURL = activeWorkspaceURL else {
            failAllWithoutWorkspace(requests)
            return
        }
        enqueue(requests, trailingText: "", workspaceURL: workspaceURL)
    }

    /// Stage files (if any) and dispatch one draft session that covers the whole
    /// batch. Files are enumerated in the prompt and `trailingText` (if any) is
    /// appended as free-form context. Each request ends up as one FeedItem so the
    /// user can see what ran.
    public func enqueue(
        _ requests: [IngestRequest],
        trailingText: String,
        workspaceURL: URL
    ) {
        guard !requests.isEmpty else {
            return
        }

        var stagedFileLines: [String] = []
        var queryText: String? = nil
        var urlTargets: [String] = []
        var items: [FeedItem] = []

        for request in requests {
            var item = FeedItem(id: request.id, source: request.displaySource)
            do {
                switch request.source {
                case .file(let fileURL):
                    let stagedPath = try FeedStore.stageSource(
                        for: request,
                        workspaceURL: workspaceURL
                    )
                    let relative = FeedStore.relativePath(
                        for: stagedPath,
                        under: workspaceURL
                    ) ?? fileURL.lastPathComponent
                    item.stagedRelativePath = relative
                    stagedFileLines.append(relative)
                case .remoteURL(let value):
                    urlTargets.append(value)
                case .query(let value):
                    queryText = value
                }
            } catch {
                item.status = .failed
                item.stage = "Staging failed"
                item.errorMessage = error.localizedDescription
            }
            items.append(item)
        }

        let prompt = Self.buildPrompt(
            stagedFiles: stagedFileLines,
            urls: urlTargets,
            query: queryText,
            trailingText: trailingText
        )

        for index in items.indices where items[index].status != .failed {
            items[index].prompt = prompt
        }

        self.items.append(contentsOf: items)
        persistItems()

        guard items.contains(where: { $0.status != .failed }) else {
            return
        }

        do {
            try dispatcher.dispatch(prompt: prompt, workspaceURL: workspaceURL)
        } catch {
            logger.log("Dispatcher failed for prompt \(prompt): \(error)")
            for index in self.items.indices
            where items.contains(where: { $0.id == self.items[index].id }) && self.items[index].status != .failed {
                self.items[index].status = .failed
                self.items[index].stage = "Failed"
                self.items[index].errorMessage = error.localizedDescription
            }
            persistItems()
        }
    }

    private func failAllWithoutWorkspace(_ requests: [IngestRequest]) {
        for request in requests {
            var item = FeedItem(id: request.id, source: request.displaySource)
            item.status = .failed
            item.stage = "No workspace"
            item.errorMessage = "Workspace is not ready yet."
            items.append(item)
        }
        persistItems()
    }

    public func markFailed(id: String, message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        items[index].status = .failed
        items[index].stage = "Failed"
        items[index].errorMessage = message
        persistItems()
    }

    private func storageKey(for workspaceURL: URL) -> String {
        let path = workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        return storageKeyPrefix + path
    }

    private func loadItems(for workspaceURL: URL) {
        let key = storageKey(for: workspaceURL)
        guard let data = defaults.data(forKey: key) else {
            items = []
            return
        }
        do {
            items = try decoder.decode([FeedItem].self, from: data)
        } catch {
            logger.log("FeedStore failed to decode persisted items for \(workspaceURL.path): \(error)")
            items = []
            defaults.removeObject(forKey: key)
        }
    }

    private func persistItems() {
        guard let activeWorkspaceURL else { return }
        let key = storageKey(for: activeWorkspaceURL)
        do {
            let data = try encoder.encode(items)
            defaults.set(data, forKey: key)
        } catch {
            logger.log("FeedStore failed to encode persisted items for \(activeWorkspaceURL.path): \(error)")
        }
    }

    static func buildPrompt(
        stagedFiles: [String],
        urls: [String],
        query: String?,
        trailingText: String
    ) -> String {
        var lines: [String] = []
        if !stagedFiles.isEmpty {
            if stagedFiles.count == 1 {
                lines.append("/ingest \(stagedFiles[0])")
            } else {
                lines.append("/ingest \(stagedFiles[0])")
                for extra in stagedFiles.dropFirst() {
                    lines.append("Also ingest: \(extra)")
                }
            }
        }
        for url in urls {
            lines.append("/ingest \(url)")
        }
        if let query, !query.isEmpty, stagedFiles.isEmpty, urls.isEmpty {
            lines.append("/query \(query)")
        }
        let trailing = trailingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(trailing)
        }
        return lines.joined(separator: "\n")
    }

    public static func relativePath(for absolutePath: String, under workspaceURL: URL) -> String? {
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedWorkspace.hasSuffix("/") ? resolvedWorkspace : resolvedWorkspace + "/"
        let resolvedPath = URL(fileURLWithPath: absolutePath).resolvingSymlinksInPath().standardizedFileURL.path
        if resolvedPath == resolvedWorkspace {
            return ""
        }
        guard resolvedPath.hasPrefix(prefix) else {
            return nil
        }
        return String(resolvedPath.dropFirst(prefix.count))
    }

    static func stageSource(for request: IngestRequest, workspaceURL: URL) throws -> String {
        switch request.source {
        case .remoteURL(let value):
            return value
        case .query(let value):
            return value
        case .file(let fileURL):
            let fileManager = FileManager.default
            let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
            let rawDir = resolvedWorkspace
                .appending(path: "raw", directoryHint: .isDirectory)
                .standardizedFileURL
            let resolvedSource = fileURL.resolvingSymlinksInPath().standardizedFileURL

            if isContained(resolvedSource, inside: rawDir) {
                return resolvedSource.path
            }

            try fileManager.createDirectory(at: rawDir, withIntermediateDirectories: true)
            let target = uniqueDestination(in: rawDir, preferredName: fileURL.lastPathComponent)
            try fileManager.copyItem(at: fileURL, to: target)
            return target.path
        }
    }

    private static func isContained(_ child: URL, inside parent: URL) -> Bool {
        let parentPath = parent.path
        let childPath = child.path
        if childPath == parentPath {
            return true
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private static func uniqueDestination(in directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let sanitized = preferredName.isEmpty ? "source" : preferredName
        let initial = directory.appending(path: sanitized, directoryHint: .notDirectory)
        if !fileManager.fileExists(atPath: initial.path) {
            return initial
        }
        let base = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        for index in 1..<1000 {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appending(path: candidateName, directoryHint: .notDirectory)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let suffix = UUID().uuidString.prefix(8)
        let fallbackName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        return directory.appending(path: fallbackName, directoryHint: .notDirectory)
    }
}
