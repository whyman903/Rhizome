import Foundation
import XCTest
@testable import RhizomeCore

private final class FakeCompileRunner: CompileRunning, @unchecked Sendable {
    var workspaceInfo: WorkspaceInfo
    var pageResult: WikiPage
    var pagesByLocator: [String: WikiPage]
    private(set) var requestedPageLocators: [String] = []

    init(
        workspaceInfo: WorkspaceInfo,
        pageResult: WikiPage,
        pagesByLocator: [String: WikiPage] = [:]
    ) {
        self.workspaceInfo = workspaceInfo
        self.pageResult = pageResult
        self.pagesByLocator = pagesByLocator
    }

    func initWorkspace(name: String, at path: URL) async throws -> WorkspaceInfo {
        workspaceInfo
    }

    func status(at path: URL) async throws -> WorkspaceInfo {
        workspaceInfo
    }

    func prepareWorkspaceForClaude(at path: URL, force: Bool) async throws {}

    func page(locator: String, at path: URL) async throws -> WikiPage {
        requestedPageLocators.append(locator)
        if let page = pagesByLocator[locator] {
            return page
        }
        if let page = pagesByLocator.values.first(where: {
            $0.relativePath == locator || $0.title == locator
        }) {
            return page
        }
        return pageResult
    }

    func ingest(
        source: String,
        at path: URL,
        jobID: String,
        onEvent: @escaping @Sendable (CompileEvent) -> Void
    ) async throws -> String? {
        nil
    }
}

@MainActor
private final class NoopDispatcher: IngestDispatcher {
    func dispatch(prompt: String, workspaceURL: URL) throws {}
}

private final class NoopQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {}
}

private final class SuccessfulQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    let onRun: @Sendable () -> Void

    init(onRun: @escaping @Sendable () -> Void = {}) {
        self.onRun = onRun
    }

    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        onRun()
        await onEvent(.toolCall(name: "Grep"))
        await onEvent(.finished(
            text: "answer",
            costUSD: 0.01,
            durationMs: 250,
            permissionDenials: [],
            sessionID: "claude-session-success"
        ))
    }
}

private final class StreamingOnlyQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    let text: String

    init(text: String = "streamed answer") {
        self.text = text
    }

    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        await onEvent(.assistantText(text))
    }
}

private final class CapturingQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CapturingQueryRunner")
    private var prompts: [String] = []
    private var resumeIDs: [String?] = []

    var capturedPrompts: [String] {
        queue.sync { prompts }
    }

    var capturedResumeSessionIDs: [String?] {
        queue.sync { resumeIDs }
    }

    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        queue.sync {
            prompts.append(prompt)
            resumeIDs.append(resumeSessionID)
        }
        await onEvent(.toolCall(name: "Grep"))
        await onEvent(.finished(
            text: "answer",
            costUSD: nil,
            durationMs: nil,
            permissionDenials: [],
            sessionID: "claude-session-captured"
        ))
    }
}

private final class ScriptedQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ScriptedQueryRunner")
    private var scripts: [[ClaudeQueryEvent]]
    private var prompts: [String] = []
    private var resumeIDs: [String?] = []

    init(scripts: [[ClaudeQueryEvent]]) {
        self.scripts = scripts
    }

    var capturedPrompts: [String] {
        queue.sync { prompts }
    }

    var capturedResumeSessionIDs: [String?] {
        queue.sync { resumeIDs }
    }

    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        let events = queue.sync {
            prompts.append(prompt)
            resumeIDs.append(resumeSessionID)
            guard !scripts.isEmpty else { return [ClaudeQueryEvent]() }
            return scripts.removeFirst()
        }
        for event in events {
            await onEvent(event)
        }
    }
}

private final class ExpiringResumeQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ExpiringResumeQueryRunner")
    private var prompts: [String] = []
    private var resumeIDs: [String?] = []
    private var didFailResume = false

    var capturedPrompts: [String] {
        queue.sync { prompts }
    }

    var capturedResumeSessionIDs: [String?] {
        queue.sync { resumeIDs }
    }

    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        let shouldFail: Bool = queue.sync {
            prompts.append(prompt)
            resumeIDs.append(resumeSessionID)
            if resumeSessionID != nil && !didFailResume {
                didFailResume = true
                return true
            }
            return false
        }
        if shouldFail {
            throw ClaudeQueryResumeUnavailableError(message: "Session not found")
        }
        await onEvent(.toolCall(name: "Grep"))
        await onEvent(.finished(
            text: "fallback answer",
            costUSD: nil,
            durationMs: nil,
            permissionDenials: [],
            sessionID: "fresh-session"
        ))
    }
}

