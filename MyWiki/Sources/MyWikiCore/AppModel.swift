import AppKit
import Foundation
import Observation

public enum AppTheme: String, CaseIterable, Codable, Sendable {
    case ivory
    case obsidian
    case umber

    public var displayName: String {
        switch self {
        case .ivory: return "Ivory"
        case .obsidian: return "Obsidian"
        case .umber: return "Umber"
        }
    }

    public var prefersDarkMode: Bool {
        switch self {
        case .ivory: return false
        case .obsidian, .umber: return true
        }
    }
}

public enum AppFont: String, CaseIterable, Codable, Sendable {
    case serif
    case sans
    case mono

    public var displayName: String {
        switch self {
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .mono: return "Mono"
        }
    }
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var workspace: WorkspaceInfo?
    public private(set) var recentWorkspacePaths: [String] = []
    public let feedStore: FeedStore
    public private(set) var querySession = QuerySession()
    public private(set) var queryHistory: [QueryHistoryRecord] = []
    public var hasActiveQuerySession: Bool {
        querySession.status != .idle || !querySession.turns.isEmpty
    }
    public var sidebarQueryHistory: [QueryHistoryRecord] {
        queryHistory.filter { $0.id != querySession.id }
    }
    public var lastError: String?
    public var statusMessage = "Preparing workspace..."
    public var launcherToast: String?
    public var showGraphPluginInstallPrompt = false
    public private(set) var isInstallingGraphPlugin = false
    public var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: themeKey) }
    }
    public var font: AppFont {
        didSet { defaults.set(font.rawValue, forKey: fontKey) }
    }

    private let runner: CompileRunning
    private let dispatcher: IngestDispatcher
    private let queryRunner: ClaudeQueryRunning
    private let logger: AppLogger
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let openWorkspaceHandler: @MainActor (URL) -> ObsidianOpener.Result
    private let openNoteHandler: @MainActor (String, URL) -> ObsidianOpener.Result
    private let openGraphHandler: @MainActor (URL) -> ObsidianOpener.Result
    private let canOpenGraphDirectlyHandler: @MainActor (URL) -> Bool
    private let isGraphPluginInstalledHandler: @MainActor (URL) -> Bool
    private let installGraphPluginHandler: @MainActor (URL) async throws -> Void
    private let isObsidianRunningHandler: @MainActor () -> Bool
    private let defaultWorkspaceName = "Commonplace"
    private let recentKey = "recentWorkspacePaths"
    private let currentWorkspaceKey = "currentWorkspacePath"
    private let themeKey = "appTheme"
    private let fontKey = "appFont"
    private let graphPluginPromptSuppressedKeyPrefix = "graphPluginPromptSuppressed."
    private let maxQueryHistoryRecords = 50
    private var didBootstrap = false
    private var toastClearTask: Task<Void, Never>?
    private var activeQueryTask: Task<Void, Never>?

    public init(
        runner: CompileRunning? = nil,
        dispatcher: IngestDispatcher? = nil,
        queryRunner: ClaudeQueryRunning? = nil,
        logger: AppLogger = AppLogger(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        openWorkspaceHandler: @escaping @MainActor (URL) -> ObsidianOpener.Result = ObsidianOpener.openWorkspace,
        openNoteHandler: @escaping @MainActor (String, URL) -> ObsidianOpener.Result = ObsidianOpener.openNote,
        openGraphHandler: @escaping @MainActor (URL) -> ObsidianOpener.Result = ObsidianOpener.openGraph,
        canOpenGraphDirectlyHandler: @escaping @MainActor (URL) -> Bool = ObsidianOpener.canOpenGraphDirectly,
        isGraphPluginInstalledHandler: @escaping @MainActor (URL) -> Bool = {
            ObsidianAdvancedURIInstaller.isInstalledAndEnabled(in: $0)
        },
        installGraphPluginHandler: @escaping @MainActor (URL) async throws -> Void = {
            try await ObsidianAdvancedURIInstaller.installAndEnable(in: $0)
        },
        isObsidianRunningHandler: @escaping @MainActor () -> Bool = ObsidianOpener.isObsidianRunning
    ) {
        self.logger = logger
        let resolvedRunner = runner ?? CompileRunner(logger: logger)
        self.runner = resolvedRunner
        let resolvedDispatcher = dispatcher ?? TerminalClaudeDispatcher(logger: logger)
        self.dispatcher = resolvedDispatcher
        self.queryRunner = queryRunner ?? ClaudeQueryRunner(logger: logger)
        self.feedStore = FeedStore(dispatcher: resolvedDispatcher, logger: logger, defaults: defaults)
        self.defaults = defaults
        self.fileManager = fileManager
        self.openWorkspaceHandler = openWorkspaceHandler
        self.openNoteHandler = openNoteHandler
        self.openGraphHandler = openGraphHandler
        self.canOpenGraphDirectlyHandler = canOpenGraphDirectlyHandler
        self.isGraphPluginInstalledHandler = isGraphPluginInstalledHandler
        self.installGraphPluginHandler = installGraphPluginHandler
        self.isObsidianRunningHandler = isObsidianRunningHandler
        self.recentWorkspacePaths = defaults.stringArray(forKey: recentKey) ?? []
        self.theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .umber
        self.font = AppFont(rawValue: defaults.string(forKey: "appFont") ?? "") ?? .serif
    }

    public var isGraphPluginInstalled: Bool {
        guard let workspace else { return false }
        return isGraphPluginInstalledHandler(workspace.url)
    }

    public var canOpenGraphDirectly: Bool {
        guard let workspace else { return false }
        return canOpenGraphDirectlyHandler(workspace.url)
    }

    public func bootstrapIfNeeded() async {
        guard !didBootstrap else {
            return
        }
        didBootstrap = true
        await restoreOrCreateWorkspace()
    }

    // MARK: - Compose + dispatch

    /// Stage any dropped files and dispatch a draft Claude session. The prompt is
    /// composed from the dropped files (if any) and free-form text (if any) and
    /// lands on the clipboard — nothing is auto-submitted.
    public func launchDraftSession(files: [URL], text: String) {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !files.isEmpty || !trimmedText.isEmpty else {
            return
        }

        var requests: [IngestRequest] = []
        var remainingText = trimmedText
        if files.isEmpty {
            if let urlRequest = urlOnlyRequest(from: trimmedText) {
                requests.append(urlRequest)
                remainingText = ""
            } else {
                requests.append(IngestRequest(source: .query(trimmedText)))
                remainingText = ""
            }
        } else {
            for file in files {
                requests.append(IngestRequest(source: .file(file)))
            }
        }

        feedStore.enqueue(requests, trailingText: remainingText, workspaceURL: workspace.url)
        flashToast("Sent to Claude — check Terminal")
    }

    /// Run a plain-text question through `claude -p --output-format stream-json`
    /// and stream the answer into the popover via `querySession`. No Terminal window,
    /// no manual paste — the response appears in-app with tappable `[[wikilinks]]`.
    public func sendQuery(_ question: String) {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeQueryTask?.cancel()
        archiveSessionIfNeeded()
        querySession = QuerySession()
        querySession.start(question: trimmed)
        let feedItemID = feedStore.recordLocalQuery(trimmed)

        let workspaceURL = workspace.url
        let session = querySession
        let claudeRunner = queryRunner
        let log = logger

        activeQueryTask = Task { [weak self] in
            log.log("sendQuery: starting query — \"\(trimmed.prefix(60))\"")

            await MainActor.run { session.updateStatusDetail("Asking Claude…") }

            do {
                try await Self.runQueryWithResearchGuard(
                    prompt: trimmed,
                    workspaceURL: workspaceURL,
                    resumeSessionID: nil,
                    retryPrompt: {
                        Self.researchRequiredRetryPrompt(for: trimmed)
                    },
                    retryResumeSessionID: nil,
                    runner: claudeRunner,
                    logger: log,
                    logPrefix: "sendQuery",
                    onRetry: { detail in
                        await MainActor.run { session.updateStatusDetail(detail) }
                    },
                    onEvent: { event in
                        await MainActor.run {
                            Self.logQueryEvent(event, logger: log, prefix: "sendQuery")
                            if case .failed(let m) = event, let feedItemID {
                                self?.feedStore.markFailed(id: feedItemID, message: m)
                            }
                            session.handle(event)
                        }
                    }
                )
                await MainActor.run { [weak self] in
                    log.log("sendQuery: runQuery returned — status=\(session.status), text=\(session.assistantText.count) chars")
                    Self.finishCompletedClaudeRunIfNeeded(session, logger: log, context: "sendQuery")
                    if session.status == .failed, let feedItemID {
                        self?.feedStore.markFailed(id: feedItemID, message: session.errorMessage ?? "Query completed without a final response")
                    }
                    self?.saveCurrentSession()
                }
            } catch is CancellationError {
                await MainActor.run { session.cancel() }
            } catch {
                await MainActor.run {
                    session.fail(error.localizedDescription)
                    if let feedItemID {
                        self?.feedStore.markFailed(id: feedItemID, message: error.localizedDescription)
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.activeQueryTask = nil
            }
        }
    }

    public func cancelQuery() {
        activeQueryTask?.cancel()
        activeQueryTask = nil
        querySession.cancel()
    }

    public func dismissQueryResponse() {
        activeQueryTask?.cancel()
        activeQueryTask = nil
        querySession = QuerySession()
    }

    /// Send a follow-up question in the current Claude conversation when a
    /// session id is available; legacy text-only history starts a fresh agent context.
    public func sendFollowUp(_ question: String) {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeQueryTask?.cancel()
        querySession.startFollowUp(question: trimmed)

        let workspaceURL = workspace.url
        let session = querySession
        let claudeRunner = queryRunner
        let log = logger
        let resumeSessionID = session.claudeSessionID
        let priorTurns = session.turns

        activeQueryTask = Task { [weak self] in
            log.log("sendFollowUp: follow-up — \"\(trimmed.prefix(60))\"")
            if resumeSessionID == nil {
                log.log("sendFollowUp: no Claude session id available; starting a fresh agent context")
            }

            await MainActor.run { session.updateStatusDetail("Asking Claude…") }

            do {
                do {
                    try await Self.runQueryWithResearchGuard(
                        prompt: trimmed,
                        workspaceURL: workspaceURL,
                        resumeSessionID: resumeSessionID,
                        retryPrompt: {
                            let prompt: String
                            if priorTurns.isEmpty {
                                prompt = trimmed
                            } else {
                                prompt = Self.followUpPromptWithPriorResearchHint(
                                    question: trimmed,
                                    priorTurns: priorTurns
                                )
                            }
                            return Self.researchRequiredRetryPrompt(for: prompt)
                        },
                        retryResumeSessionID: nil,
                        runner: claudeRunner,
                        logger: log,
                        logPrefix: "sendFollowUp",
                        onRetry: { detail in
                            await MainActor.run { session.updateStatusDetail(detail) }
                        },
                        onEvent: { event in
                            await MainActor.run {
                                Self.logQueryEvent(event, logger: log, prefix: "sendFollowUp")
                                session.handle(event)
                            }
                        }
                    )
                } catch let resumeError as ClaudeQueryResumeUnavailableError where resumeSessionID != nil {
                    log.log("sendFollowUp: Claude resume failed — \(resumeError.message)")
                    await MainActor.run {
                        session.updateStatusDetail("Claude session expired; searching again…")
                    }
                    let fallbackPrompt = Self.followUpPromptWithPriorResearchHint(
                        question: trimmed,
                        priorTurns: priorTurns
                    )
                    try await Self.runQueryWithResearchGuard(
                        prompt: fallbackPrompt,
                        workspaceURL: workspaceURL,
                        resumeSessionID: nil,
                        retryPrompt: {
                            Self.researchRequiredRetryPrompt(for: fallbackPrompt)
                        },
                        retryResumeSessionID: nil,
                        runner: claudeRunner,
                        logger: log,
                        logPrefix: "sendFollowUp",
                        onRetry: { detail in
                            await MainActor.run { session.updateStatusDetail(detail) }
                        },
                        onEvent: { event in
                            await MainActor.run {
                                Self.logQueryEvent(event, logger: log, prefix: "sendFollowUp")
                                session.handle(event)
                            }
                        }
                    )
                }
                await MainActor.run { [weak self] in
                    Self.finishCompletedClaudeRunIfNeeded(session, logger: log, context: "sendFollowUp")
                    self?.saveCurrentSession()
                }
            } catch is CancellationError {
                await MainActor.run { session.cancel() }
            } catch {
                await MainActor.run {
                    session.fail(error.localizedDescription)
                }
            }
            await MainActor.run { [weak self] in
                self?.activeQueryTask = nil
            }
        }
    }

    nonisolated private static func followUpPromptWithPriorResearchHint(
        question: String,
        priorTurns: [QueryTurn]
    ) -> String {
        var seen: Set<String> = []
        var links: [String] = []
        for turn in priorTurns {
            for run in WikilinkParser.parse(turn.answer) {
                guard case .link(let target, _) = run else { continue }
                let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                links.append(trimmed)
            }
        }

        if !links.isEmpty {
            let cited = links.prefix(8).map { "[[\($0)]]" }.joined(separator: ", ")
            return "Prior research covered: \(cited).\n\n\(question)"
        }

        return """
        The previous Claude tool context is no longer available. Answer this follow-up from a fresh agentic wiki research pass.

        \(question)
        """
    }

    private static func logQueryEvent(_ event: ClaudeQueryEvent, logger: AppLogger, prefix: String) {
        switch event {
        case .assistantText(let text):
            logger.log("\(prefix): got assistantText (\(text.count) chars)")
        case .toolCall(let name):
            logger.log("\(prefix): got toolCall — \(name)")
        case .toolResult(let preview):
            logger.log("\(prefix): got toolResult (\(preview.count) chars)")
        case .finished(let text, let cost, _, _, let sessionID):
            logger.log("\(prefix): got finished — text=\(text.count) chars, cost=\(cost ?? -1)")
            if let sessionID {
                logger.log("\(prefix): Claude session id=\(sessionID)")
            }
        case .failed(let message):
            logger.log("\(prefix): got failed — \(message)")
        }
    }

    public func selectHistorySession(_ record: QueryHistoryRecord) {
        activeQueryTask?.cancel()
        activeQueryTask = nil
        archiveSessionIfNeeded()
        let session = QuerySession(id: record.id)
        session.restore(turns: record.turns, claudeSessionID: record.claudeSessionID)
        querySession = session
    }

    public func startNewQuery() {
        activeQueryTask?.cancel()
        activeQueryTask = nil
        archiveSessionIfNeeded()
        querySession = QuerySession()
    }

    /// Persist the current session into history immediately (called after each completed query).
    private func saveCurrentSession() {
        guard !querySession.turns.isEmpty else { return }
        upsertHistoryRecord(QueryHistoryRecord(
            id: querySession.id,
            turns: querySession.turns,
            claudeSessionID: querySession.claudeSessionID
        ))
    }

    private func archiveSessionIfNeeded() {
        guard !querySession.turns.isEmpty else { return }
        upsertHistoryRecord(QueryHistoryRecord(
            id: querySession.id,
            turns: querySession.turns,
            claudeSessionID: querySession.claudeSessionID
        ))
    }

    private var historyFileURL: URL? {
        workspace?.url.appending(path: ".compile/query-history.json", directoryHint: .notDirectory)
    }

    private func upsertHistoryRecord(_ record: QueryHistoryRecord) {
        queryHistory.removeAll { $0.id == record.id }
        queryHistory.insert(record, at: 0)
        queryHistory = normalizedHistory(queryHistory)
        saveHistory()
    }

    private static func finishCompletedClaudeRunIfNeeded(
        _ session: QuerySession,
        logger: AppLogger,
        context: String
    ) {
        guard session.status == .running else { return }
        logger.log("\(context): Claude runner returned without a terminal event")
        session.fail("Query completed without a final response")
    }

    nonisolated private static let researchToolNames: Set<String> = [
        "Bash",
        "Glob",
        "Grep",
        "Read",
        "Task",
        "WebFetch",
        "WebSearch",
    ]

    private struct ResearchAttemptOutcome: Sendable {
        let sawResearchTool: Bool
        let finishedWithoutResearch: Bool
        let retryableIncompleteAnswerFailureMessage: String?
    }

    private actor ResearchAttemptBuffer {
        private var bufferedEvents: [ClaudeQueryEvent] = []
        private var emittedBufferedEvents = false
        private var sawFinished = false
        private var sawResearchTool = false
        private var retryableIncompleteAnswerFailureMessage: String?

        func handle(
            _ event: ClaudeQueryEvent,
            emit: @Sendable (ClaudeQueryEvent) async -> Void
        ) async {
            if case .failed(let message) = event,
               AppModel.isRetryableIncompleteAnswerFailure(message) {
                retryableIncompleteAnswerFailureMessage = message
                return
            }

            if AppModel.isResearchToolCall(event) {
                sawResearchTool = true
            }

            if sawResearchTool {
                if !emittedBufferedEvents {
                    emittedBufferedEvents = true
                    let events = bufferedEvents
                    bufferedEvents.removeAll()
                    for event in events {
                        await emit(event)
                    }
                }
                await emit(event)
            } else {
                bufferedEvents.append(event)
            }

            if case .finished = event {
                sawFinished = true
            }
        }

        func finish(
            emit: @Sendable (ClaudeQueryEvent) async -> Void,
            discardFinishedWithoutResearch: Bool
        ) async -> ResearchAttemptOutcome {
            if !sawResearchTool && (!sawFinished || !discardFinishedWithoutResearch) {
                await flush(emit: emit)
            }
            return ResearchAttemptOutcome(
                sawResearchTool: sawResearchTool,
                finishedWithoutResearch: sawFinished && !sawResearchTool,
                retryableIncompleteAnswerFailureMessage: retryableIncompleteAnswerFailureMessage
            )
        }

        func flush(emit: @Sendable (ClaudeQueryEvent) async -> Void) async {
            guard !emittedBufferedEvents else { return }
            emittedBufferedEvents = true
            let events = bufferedEvents
            bufferedEvents.removeAll()
            for event in events {
                await emit(event)
            }
        }
    }

    private static func runQueryWithResearchGuard(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        retryPrompt: @escaping @Sendable () -> String,
        retryResumeSessionID: String?,
        runner: ClaudeQueryRunning,
        logger: AppLogger,
        logPrefix: String,
        onRetry: @escaping @Sendable (String) async -> Void,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        let firstAttempt = try await runBufferedQueryAttempt(
            prompt: prompt,
            workspaceURL: workspaceURL,
            resumeSessionID: resumeSessionID,
            runner: runner,
            discardFinishedWithoutResearch: true,
            onEvent: onEvent
        )
        if firstAttempt.finishedWithoutResearch {
            logger.log("\(logPrefix): Claude answered without research tools; retrying once")
            await onRetry("Retrying with wiki search required…")
            let retryPromptText = retryPrompt()
            let retryAttempt = try await runBufferedQueryAttempt(
                prompt: retryPromptText,
                workspaceURL: workspaceURL,
                resumeSessionID: retryResumeSessionID,
                runner: runner,
                discardFinishedWithoutResearch: false,
                onEvent: onEvent
            )
            guard retryAttempt.finishedWithoutResearch == false else { return }
            if let message = retryAttempt.retryableIncompleteAnswerFailureMessage {
                logger.log("\(logPrefix): Claude exited after research without an answer; retrying final answer once — \(message.prefix(160))")
                await onRetry("Retrying after interrupted tool output…")
                try await runner.runQuery(
                    prompt: Self.finalAnswerRequiredRetryPrompt(for: retryPromptText),
                    workspaceURL: workspaceURL,
                    resumeSessionID: nil,
                    onEvent: onEvent
                )
            }
            return
        }

        if let message = firstAttempt.retryableIncompleteAnswerFailureMessage {
            logger.log("\(logPrefix): Claude exited after research without an answer; retrying final answer once — \(message.prefix(160))")
            await onRetry("Retrying after interrupted tool output…")
            try await runner.runQuery(
                prompt: Self.finalAnswerRequiredRetryPrompt(for: prompt),
                workspaceURL: workspaceURL,
                resumeSessionID: nil,
                onEvent: onEvent
            )
        }
    }

    private static func runBufferedQueryAttempt(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        runner: ClaudeQueryRunning,
        discardFinishedWithoutResearch: Bool,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws -> ResearchAttemptOutcome {
        let buffer = ResearchAttemptBuffer()
        do {
            try await runner.runQuery(
                prompt: prompt,
                workspaceURL: workspaceURL,
                resumeSessionID: resumeSessionID,
                onEvent: { event in
                    await buffer.handle(event, emit: onEvent)
                }
            )
            return await buffer.finish(
                emit: onEvent,
                discardFinishedWithoutResearch: discardFinishedWithoutResearch
            )
        } catch {
            await buffer.flush(emit: onEvent)
            throw error
        }
    }

    nonisolated private static func isResearchToolCall(_ event: ClaudeQueryEvent) -> Bool {
        guard case .toolCall(let name) = event else { return false }
        return researchToolNames.contains(name)
    }

    nonisolated private static func isRetryableIncompleteAnswerFailure(_ message: String) -> Bool {
        message.contains("Claude exited before producing an answer")
            || message.contains("Claude exited after a tool result without producing an answer")
    }

    nonisolated private static func researchRequiredRetryPrompt(for prompt: String) -> String {
        """
        Your previous answer was discarded because it did not use any research tools. Retry the request below.

        Before answering, use at least one content research tool: Bash, Grep, Glob, Read, Task, WebSearch, or WebFetch. LS is allowed for navigation, but it does not count by itself. Search the local wiki first unless the request is explicitly about external or current information. Keep Bash output focused with search excerpts or bounded page reads instead of dumping long files unless the full text is essential. If you conclude the topic is not in the wiki, use both `compile obsidian search` and direct wiki/raw file search, then briefly state what you searched.

        Request:
        \(prompt)
        """
    }

    nonisolated private static func finalAnswerRequiredRetryPrompt(for prompt: String) -> String {
        """
        Your previous research run used tools but Claude Code exited before producing a final answer. Retry the request below.

        Use research tools as needed, keep Bash output focused with search excerpts or bounded page reads, and then produce the final answer. Search the local wiki first unless the request is explicitly about external or current information. If you conclude the topic is not in the wiki, use both `compile obsidian search` and direct wiki/raw file search, then briefly state what you searched.

        Request:
        \(prompt)
        """
    }

    private func normalizedHistory(_ records: [QueryHistoryRecord]) -> [QueryHistoryRecord] {
        var seenIDs: Set<UUID> = []
        let deduped = records
            .filter { !$0.turns.isEmpty }
            .sorted { $0.archivedAt > $1.archivedAt }
            .filter { seenIDs.insert($0.id).inserted }
        return Array(deduped.prefix(maxQueryHistoryRecords))
    }

    private func saveHistory() {
        guard let url = historyFileURL else { return }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let normalized = normalizedHistory(queryHistory)
            let data = try JSONEncoder().encode(normalized)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.log("Failed to save query history: \(error)")
        }
    }

    func loadHistory() {
        queryHistory = []
        guard let url = historyFileURL,
              fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([QueryHistoryRecord].self, from: data)
            queryHistory = normalizedHistory(decoded)
        } catch {
            logger.log("Failed to load query history: \(error)")
        }
    }

    /// Open a `[[wikilink]]` reference in Obsidian. Path-style targets open directly,
    /// and bare titles are first resolved through the sidecar so we can open the
    /// exact file path instead of relying on ambiguous vault-name routing.
    public func openWikiPage(target: String) {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        logger.log("openWikiPage: target=\"\(trimmed)\"")

        if trimmed.contains("/") || trimmed.hasSuffix(".md") {
            let relative = trimmed.hasSuffix(".md") ? trimmed : trimmed + ".md"
            let candidate = workspace.url
                .appending(path: relative, directoryHint: .notDirectory)
                .standardizedFileURL
            if fileManager.fileExists(atPath: candidate.path) {
                let result = openNoteHandler(relative, workspace.url)
                lastError = noteOpenErrorMessage(for: result, relativePath: relative)
                logger.log("openWikiPage: direct path opened relative=\(relative) result=\(String(describing: result))")
                return
            }
        }
        let workspaceURL = workspace.url
        let runner = self.runner
        let logger = self.logger
        let fallbackLocators = Self.fallbackWikiPageLocators(for: trimmed)
        Task { [weak self] in
            do {
                let page = try await runner.page(locator: trimmed, at: workspaceURL)
                await MainActor.run {
                    guard let self else { return }
                    let result = self.openNoteHandler(page.relativePath, workspaceURL)
                    self.lastError = self.noteOpenErrorMessage(for: result, relativePath: page.relativePath)
                    logger.log("openWikiPage: resolved target=\"\(trimmed)\" -> \(page.relativePath) result=\(String(describing: result))")
                }
            } catch {
                for fallbackLocator in fallbackLocators {
                    do {
                        let page = try await runner.page(locator: fallbackLocator, at: workspaceURL)
                        await MainActor.run {
                            guard let self else { return }
                            let result = self.openNoteHandler(page.relativePath, workspaceURL)
                            self.lastError = self.noteOpenErrorMessage(for: result, relativePath: page.relativePath)
                            logger.log("openWikiPage: resolved target=\"\(trimmed)\" via fallback=\"\(fallbackLocator)\" -> \(page.relativePath) result=\(String(describing: result))")
                        }
                        return
                    } catch {
                        logger.log("openWikiPage: fallback failed target=\"\(trimmed)\" fallback=\"\(fallbackLocator)\" error=\(error.localizedDescription)")
                    }
                }

                await MainActor.run {
                    self?.lastError = "Could not resolve wiki page '\(trimmed)': \(error.localizedDescription)"
                    logger.log("openWikiPage: failed target=\"\(trimmed)\" error=\(error.localizedDescription)")
                }
            }
        }
    }

    public func launchBareClaude() {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }
        do {
            try TerminalLauncher.launch(directory: workspace.url, runningCommand: "claude")
            flashToast("Claude launched in Terminal")
        } catch {
            logger.log("Failed to open terminal: \(error)")
            lastError = "Could not open Terminal: \(error.localizedDescription)"
        }
    }

    public func openWorkspaceInObsidian() {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }
        switch openWorkspaceHandler(workspace.url) {
        case .opened:
            flashToast("Opened in Obsidian")
        case .openedVaultForRegistration:
            flashToast("Opened vault in Obsidian")
        case .notInstalled:
            lastError = "Obsidian is not installed. Install it from obsidian.md."
        case .requiresAdvancedURI:
            lastError = "Obsidian graph support needs the Advanced URI plugin."
        case .vaultMissing:
            lastError = "The workspace folder no longer exists."
        case .failed(let message):
            lastError = "Obsidian refused to open: \(message)"
        }
    }

    public func openObsidianGraph() {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }
        let canOpenDirectly = canOpenGraphDirectlyHandler(workspace.url)
        let pluginInstalled = isGraphPluginInstalledHandler(workspace.url)
        logger.log(
            "openObsidianGraph: workspace=\(workspace.url.path) canOpenDirectly=\(canOpenDirectly) pluginInstalled=\(pluginInstalled)"
        )
        guard canOpenDirectly else {
            if defaults.bool(forKey: graphPluginPromptSuppressedKey(for: workspace.url)) {
                lastError = "Graph view needs the Advanced URI plugin. Open Settings to install it for this vault."
            } else {
                showGraphPluginInstallPrompt = true
            }
            return
        }
        let result = openGraphHandler(workspace.url)
        logger.log("openObsidianGraph: result=\(String(describing: result))")
        switch result {
        case .opened:
            flashToast("Opening graph in Obsidian")
        case .openedVaultForRegistration:
            flashToast("Opened vault in Obsidian. Click Graph again after it finishes loading.")
        case .notInstalled:
            lastError = "Obsidian is not installed. Install it from obsidian.md."
        case .requiresAdvancedURI:
            showGraphPluginInstallPrompt = true
        case .vaultMissing:
            lastError = "The workspace folder no longer exists."
        case .failed(let message):
            lastError = "Obsidian refused to open: \(message)"
        }
    }

    public func dismissGraphPluginInstallPrompt() {
        if let workspace {
            defaults.set(true, forKey: graphPluginPromptSuppressedKey(for: workspace.url))
        }
        showGraphPluginInstallPrompt = false
    }

    public func installGraphPluginForCurrentWorkspace() async {
        guard let workspace else {
            lastError = "Workspace is not ready yet."
            return
        }
        showGraphPluginInstallPrompt = false
        lastError = nil
        isInstallingGraphPlugin = true
        let workspaceURL = workspace.url
        let obsidianWasRunning = isObsidianRunningHandler()

        do {
            try await installGraphPluginHandler(workspaceURL)
            defaults.removeObject(forKey: graphPluginPromptSuppressedKey(for: workspaceURL))
            isInstallingGraphPlugin = false

            if obsidianWasRunning {
                flashToast("Advanced URI installed. Relaunch Obsidian once, then use Graph.")
                return
            }

            switch openGraphHandler(workspaceURL) {
            case .opened:
                flashToast("Installed Advanced URI and opened graph")
            case .openedVaultForRegistration:
                flashToast("Installed Advanced URI and opened the vault. Click Graph again after Obsidian finishes loading.")
            case .notInstalled:
                lastError = "Obsidian is not installed. Install it from obsidian.md."
            case .requiresAdvancedURI:
                lastError = "Advanced URI was installed, but Obsidian has not loaded it yet. Launch Obsidian once and try Graph again."
            case .vaultMissing:
                lastError = "The workspace folder no longer exists."
            case .failed(let message):
                lastError = "Installed Advanced URI, but Obsidian refused to open the graph: \(message)"
            }
        } catch {
            isInstallingGraphPlugin = false
            lastError = "Could not install Advanced URI: \(error.localizedDescription)"
        }
    }

    public func chooseFilesForIngest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Files"
        panel.message = "Choose files to hand off to Claude."
        panel.level = .modalPanel
        guard panel.runModal() == .OK else {
            return
        }
        launchDraftSession(files: panel.urls, text: "")
    }

    public func revealWorkspaceInFinder() {
        guard let workspace else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([workspace.url])
    }

    public func revealClaudeCommandsInFinder() {
        guard let workspace else {
            return
        }
        let commandsURL = workspace.url
            .appending(path: ".claude/commands", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: commandsURL.path) else {
            lastError = "No .claude/commands directory. Run `compile claude setup` on this workspace first."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([commandsURL])
    }

    public func refreshClaudeCommands() async {
        guard let workspace else {
            lastError = "No workspace is active."
            return
        }
        do {
            try await runner.prepareWorkspaceForClaude(at: workspace.url, force: true)
            flashToast("Updated Claude commands from the app bundle.")
        } catch {
            logger.log("Failed to refresh Claude commands: \(error)")
            lastError = "Could not update commands: \(error.localizedDescription)"
        }
    }

    public func openFeedItem(_ item: FeedItem) {
        guard let workspace, let relativePath = item.stagedRelativePath else {
            return
        }
        let fileURL = workspace.url
            .appending(path: relativePath, directoryHint: .notDirectory)
            .standardizedFileURL
        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastError = "The staged file no longer exists: \(relativePath)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    public func selectRecentWorkspace(_ path: String) {
        Task {
            await loadWorkspace(at: URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    public func chooseOtherWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Workspace"
        panel.message = "Choose an existing compile workspace."
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            await loadWorkspace(at: url)
        }
    }

    // MARK: - Workspace bootstrap

    private func restoreOrCreateWorkspace() async {
        if let storedPath = defaults.string(forKey: currentWorkspaceKey) {
            await loadWorkspace(at: URL(fileURLWithPath: storedPath, isDirectory: true), shouldFallbackToDefault: true)
            if workspace != nil {
                return
            }
        }
        await ensureDefaultWorkspace()
    }

    private func ensureDefaultWorkspace() async {
        let workspaceURL = defaultWorkspaceURL()
        do {
            if fileManager.fileExists(atPath: workspaceURL.appending(path: ".compile/config.yaml").path) {
                let info = try await runner.status(at: workspaceURL)
                try await runner.prepareWorkspaceForClaude(at: workspaceURL, force: false)
                setWorkspace(info)
            } else {
                let info = try await runner.initWorkspace(name: defaultWorkspaceName, at: workspaceURL)
                try await runner.prepareWorkspaceForClaude(at: workspaceURL, force: false)
                setWorkspace(info)
            }
            statusMessage = "Ready"
        } catch {
            logger.log("Failed to prepare default workspace: \(error)")
            lastError = "Failed to prepare workspace: \(error.localizedDescription)"
            statusMessage = "Workspace setup failed"
        }
    }

    private func loadWorkspace(at url: URL, shouldFallbackToDefault: Bool = false) async {
        do {
            let info = try await runner.status(at: url)
            try await runner.prepareWorkspaceForClaude(at: url, force: false)
            setWorkspace(info)
            statusMessage = "Ready"
        } catch {
            logger.log("Failed to load workspace at \(url.path): \(error)")
            lastError = "Could not open workspace: \(error.localizedDescription)"
            if shouldFallbackToDefault {
                await ensureDefaultWorkspace()
            }
        }
    }

    private func setWorkspace(_ info: WorkspaceInfo) {
        activeQueryTask?.cancel()
        activeQueryTask = nil
        workspace = info
        querySession = QuerySession()
        queryHistory = []
        showGraphPluginInstallPrompt = false
        isInstallingGraphPlugin = false
        statusMessage = "Ready"
        lastError = nil
        defaults.set(info.path, forKey: currentWorkspaceKey)
        rememberWorkspacePath(info.path)
        feedStore.bindWorkspace(info.url)
        loadHistory()
    }

    private func rememberWorkspacePath(_ path: String) {
        recentWorkspacePaths.removeAll { $0 == path }
        recentWorkspacePaths.insert(path, at: 0)
        recentWorkspacePaths = Array(recentWorkspacePaths.prefix(5))
        defaults.set(recentWorkspacePaths, forKey: recentKey)
    }

    private func defaultWorkspaceURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: "wiki", directoryHint: .isDirectory)
    }

    private func urlOnlyRequest(from text: String) -> IngestRequest? {
        guard text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") else {
            return nil
        }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == 1 else {
            return nil
        }
        return IngestRequest(source: .remoteURL(String(tokens[0])))
    }

    private func flashToast(_ message: String) {
        launcherToast = message
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    self?.launcherToast = nil
                }
            }
        }
    }

    private func graphPluginPromptSuppressedKey(for workspaceURL: URL) -> String {
        graphPluginPromptSuppressedKeyPrefix
            + workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func fallbackWikiPageLocators(for target: String) -> [String] {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let suffixes = [" (Notion)"]
        return suffixes.compactMap { suffix in
            guard lowercased.hasSuffix(suffix.lowercased()) else {
                return nil
            }
            let fallback = String(trimmed.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? nil : fallback
        }
    }

    private func noteOpenErrorMessage(
        for result: ObsidianOpener.Result,
        relativePath: String
    ) -> String? {
        switch result {
        case .opened:
            return nil
        case .openedVaultForRegistration:
            return "Opened the vault in Obsidian. Try opening \(relativePath) again once Obsidian finishes loading."
        case .notInstalled:
            return "Obsidian is not installed. Install it from obsidian.md."
        case .requiresAdvancedURI:
            return "Obsidian graph support needs the Advanced URI plugin."
        case .vaultMissing:
            return "The wiki page could not be found at \(relativePath)."
        case .failed(let message):
            return "Obsidian refused to open: \(message)"
        }
    }
}