private final class DelayedQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 300_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }
}

private final class DynamicCompileRunner: CompileRunning, @unchecked Sendable {
    var pageResult: WikiPage
    private(set) var requestedPageLocators: [String] = []

    init(pageResult: WikiPage) {
        self.pageResult = pageResult
    }

    func initWorkspace(name: String, at path: URL) async throws -> WorkspaceInfo {
        workspaceInfo(for: path)
    }

    func status(at path: URL) async throws -> WorkspaceInfo {
        workspaceInfo(for: path)
    }

    func prepareWorkspaceForClaude(at path: URL, force: Bool) async throws {}

    func page(locator: String, at path: URL) async throws -> WikiPage {
        requestedPageLocators.append(locator)
        return pageResult
    }

    func ingest(
        source: String,
        at path: URL,
        jobID: String,
        onEvent: @escaping @Sendable (CompileEvent) -> Void
    ) async throws -> String? {
        nil
    }

    private func workspaceInfo(for path: URL) -> WorkspaceInfo {
        WorkspaceInfo(
            path: path.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
    }
}

private final class SelectivePageRunner: CompileRunning, @unchecked Sendable {
    let workspaceInfo: WorkspaceInfo
    let pagesByLocator: [String: WikiPage]
    private(set) var requestedPageLocators: [String] = []

    init(workspaceInfo: WorkspaceInfo, pagesByLocator: [String: WikiPage]) {
        self.workspaceInfo = workspaceInfo
        self.pagesByLocator = pagesByLocator
    }

    func initWorkspace(name: String, at path: URL) async throws -> WorkspaceInfo {
        workspaceInfo
    }

    func status(at path: URL) async throws -> WorkspaceInfo {
        workspaceInfo
    }

    func prepareWorkspaceForClaude(at path: URL, force: Bool) async throws {}

    func page(locator: String, at path: URL) async throws -> WikiPage {
        requestedPageLocators.append(locator)
        guard let page = pagesByLocator[locator] else {
            throw CompileCommandError(locator)
        }
        return page
    }

    func ingest(
        source: String,
        at path: URL,
        jobID: String,
        onEvent: @escaping @Sendable (CompileEvent) -> Void
    ) async throws -> String? {
        nil
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "AppModelTests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "AppModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        if let defaults {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        defaults = nil
        defaultsSuiteName = nil
        tempDirectory = nil
        try await super.tearDown()
    }

    private func makePage(
        title: String,
        relativePath: String,
        pageType: String = "article",
        body: String? = nil,
        summary: String? = "summary"
    ) throws -> WikiPage {
        let bodyText = body ?? "# \(title)"
        var payload: [String: Any] = [
            "title": title,
            "relative_path": relativePath,
            "page_type": pageType,
            "word_count": bodyText.split(whereSeparator: { $0.isWhitespace }).count,
            "body": bodyText,
        ]
        if let summary {
            payload["frontmatter"] = ["summary": summary]
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(WikiPage.self, from: data)
    }

    private func writeHistory(_ records: [QueryHistoryRecord], to workspaceURL: URL) throws {
        let compileURL = workspaceURL.appending(path: ".compile", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: compileURL, withIntermediateDirectories: true)
        let historyURL = compileURL.appending(path: "query-history.json", directoryHint: .notDirectory)
        let data = try JSONEncoder().encode(records)
        try data.write(to: historyURL, options: .atomic)
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    func testOpenWikiPageResolvesBareTitleToRelativePathBeforeOpeningObsidian() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let fakeRunner = FakeCompileRunner(
            workspaceInfo: info,
            pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
        )

        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let opened = expectation(description: "open note")
        var openedNotePath: String?
        var openedWorkspacePath: String?

        let model = AppModel(
            runner: fakeRunner,
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { notePath, workspace in
                openedNotePath = notePath
                openedWorkspacePath = workspace.path
                opened.fulfill()
                return .opened
            },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.openWikiPage(target: "Planner")

        await fulfillment(of: [opened], timeout: 1.0)
        XCTAssertEqual(fakeRunner.requestedPageLocators, ["Planner"])
        XCTAssertEqual(openedNotePath, "wiki/articles/planner.md")
        XCTAssertEqual(openedWorkspacePath, workspaceURL.path)
    }

    func testOpenWikiPageFallsBackFromNotionImportTitleToCurrentTitle() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-notion-fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let runner = SelectivePageRunner(
            workspaceInfo: info,
            pagesByLocator: [
                "System design": try makePage(
                    title: "System design",
                    relativePath: "wiki/sources/System design.md",
                    pageType: "source"
                )
            ]
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let opened = expectation(description: "open fallback note")
        var openedNotePath: String?

        let model = AppModel(
            runner: runner,
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-notion-fallback", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { notePath, _ in
                openedNotePath = notePath
                opened.fulfill()
                return .opened
            },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.openWikiPage(target: "System design (Notion)")

        await fulfillment(of: [opened], timeout: 1.0)
        XCTAssertEqual(runner.requestedPageLocators, ["System design (Notion)", "System design"])
        XCTAssertEqual(openedNotePath, "wiki/sources/System design.md")
        XCTAssertNil(model.lastError)
    }

    func testSendQueryAddsInAppQueryToFeedStore() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let fakeRunner = FakeCompileRunner(
            workspaceInfo: info,
            pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let ranQuery = expectation(description: "query runner called")
        let model = AppModel(
            runner: fakeRunner,
            dispatcher: NoopDispatcher(),
            queryRunner: SuccessfulQueryRunner(onRun: { ranQuery.fulfill() }),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("What changed in SIDE?")

        await fulfillment(of: [ranQuery], timeout: 1.0)
        XCTAssertEqual(model.feedStore.items.count, 1)
        XCTAssertEqual(model.feedStore.items.first?.source, "What changed in SIDE?")
        XCTAssertEqual(model.feedStore.items.first?.prompt, "What changed in SIDE?")
    }

    func testCompletedQueriesPersistAcrossAppSessions() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let fakeRunner = FakeCompileRunner(
            workspaceInfo: info,
            pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let firstModel = AppModel(
            runner: fakeRunner,
            dispatcher: NoopDispatcher(),
            queryRunner: SuccessfulQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await firstModel.bootstrapIfNeeded()
        firstModel.sendQuery("What changed in SIDE?")

        await waitUntil {
            firstModel.queryHistory.count == 1
                && firstModel.queryHistory.first?.turns.count == 1
        }

        let historyURL = workspaceURL.appending(path: ".compile/query-history.json", directoryHint: .notDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))

        let secondModel = AppModel(
            runner: fakeRunner,
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-reloaded", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await secondModel.bootstrapIfNeeded()

        XCTAssertEqual(secondModel.queryHistory.count, 1)
        XCTAssertEqual(secondModel.queryHistory.first?.firstQuestion, "What changed in SIDE?")
        XCTAssertEqual(secondModel.queryHistory.first?.turns.count, 1)
    }

    func testQueryFailsWhenRunnerReturnsWithoutTerminalEvent() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-stream-only", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")
        let model = AppModel(
            runner: FakeCompileRunner(
                workspaceInfo: info,
                pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
            ),
            dispatcher: NoopDispatcher(),
            queryRunner: StreamingOnlyQueryRunner(text: "streamed answer"),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-stream-only", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("What changed?")

        await waitUntil {
            model.querySession.status == .failed
        }

        XCTAssertEqual(model.querySession.assistantText, "streamed answer")
        XCTAssertEqual(model.querySession.errorMessage, "Query completed without a final response")
        XCTAssertNil(model.queryHistory.first?.turns.first?.answer)
    }

    func testQueryPromptPassesRawQuestionToClaude() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-raw-query", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let fakeRunner = FakeCompileRunner(
            workspaceInfo: info,
            pageResult: try makePage(title: "Long Source", relativePath: "wiki/sources/long-source.md")
        )
        let queryRunner = CapturingQueryRunner()
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: fakeRunner,
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-raw-query", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("What does the source say?")

        await waitUntil {
            model.querySession.status == .completed && !queryRunner.capturedPrompts.isEmpty
        }

        let prompt = try XCTUnwrap(queryRunner.capturedPrompts.first)
        XCTAssertEqual(prompt, "What does the source say?")
        XCTAssertTrue(fakeRunner.requestedPageLocators.isEmpty)
        XCTAssertEqual(queryRunner.capturedResumeSessionIDs.count, 1)
        XCTAssertNil(queryRunner.capturedResumeSessionIDs[0])
    }

    func testZeroToolAnswerRetriesOnceAndPersistsRetryOutput() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-zero-tool-retry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let queryRunner = ScriptedQueryRunner(
            scripts: [
                [
                    .finished(
                        text: "bad answer",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "bad-session"
                    ),
                ],
                [
                    .toolCall(name: "Grep"),
                    .finished(
                        text: "researched answer",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "retry-session"
                    ),
                ],
            ]
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: FakeCompileRunner(
                workspaceInfo: info,
                pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
            ),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-zero-tool-retry", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("what's the difference between tcp and udp?")

        await waitUntil {
            model.querySession.status == .completed && queryRunner.capturedPrompts.count == 2
        }

        XCTAssertEqual(queryRunner.capturedPrompts[0], "what's the difference between tcp and udp?")
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("did not use any research tools"))
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("what's the difference between tcp and udp?"))
        XCTAssertEqual(model.querySession.assistantText, "researched answer")
        XCTAssertEqual(model.querySession.claudeSessionID, "retry-session")
        XCTAssertEqual(model.queryHistory.first?.turns.map(\.answer), ["researched answer"])
        XCTAssertFalse(model.queryHistory.first?.turns.contains { $0.answer == "bad answer" } ?? true)
    }

    func testRetryResultIsShownWhenRetryAlsoUsesNoTools() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-zero-tool-retry-visible", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let queryRunner = ScriptedQueryRunner(
            scripts: [
                [
                    .finished(
                        text: "bad answer",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "bad-session"
                    ),
                ],
                [
                    .finished(
                        text: "retry answer",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "retry-session"
                    ),
                ],
            ]
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: FakeCompileRunner(
                workspaceInfo: info,
                pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
            ),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-zero-tool-retry-visible", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("What changed?")

        await waitUntil {
            model.querySession.status == .completed && queryRunner.capturedPrompts.count == 2
        }

        XCTAssertEqual(queryRunner.capturedPrompts.count, 2)
        XCTAssertEqual(model.querySession.assistantText, "retry answer")
        XCTAssertEqual(model.querySession.claudeSessionID, "retry-session")
        XCTAssertEqual(model.queryHistory.first?.turns.map(\.answer), ["retry answer"])
    }

    func testLSOnlyAnswerRetriesBecauseItDoesNotSearchContent() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-ls-only-retry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let queryRunner = ScriptedQueryRunner(
            scripts: [
                [
                    .toolCall(name: "LS"),
                    .finished(
                        text: "directory-only answer",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "ls-session"
                    ),
                ],
                [
                    .toolCall(name: "Grep"),
                    .finished(
                        text: "content-searched answer",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "grep-session"
                    ),
                ],
            ]
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: FakeCompileRunner(
                workspaceInfo: info,
                pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
            ),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-ls-only-retry", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("Count all notes about TCP")

        await waitUntil {
            model.querySession.status == .completed && queryRunner.capturedPrompts.count == 2
        }

        XCTAssertEqual(queryRunner.capturedPrompts[0], "Count all notes about TCP")
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("did not use any research tools"))
        XCTAssertEqual(model.querySession.toolCalls, ["Grep"])
        XCTAssertEqual(model.querySession.assistantText, "content-searched answer")
    }

    func testRetryAfterResearchToolExitWithoutAnswerGetsFinalFreshAttempt() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-tool-output-exit-retry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let queryRunner = ScriptedQueryRunner(
            scripts: [
                [
                    .finished(
                        text: "not searched",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "no-tool-session"
                    ),
                ],
                [
                    .toolCall(name: "Bash"),
                    .toolResult(preview: "System design networking page"),
                    .failed(message: "Claude exited before producing an answer. The last stream output was incomplete or not valid JSON:")
                ],
                [
                    .toolCall(name: "Grep"),
                    .finished(
                        text: "final researched answer",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "final-session"
                    ),
                ],
            ]
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: FakeCompileRunner(
                workspaceInfo: info,
                pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
            ),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-tool-output-exit-retry", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("What's the difference between TCP and UDP?")

        await waitUntil {
            model.querySession.status == .completed && queryRunner.capturedPrompts.count == 3
        }

        XCTAssertEqual(queryRunner.capturedResumeSessionIDs, [nil, nil, nil])
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("did not use any research tools"))
        XCTAssertTrue(queryRunner.capturedPrompts[2].contains("exited before producing a final answer"))
        XCTAssertTrue(queryRunner.capturedPrompts[2].contains("What's the difference between TCP and UDP?"))
        XCTAssertEqual(model.querySession.status, .completed)
        XCTAssertEqual(model.querySession.assistantText, "final researched answer")
        XCTAssertEqual(model.queryHistory.first?.turns.map(\.answer), ["final researched answer"])
    }

    func testToolUsingAnswerDoesNotRetry() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-tool-no-retry", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let queryRunner = ScriptedQueryRunner(
            scripts: [
                [
                    .toolCall(name: "Bash"),
                    .finished(
                        text: "researched once",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "single-session"
                    ),
                ],
            ]
        )
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: FakeCompileRunner(
                workspaceInfo: info,
                pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
            ),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-tool-no-retry", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("Find all notes about GRPO")

        await waitUntil {
            model.querySession.status == .completed && queryRunner.capturedPrompts.count == 1
        }

        XCTAssertEqual(queryRunner.capturedPrompts, ["Find all notes about GRPO"])
        XCTAssertEqual(model.querySession.assistantText, "researched once")
    }

    func testFollowUpUsesClaudeSessionInsteadOfSerializedHistory() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-resumable-context", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let fakeRunner = FakeCompileRunner(
            workspaceInfo: info,
            pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
        )
        let queryRunner = CapturingQueryRunner()
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: fakeRunner,
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-resumable-context", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("What is the evaluation metric distinction?")

        await waitUntil {
            model.querySession.status == .completed && !queryRunner.capturedPrompts.isEmpty
        }

        model.sendFollowUp("What else matters?")

        await waitUntil {
            queryRunner.capturedPrompts.count == 2
                && model.querySession.turns.count == 2
        }

        XCTAssertEqual(queryRunner.capturedPrompts, [
            "What is the evaluation metric distinction?",
            "What else matters?",
        ])
        XCTAssertFalse(queryRunner.capturedPrompts[1].contains("<conversation-history>"))
        XCTAssertEqual(queryRunner.capturedResumeSessionIDs.count, 2)
        XCTAssertNil(queryRunner.capturedResumeSessionIDs[0])
        XCTAssertEqual(queryRunner.capturedResumeSessionIDs[1], "claude-session-captured")
    }

    func testFollowUpFromRestoredHistoryUsesPersistedClaudeSessionID() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-restored-resume", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let record = QueryHistoryRecord(
            turns: [QueryTurn(question: "Original question", answer: "Original answer")],
            claudeSessionID: "restored-claude-session"
        )
        try writeHistory([record], to: workspaceURL)

        let queryRunner = CapturingQueryRunner()
        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-restored-resume", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.selectHistorySession(record)
        model.sendFollowUp("Continue this")

        await waitUntil {
            queryRunner.capturedPrompts.count == 1
                && model.querySession.turns.count == 2
        }

        XCTAssertEqual(queryRunner.capturedPrompts, ["Continue this"])
        XCTAssertEqual(queryRunner.capturedResumeSessionIDs.count, 1)
        XCTAssertEqual(queryRunner.capturedResumeSessionIDs[0], "restored-claude-session")
    }

    func testFollowUpZeroToolAnswerRetriesWithPersistedClaudeSessionID() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-followup-zero-tool", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let record = QueryHistoryRecord(
            turns: [QueryTurn(question: "Original question", answer: "Original answer cited [[Planner]].")],
            claudeSessionID: "restored-claude-session"
        )
        try writeHistory([record], to: workspaceURL)

        let queryRunner = ScriptedQueryRunner(
            scripts: [
                [
                    .finished(
                        text: "follow-up without search",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "first-followup-session"
                    ),
                ],
                [
                    .toolCall(name: "Task"),
                    .finished(
                        text: "follow-up researched",
                        costUSD: nil,
                        durationMs: nil,
                        permissionDenials: [],
                        sessionID: "retry-followup-session"
                    ),
                ],
            ]
        )
        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-followup-zero-tool", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.selectHistorySession(record)
        model.sendFollowUp("Continue this")

        await waitUntil {
            model.querySession.status == .completed && queryRunner.capturedPrompts.count == 2
        }

        XCTAssertEqual(queryRunner.capturedResumeSessionIDs, [
            "restored-claude-session",
            nil,
        ])
        XCTAssertEqual(queryRunner.capturedPrompts[0], "Continue this")
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("did not use any research tools"))
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("Prior research covered: [[Planner]]."))
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("Continue this"))
        XCTAssertEqual(model.querySession.turns.map(\.answer), [
            "Original answer cited [[Planner]].",
            "follow-up researched",
        ])
    }

    func testFollowUpFromLegacyRestoredHistoryStartsFreshWithoutTranscript() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-restored-legacy", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let legacyRecord = QueryHistoryRecord(
            turns: [QueryTurn(question: "Legacy question", answer: "Legacy answer")]
        )
        try writeHistory([legacyRecord], to: workspaceURL)

        let queryRunner = CapturingQueryRunner()
        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-restored-legacy", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        let record = try XCTUnwrap(model.queryHistory.first)
        model.selectHistorySession(record)
        model.sendFollowUp("Continue without old tool context")

        await waitUntil {
            queryRunner.capturedPrompts.count == 1
                && model.querySession.turns.count == 2
        }

        XCTAssertEqual(queryRunner.capturedPrompts, ["Continue without old tool context"])
        XCTAssertFalse(queryRunner.capturedPrompts[0].contains("<conversation-history>"))
        XCTAssertEqual(queryRunner.capturedResumeSessionIDs.count, 1)
        XCTAssertNil(queryRunner.capturedResumeSessionIDs[0])
    }

    func testExpiredResumeSessionRetriesWithPriorResearchHint() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-expired-resume", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let record = QueryHistoryRecord(
            turns: [
                QueryTurn(
                    question: "What changed?",
                    answer: "The policy shifted because of [[Policy Timeline]] and [[Budget Memo]]."
                )
            ],
            claudeSessionID: "expired-session"
        )
        try writeHistory([record], to: workspaceURL)

        let queryRunner = ExpiringResumeQueryRunner()
        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: queryRunner,
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-expired-resume", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.selectHistorySession(record)
        model.sendFollowUp("What should I check next?")

        await waitUntil {
            queryRunner.capturedPrompts.count == 2
                && model.querySession.status == .completed
        }

        XCTAssertEqual(queryRunner.capturedResumeSessionIDs.count, 2)
        XCTAssertEqual(queryRunner.capturedResumeSessionIDs[0], "expired-session")
        XCTAssertNil(queryRunner.capturedResumeSessionIDs[1])
        XCTAssertEqual(queryRunner.capturedPrompts[0], "What should I check next?")
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("Prior research covered: [[Policy Timeline]], [[Budget Memo]]."))
        XCTAssertTrue(queryRunner.capturedPrompts[1].contains("What should I check next?"))
    }

    func testFollowUpFromRestoredHistoryUpdatesExistingRecord() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let firstTurn = QueryTurn(question: "Where did I put that paper?", answer: "In the planner.")
        let originalRecord = QueryHistoryRecord(id: UUID(), turns: [firstTurn])
        try writeHistory([originalRecord], to: workspaceURL)

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: SuccessfulQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-followup", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        XCTAssertEqual(model.queryHistory.count, 1)

        model.selectHistorySession(originalRecord)
        model.sendFollowUp("What else should I check?")

        await waitUntil {
            model.queryHistory.count == 1
                && model.queryHistory.first?.turns.count == 2
        }

        XCTAssertEqual(model.queryHistory.first?.id, originalRecord.id)
        XCTAssertEqual(model.queryHistory.first?.turns.map(\.question), [
            "Where did I put that paper?",
            "What else should I check?",
        ])

        let historyURL = workspaceURL.appending(path: ".compile/query-history.json", directoryHint: .notDirectory)
        let savedData = try Data(contentsOf: historyURL)
        let savedRecords = try JSONDecoder().decode([QueryHistoryRecord].self, from: savedData)
        XCTAssertEqual(savedRecords.count, 1)
        XCTAssertEqual(savedRecords.first?.id, originalRecord.id)
        XCTAssertEqual(savedRecords.first?.turns.count, 2)
    }

    func testSidebarHistoryKeepsSelectedHistoryRecordInPlace() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let activeRecord = QueryHistoryRecord(
            id: UUID(),
            turns: [QueryTurn(question: "Active question", answer: "Active answer")],
            archivedAt: Date(timeIntervalSince1970: 2_000)
        )
        let archivedRecord = QueryHistoryRecord(
            id: UUID(),
            turns: [QueryTurn(question: "Archived question", answer: "Archived answer")],
            archivedAt: Date(timeIntervalSince1970: 1_000)
        )
        try writeHistory([activeRecord, archivedRecord], to: workspaceURL)

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-sidebar", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.selectHistorySession(activeRecord)

        XCTAssertEqual(model.queryHistory.count, 2)
        XCTAssertEqual(model.sidebarQueryHistory.map(\.id), [activeRecord.id, archivedRecord.id])
        XCTAssertFalse(model.hasUnsavedActiveQuerySession)
    }

    func testSelectingHistorySessionDoesNotMovePreviousSelectionToTop() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-selection-order", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let olderRecord = QueryHistoryRecord(
            id: UUID(),
            turns: [QueryTurn(question: "Older question", answer: "Older answer")],
            archivedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newerRecord = QueryHistoryRecord(
            id: UUID(),
            turns: [QueryTurn(question: "Newer question", answer: "Newer answer")],
            archivedAt: Date(timeIntervalSince1970: 2_000)
        )
        try writeHistory([newerRecord, olderRecord], to: workspaceURL)

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-selection-order", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        XCTAssertEqual(model.queryHistory.map(\.id), [newerRecord.id, olderRecord.id])

        model.selectHistorySession(olderRecord)
        model.selectHistorySession(newerRecord)

        XCTAssertEqual(model.queryHistory.map(\.id), [newerRecord.id, olderRecord.id])
    }

    func testFollowUpFromSelectedHistorySessionMovesRecordToTop() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-followup-order", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let olderRecord = QueryHistoryRecord(
            id: UUID(),
            turns: [QueryTurn(question: "Older question", answer: "Older answer")],
            archivedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newerRecord = QueryHistoryRecord(
            id: UUID(),
            turns: [QueryTurn(question: "Newer question", answer: "Newer answer")],
            archivedAt: Date(timeIntervalSince1970: 2_000)
        )
        try writeHistory([newerRecord, olderRecord], to: workspaceURL)

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: SuccessfulQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-followup-order", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.selectHistorySession(olderRecord)
        model.sendFollowUp("What changed?")

        await waitUntil {
            model.queryHistory.first?.id == olderRecord.id
                && model.queryHistory.first?.turns.count == 2
        }

        XCTAssertEqual(model.queryHistory.map(\.id), [olderRecord.id, newerRecord.id])
    }

    func testDismissingSelectedHistorySessionRestoresArchivedRecordToSidebar() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let record = QueryHistoryRecord(id: UUID(), turns: [
            QueryTurn(question: "Archived question", answer: "Archived answer")
        ])
        try writeHistory([record], to: workspaceURL)

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-dismiss", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.selectHistorySession(record)
        XCTAssertEqual(model.sidebarQueryHistory.map(\.id), [record.id])
        XCTAssertFalse(model.hasUnsavedActiveQuerySession)

        model.dismissQueryResponse()

        XCTAssertFalse(model.hasActiveQuerySession)
        XCTAssertEqual(model.sidebarQueryHistory.map(\.id), [record.id])
    }

    func testHasActiveQuerySessionIsTrueForInFlightFirstQueryWithoutTurns() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let info = WorkspaceInfo(
            path: workspaceURL.path,
            topic: "Rhizome",
            description: "Test workspace",
            rawFiles: 0,
            processed: 0,
            unprocessed: 0,
            needsDocumentReview: 0,
            wikiPageCount: 1
        )
        let model = AppModel(
            runner: FakeCompileRunner(
                workspaceInfo: info,
                pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")
            ),
            dispatcher: NoopDispatcher(),
            queryRunner: DelayedQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-running", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.sendQuery("Still running?")

        await waitUntil {
            model.querySession.status == .running
        }

        XCTAssertTrue(model.hasActiveQuerySession)
        XCTAssertTrue(model.hasUnsavedActiveQuerySession)
        XCTAssertTrue(model.querySession.turns.isEmpty)

        model.cancelQuery()
    }

    func testSwitchingWorkspacesClearsHistoryWhenDestinationHasNoHistoryFile() async throws {
        let workspaceOneURL = tempDirectory.appending(path: "wiki-one", directoryHint: .isDirectory)
        let workspaceTwoURL = tempDirectory.appending(path: "wiki-two", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceOneURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceTwoURL, withIntermediateDirectories: true)
        defaults.set(workspaceOneURL.path, forKey: "currentWorkspacePath")

        let record = QueryHistoryRecord(turns: [
            QueryTurn(question: "First workspace question", answer: "First workspace answer")
        ])
        try writeHistory([record], to: workspaceOneURL)

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-workspaces", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        XCTAssertEqual(model.workspace?.path, workspaceOneURL.path)
        XCTAssertEqual(model.queryHistory.count, 1)

        model.selectRecentWorkspace(workspaceTwoURL.path)

        await waitUntil {
            model.workspace?.path == workspaceTwoURL.path
        }

        XCTAssertTrue(model.queryHistory.isEmpty)
        XCTAssertTrue(model.querySession.turns.isEmpty)
    }

    func testOpenObsidianGraphPromptsToInstallPluginWhenMissing() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-graph", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-graph-prompt", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened },
            isGraphPluginInstalledHandler: { _ in false }
        )

        await model.bootstrapIfNeeded()
        model.openObsidianGraph()

        XCTAssertTrue(model.showGraphPluginInstallPrompt)
        XCTAssertNil(model.lastError)
    }

    func testInstallGraphPluginOpensGraphWhenObsidianIsNotRunning() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-install", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let installCalled = expectation(description: "plugin installed")
        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-graph-install", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened },
            isGraphPluginInstalledHandler: { _ in false },
            installGraphPluginHandler: { _ in
                installCalled.fulfill()
            },
            isObsidianRunningHandler: { false }
        )

        await model.bootstrapIfNeeded()
        await model.installGraphPluginForCurrentWorkspace()

        await fulfillment(of: [installCalled], timeout: 1.0)
        XCTAssertEqual(model.launcherToast, "Installed Advanced URI and opened graph")
        XCTAssertFalse(model.isInstallingGraphPlugin)
        XCTAssertFalse(model.showGraphPluginInstallPrompt)
    }

    func testInstallGraphPluginRequestsRelaunchWhenObsidianAlreadyRunning() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-relaunch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let installCalled = expectation(description: "plugin installed")
        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-graph-relaunch", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened },
            isGraphPluginInstalledHandler: { _ in false },
            installGraphPluginHandler: { _ in
                installCalled.fulfill()
            },
            isObsidianRunningHandler: { true }
        )

        await model.bootstrapIfNeeded()
        await model.installGraphPluginForCurrentWorkspace()

        await fulfillment(of: [installCalled], timeout: 1.0)
        XCTAssertEqual(model.launcherToast, "Advanced URI installed. Relaunch Obsidian once, then use Graph.")
        XCTAssertFalse(model.isInstallingGraphPlugin)
    }

    func testInstallGraphPluginHandlesVaultRegistrationBootstrap() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-registration", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let installCalled = expectation(description: "plugin installed")
        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-graph-registration", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .openedVaultForRegistration },
            isGraphPluginInstalledHandler: { _ in false },
            installGraphPluginHandler: { _ in
                installCalled.fulfill()
            },
            isObsidianRunningHandler: { false }
        )

        await model.bootstrapIfNeeded()
        await model.installGraphPluginForCurrentWorkspace()

        await fulfillment(of: [installCalled], timeout: 1.0)
        XCTAssertEqual(
            model.launcherToast,
            "Installed Advanced URI and opened the vault. Click Graph again after Obsidian finishes loading."
        )
        XCTAssertNil(model.lastError)
    }

    func testOpenObsidianGraphPromptSuppressionIsScopedPerWorkspace() async throws {
        let workspaceOneURL = tempDirectory.appending(path: "wiki-one", directoryHint: .isDirectory)
        let workspaceTwoURL = tempDirectory.appending(path: "wiki-two", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceOneURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceTwoURL, withIntermediateDirectories: true)
        defaults.set(workspaceOneURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-graph-suppression", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .opened },
            openGraphHandler: { _ in .opened },
            isGraphPluginInstalledHandler: { _ in false }
        )

        await model.bootstrapIfNeeded()
        model.dismissGraphPluginInstallPrompt()

        model.selectRecentWorkspace(workspaceTwoURL.path)
        await waitUntil {
            model.workspace?.path == workspaceTwoURL.path
        }

        model.openObsidianGraph()

        XCTAssertTrue(model.showGraphPluginInstallPrompt)
        XCTAssertNil(model.lastError)
    }

    func testOpenWikiPageDirectPathSurfacesOpenNoteErrors() async throws {
        let workspaceURL = tempDirectory.appending(path: "wiki-direct", directoryHint: .isDirectory)
        let pageURL = workspaceURL
            .appending(path: "wiki/articles/planner.md", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: pageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Planner".write(to: pageURL, atomically: true, encoding: .utf8)
        defaults.set(workspaceURL.path, forKey: "currentWorkspacePath")

        let model = AppModel(
            runner: DynamicCompileRunner(pageResult: try makePage(title: "Planner", relativePath: "wiki/articles/planner.md")),
            dispatcher: NoopDispatcher(),
            queryRunner: NoopQueryRunner(),
            logger: AppLogger(logDirectory: tempDirectory.appending(path: "logs-open-note-error", directoryHint: .isDirectory)),
            defaults: defaults,
            fileManager: .default,
            openWorkspaceHandler: { _ in .opened },
            openNoteHandler: { _, _ in .notInstalled },
            openGraphHandler: { _ in .opened }
        )

        await model.bootstrapIfNeeded()
        model.openWikiPage(target: "wiki/articles/planner.md")

        XCTAssertEqual(model.lastError, "Obsidian is not installed. Install it from obsidian.md.")
    }
}
