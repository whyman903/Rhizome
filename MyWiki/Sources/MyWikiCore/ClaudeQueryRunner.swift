import Foundation

public enum ClaudeQueryEvent: Sendable {
    case assistantText(String)
    case toolCall(name: String)
    case toolResult(preview: String)
    case finished(text: String, costUSD: Double?, durationMs: Int?, permissionDenials: [String], sessionID: String?)
    case failed(message: String)
}

public protocol ClaudeQueryRunning: AnyObject, Sendable {
    func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String?,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws
}

public struct ClaudeQueryResumeUnavailableError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public var errorDescription: String? {
        message
    }
}

public final class ClaudeQueryRunner: ClaudeQueryRunning, @unchecked Sendable {
    private let logger: AppLogger
    private let executableProvider: @Sendable () -> URL
    private let transcriptRootProvider: @Sendable () -> URL
    private let optionSupportLock = NSLock()
    private var optionSupportCache: [String: Bool] = [:]

    public init(
        logger: AppLogger,
        executableProvider: @escaping @Sendable () -> URL = ClaudeQueryRunner.defaultExecutable,
        transcriptRootProvider: @escaping @Sendable () -> URL = ClaudeQueryRunner.defaultTranscriptRoot
    ) {
        self.logger = logger
        self.executableProvider = executableProvider
        self.transcriptRootProvider = transcriptRootProvider
    }

    public static func defaultExecutable() -> URL {
        if let override = ProcessInfo.processInfo.environment["MYWIKI_CLAUDE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    public static func defaultTranscriptRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude", directoryHint: .isDirectory)
    }

    public static let wikiSystemPromptAddendum = """
        You are an agentic researcher working inside the user's personal Obsidian wiki workspace. \
        Query mode is answer-first and wiki-first. You may save, render, or update the wiki only \
        when the user explicitly asks for an artifact or confirms a follow-up save/integration \
        action. "Build/make/render/create me a deck/chart/canvas" is explicit consent to create \
        and save that artifact immediately; after rendering, report the created wiki path and do \
        not ask whether to save it again. Full Bash is trusted for wiki research and confirmed \
        compile-based writes. Use Bash, Task subagents, Grep, Glob, LS, Read, \
        WebSearch, and WebFetch when useful. Prefer the wiki first, then fill gaps from \
        web-backed or general knowledge with clear labels. \
        Use `compile obsidian search`, `compile obsidian page`, and `compile obsidian neighbors` \
        through Bash for semantic wiki discovery and page reads; if the global `compile` command \
        is unavailable, use `uv run compile ...`. Prefer Read, Glob, and Grep for file inspection; \
        reserve Bash mainly for `compile` commands and broad aggregation shell commands. Use `rg`, \
        `find`, `stat`, `wc`, and focused shell inspection to enumerate local files, count matches, \
        inspect recent uploads, and follow raw source paths. Keep shell output focused: prefer \
        `rg -n -C`, `head`, `sed -n`, `wc`, targeted `compile obsidian search`, and bounded page \
        excerpts over dumping entire long files unless the full text is necessary. \
        Source notes in `wiki/sources/` contain a short synopsis plus a collapsed \
        `> [!abstract]- Full extracted text` callout holding the extracted content of \
        the underlying raw file (PDF, Notion page, fetched URL, etc.). The callout is \
        usually faithful but not guaranteed complete — some extraction paths drop \
        fenced code, images, or embeds. Always Grep inside those callouts — not just \
        the synopsis — before concluding a topic isn't in the wiki, and if a source \
        note is thin, the callout is missing, or the hit looks truncated, fall back \
        to Grep and Read over `raw/` (including `raw/notion/` UUID-named files) \
        before answering from general knowledge. For backlink search, Grep the \
        escaped pattern `\\[\\[Page Title\\]\\]`.

        Classify the request before researching:
        - Brief/casual lookup or callback ("what's the deal", "remind me", "couple sentences") gets a concise answer and no save offer.
        - Synthesis across wiki sources should answer, then offer to fold it into the best existing article/map when one exists.
        - Audit, status review, or duplicate cleanup should offer the concrete fix, not an output page.
        - Drafting or wording requests should offer iteration first, persistence second.
        - Explicit artifact requests should render/save immediately with `compile render ...` and report the path.
        - Ordinary durable answers with no existing anchor may offer a new output page only if reusable.

        Prefer useful, rich Markdown over a plain paragraph when the query calls for it:
        - Use short sections when the answer has multiple parts.
        - Use markdown tables for comparisons, tradeoffs, timelines, or grouped evidence.
        - Use Mermaid diagrams for compact process flows, causal chains, or relationship maps.
        - Use Obsidian callouts for notable caveats, open questions, or recommendations when they add clarity.
        - Use LaTeX math notation, not Unicode math symbols.

        Use the right research pattern for the request:
        - For "explain the difference between X and Y", search each term and likely aliases, then compare the best wiki evidence.
        - For "how many notes", "find them all", inventory, count, list-all, or duplicate queries, start with a broad aggregation pass such as `rg -l`, `grep -rl`, `grep -rh "^sources:"`, `find`, or `wc`; dedupe matching wiki paths, define the inclusion rule, then inspect candidates.
        - For quote, verbatim, or "in their own words" queries, read the source note and raw source early when available; do not rely only on extracted snippets for exact wording.
        - For source-accounting queries ("which sources support which moves"), read every named source note that exists; if you rely on a synthesis page instead, say so.
        - For recent uploads or fuzzy memory such as "a paper from last week about GRPO", inspect file metadata and source/raw paths with `stat`, `find`, `rg`, and wiki search.
        - For broad/deep questions, use Task subagents to parallelize independent searches or source-reading passes.
        - Before saying a topic is not in the wiki, run both `compile obsidian search` and direct `rg`/file search across `wiki/` and `raw/` for exact phrases, acronyms, expansions, and likely aliases. Briefly state what you searched.
        - For modern technical/current topics not covered by the wiki, use WebSearch/WebFetch when current external grounding would materially improve the answer. If you do not search the web, avoid current-state claims.
        - Keep searches bounded: after a broad pass plus about five targeted searches, answer with gathered evidence and offer to dig further if useful.
        - Do not use todo or planning tools for query answers.

        Always answer the user's question. Search the wiki first and prefer wiki-grounded \
        answers: when the wiki covers a claim, cite it inline with an Obsidian [[Page Title]] \
        wikilink to the page you read it from, for example: The policy shift was driven by X \
        ([[Policy Timeline]]). When the wiki partially covers the question, use the wiki for \
        what it supports and answer the rest from web search or general knowledge. Make clear \
        which claims are wiki-backed (with `[[wikilinks]]`), which are web-backed, and which are \
        general knowledge. When the wiki does not cover the question at all, answer from web-backed \
        or general knowledge and note upfront that the topic is not in your wiki. \
        Use WebSearch/WebFetch when the user asks for current or external information, or when \
        the wiki is insufficient and current external grounding would materially improve the answer. \
        Do not refuse to answer a question just because it is not in the wiki. Do not say \
        you cannot answer because of your role, because the topic is outside the wiki, or \
        because of a knowledge cutoff unless the user explicitly asks about freshness or a \
        time-sensitive fact. Do not claim to save files, render artifacts, or update the wiki \
        unless the relevant command succeeded. Do not use Edit, Write, MultiEdit, or NotebookEdit; \
        use the `compile` CLI for confirmed wiki writes.
        """

    public func runQuery(
        prompt: String,
        workspaceURL: URL,
        resumeSessionID: String? = nil,
        onEvent: @escaping @Sendable (ClaudeQueryEvent) async -> Void
    ) async throws {
        let queryStart = Date()
        logger.log("ClaudeQueryRunner: query starting")
        let executable = executableProvider()
        let process = Process()
        process.executableURL = executable
        var claudeArgs = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--allowedTools", "Read,Grep,Glob,LS,Bash,Task,WebSearch,WebFetch",
            "--disallowedTools", "AskUserQuestion,Monitor,Edit,Write,NotebookEdit,MultiEdit",
            "--model", "sonnet",
            "--append-system-prompt", Self.wikiSystemPromptAddendum,
            prompt,
        ]
        if executableSupportsOption(executable, option: "--exclude-dynamic-system-prompt-sections") {
            let insertIndex = claudeArgs.firstIndex(of: "--append-system-prompt") ?? max(claudeArgs.count - 1, 0)
            claudeArgs.insert("--exclude-dynamic-system-prompt-sections", at: insertIndex)
        }
        if let resumeSessionID, !resumeSessionID.isEmpty {
            claudeArgs.insert(contentsOf: ["--resume", resumeSessionID], at: 1)
        }
        if executable.lastPathComponent == "env" {
            process.arguments = ["claude"] + claudeArgs
        } else {
            process.arguments = claudeArgs
        }
        process.currentDirectoryURL = workspaceURL

        var env = ProcessInfo.processInfo.environment
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [
            workspaceURL.path + "/.compile/mywiki-bin",
            "\(homePath)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existingPath,
        ].joined(separator: ":")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task { [logger] () -> StdoutSummary in
            var summary = StdoutSummary()
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    guard !line.isEmpty else { continue }
                    let result = await Self.parseStreamLine(line: line, logger: logger, onEvent: onEvent)
                    switch result {
                    case .parsed(let lineSummary):
                        summary.sawAssistantText = summary.sawAssistantText || lineSummary.emittedAssistantText
                        summary.sawFinished = summary.sawFinished || lineSummary.emittedFinished
                        if let sessionID = lineSummary.sessionID, !sessionID.isEmpty {
                            summary.sessionID = sessionID
                        }
                        if let text = lineSummary.textOnlyAssistantText {
                            summary.lastTextOnlyAssistantText = text
                        }
                        if let preview = lineSummary.toolResultPreview {
                            summary.lastToolResultPreview = preview
                        }
                    case .unparsed:
                        summary.appendUnparsedLine(line)
                    }
                }
            } catch {
                logger.log("ClaudeQueryRunner stdout read error: \(error)")
            }
            return summary
        }

        let stderrTask = Task { [logger] () -> String in
            var buffer = Data()
            do {
                for try await byte in stderrPipe.fileHandleForReading.bytes {
                    buffer.append(byte)
                    if buffer.count > 32 * 1024 {
                        buffer.removeFirst(buffer.count - 32 * 1024)
                    }
                }
            } catch {
                logger.log("ClaudeQueryRunner stderr read error: \(error)")
            }
            return String(decoding: buffer, as: UTF8.self)
        }

        try await withTaskCancellationHandler {
            try await Self.runProcess(process)
        } onCancel: { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let stdoutSummary = await stdoutTask.value
        let stdoutTail = stdoutSummary.unparsedTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrTail = await stderrTask.value.trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            let message: String
            if !stderrTail.isEmpty {
                message = stderrTail
            } else if !stdoutTail.isEmpty {
                message = stdoutTail
            } else {
                message = "claude -p exited with code \(process.terminationStatus)"
            }
            logger.log("ClaudeQueryRunner failure: \(message)")
            if resumeSessionID != nil, Self.isResumeSessionUnavailable(message) {
                throw ClaudeQueryResumeUnavailableError(message: message)
            }
            await onEvent(.failed(message: message))
        } else if !stdoutSummary.sawFinished {
            if let recovered = await Self.recoverTranscriptAnswer(
                sessionID: stdoutSummary.sessionID,
                workspaceURL: workspaceURL,
                transcriptRoot: transcriptRootProvider(),
                logger: logger
            ) {
                logger.log("ClaudeQueryRunner recovered final answer from Claude transcript for session \(recovered.sessionID)")
                await onEvent(.assistantText(recovered.text))
                await onEvent(.finished(
                    text: recovered.text,
                    costUSD: nil,
                    durationMs: nil,
                    permissionDenials: [],
                    sessionID: recovered.sessionID
                ))
            } else if let recoveredText = Self.recoverAssistantText(fromUnparsedTail: stdoutTail) {
                logger.log("ClaudeQueryRunner recovered final assistant text from incomplete stream JSON")
                await onEvent(.assistantText(recoveredText))
                await onEvent(.finished(
                    text: recoveredText,
                    costUSD: nil,
                    durationMs: nil,
                    permissionDenials: [],
                    sessionID: nil
                ))
            } else if let text = stdoutSummary.lastTextOnlyAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      stdoutTail.isEmpty {
                logger.log("ClaudeQueryRunner: result event missing; completing from final text-only assistant message")
                await onEvent(.finished(
                    text: text,
                    costUSD: nil,
                    durationMs: nil,
                    permissionDenials: [],
                    sessionID: nil
                ))
            } else {
                let message = Self.emptySuccessfulRunMessage(
                    stdoutSummary: stdoutSummary,
                    stderrTail: stderrTail
                )
                logger.log("ClaudeQueryRunner empty response: \(message)")
                await onEvent(.failed(message: message))
            }
        } else if !stdoutTail.isEmpty {
            logger.log("ClaudeQueryRunner stdout (ignored): \(stdoutTail)")
        } else if !stderrTail.isEmpty {
            logger.log("ClaudeQueryRunner stderr (ignored): \(stderrTail)")
        }
        let elapsed = Date().timeIntervalSince(queryStart)
        let reasonLabel: String
        switch process.terminationReason {
        case .exit: reasonLabel = "exit"
        case .uncaughtSignal: reasonLabel = "uncaughtSignal"
        @unknown default: reasonLabel = "unknown"
        }
        logger.log("ClaudeQueryRunner: query finished in \(String(format: "%.1f", elapsed))s (exit \(process.terminationStatus), reason \(reasonLabel))")
    }

    private static func runProcess(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func executableSupportsOption(_ executable: URL, option: String) -> Bool {
        let cacheKey = "\(executable.path)\u{0}\(option)"
        optionSupportLock.lock()
        if let cached = optionSupportCache[cacheKey] {
            optionSupportLock.unlock()
            return cached
        }
        optionSupportLock.unlock()

        let process = Process()
        process.executableURL = executable
        process.arguments = executable.lastPathComponent == "env"
            ? ["claude", "--help"]
            : ["--help"]

        // Match the PATH augmentation `runQuery` applies so GUI launches — which
        // normally inherit only `/usr/bin:/bin:/usr/sbin:/sbin` from launchd —
        // can still locate `claude` via `/usr/bin/env`.
        var env = ProcessInfo.processInfo.environment
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = [
            "\(homePath)/.claude/local",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            existingPath,
        ].joined(separator: ":")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let result: Bool
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            result = String(decoding: data, as: UTF8.self).contains(option)
        } catch {
            result = false
        }

        optionSupportLock.lock()
        optionSupportCache[cacheKey] = result
        optionSupportLock.unlock()
        return result
    }

    private struct StdoutSummary: Sendable {
        var unparsedBuffer = Data()
        var sawAssistantText = false
        var sawFinished = false
        var sessionID: String?
        var lastTextOnlyAssistantText: String?
        var lastToolResultPreview: String?

        var unparsedTail: String {
            String(decoding: unparsedBuffer, as: UTF8.self)
        }

        mutating func appendUnparsedLine(_ line: String) {
            unparsedBuffer.append(contentsOf: line.utf8)
            unparsedBuffer.append(0x0A)
            if unparsedBuffer.count > Self.maxUnparsedBufferBytes {
                unparsedBuffer.removeFirst(unparsedBuffer.count - Self.maxUnparsedBufferBytes)
            }
        }

        private static let maxUnparsedBufferBytes = 512 * 1024
    }

    private struct StreamLineSummary: Sendable {
        var emittedAssistantText = false
        var emittedFinished = false
        var sessionID: String?
        var textOnlyAssistantText: String?
        var toolResultPreview: String?
    }

    private enum StreamLineParseResult: Sendable {
        case parsed(StreamLineSummary)
        case unparsed
    }

    private static func parseStreamLine(
        line: String,
        logger: AppLogger,
        onEvent: @Sendable (ClaudeQueryEvent) async -> Void
    ) async -> StreamLineParseResult {
        guard let data = line.data(using: .utf8) else { return .unparsed }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let json = any as? [String: Any],
              let type = json["type"] as? String else {
            return .unparsed
        }
        var summary = StreamLineSummary()
        summary.sessionID = json["session_id"] as? String
        switch type {
        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return .parsed(summary)
            }
            let texts = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            let toolNames = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "tool_use" else { return nil }
                return block["name"] as? String
            }
            let joined = texts.joined()
            if !joined.isEmpty && toolNames.isEmpty {
                await onEvent(.assistantText(joined))
                summary.emittedAssistantText = true
                summary.textOnlyAssistantText = joined
            }
            for name in toolNames {
                await onEvent(.toolCall(name: name))
            }
        case "user":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return .parsed(summary)
            }
            for block in content {
                guard (block["type"] as? String) == "tool_result" else { continue }
                if let textContent = block["content"] as? String {
                    let preview = String(textContent.prefix(200))
                    summary.toolResultPreview = preview
                    await onEvent(.toolResult(preview: preview))
                } else if let blocks = block["content"] as? [[String: Any]] {
                    let combined = blocks.compactMap { $0["text"] as? String }.joined()
                    if !combined.isEmpty {
                        let preview = String(combined.prefix(200))
                        summary.toolResultPreview = preview
                        await onEvent(.toolResult(preview: preview))
                    }
                }
            }
        case "result":
            let text = (json["result"] as? String) ?? ""
            let cost = json["total_cost_usd"] as? Double
            let duration = json["duration_ms"] as? Int
            logger.log("ClaudeQueryRunner result: text=\(text.prefix(80))… cost=\(cost ?? -1) duration=\(duration ?? -1)")
            let sessionID = json["session_id"] as? String
            var denials: [String] = []
            if let array = json["permission_denials"] as? [[String: Any]] {
                for item in array {
                    if let tool = item["tool"] as? String {
                        denials.append(tool)
                    } else if let name = item["name"] as? String {
                        denials.append(name)
                    }
                }
            }
            await onEvent(.finished(
                text: text,
                costUSD: cost,
                durationMs: duration,
                permissionDenials: denials,
                sessionID: sessionID
            ))
            summary.emittedFinished = true
        case "system", "rate_limit_event":
            break
        default:
            logger.log("ClaudeQueryRunner unknown event: \(type)")
        }
        return .parsed(summary)
    }

    private static func recoverAssistantText(fromUnparsedTail tail: String) -> String? {
        let candidates = tail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                let line = String(rawLine)
                guard line.contains(#""type":"assistant""#),
                      !line.contains(#""type":"tool_use""#) else {
                    return nil
                }
                return recoverTextBlocks(fromPartialAssistantLine: line)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        return candidates.last
    }

    private static func recoverTextBlocks(fromPartialAssistantLine line: String) -> String? {
        var texts: [String] = []
        var cursor = line.startIndex
        let typeMarker = #""type":"text""#
        let textKey = #""text""#

        while let typeRange = line.range(of: typeMarker, range: cursor..<line.endIndex) {
            guard let textKeyRange = line.range(of: textKey, range: typeRange.upperBound..<line.endIndex),
                  let colon = line[textKeyRange.upperBound..<line.endIndex].firstIndex(of: ":"),
                  let quote = line[line.index(after: colon)..<line.endIndex].firstIndex(of: "\""),
                  let parsed = parseJSONStringLiteral(in: line, startingAt: quote) else {
                break
            }
            texts.append(parsed.value)
            cursor = parsed.end
        }

        guard !texts.isEmpty else {
            return nil
        }
        return texts.joined()
    }

    private static func parseJSONStringLiteral(
        in text: String,
        startingAt start: String.Index
    ) -> (value: String, end: String.Index)? {
        guard start < text.endIndex, text[start] == "\"" else {
            return nil
        }

        var index = text.index(after: start)
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                let literal = String(text[start...index])
                guard let data = literal.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                    return nil
                }
                return (decoded, text.index(after: index))
            }
            index = text.index(after: index)
        }

        return nil
    }

    private struct TranscriptRecovery: Sendable {
        let text: String
        let sessionID: String
    }

    private static func recoverTranscriptAnswer(
        sessionID: String?,
        workspaceURL: URL,
        transcriptRoot: URL,
        logger: AppLogger
    ) async -> TranscriptRecovery? {
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }

        let transcriptURL = transcriptURL(
            sessionID: sessionID,
            workspaceURL: workspaceURL,
            transcriptRoot: transcriptRoot
        )

        for attempt in 0..<5 {
            if let text = readFinalAssistantTextAfterLatestToolResult(from: transcriptURL) {
                return TranscriptRecovery(text: text, sessionID: sessionID)
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        logger.log("ClaudeQueryRunner transcript recovery found no final answer at \(transcriptURL.path)")
        return nil
    }

    private static func transcriptURL(
        sessionID: String,
        workspaceURL: URL,
        transcriptRoot: URL
    ) -> URL {
        let projectName = workspaceURL.standardizedFileURL.path
            .replacingOccurrences(of: "/", with: "-")
        return transcriptRoot
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: projectName, directoryHint: .isDirectory)
            .appending(path: "\(sessionID).jsonl", directoryHint: .notDirectory)
    }

    private static func readFinalAssistantTextAfterLatestToolResult(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }

        var answerAfterLatestTool: String?
        var sawToolResult = false

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: lineData),
                  let json = any as? [String: Any],
                  let type = json["type"] as? String,
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            if type == "user", content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                sawToolResult = true
                answerAfterLatestTool = nil
                continue
            }

            guard type == "assistant" else {
                continue
            }

            if content.contains(where: { ($0["type"] as? String) == "tool_use" }) {
                answerAfterLatestTool = nil
                continue
            }

            let text = content
                .compactMap { block -> String? in
                    guard (block["type"] as? String) == "text" else { return nil }
                    return block["text"] as? String
                }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if sawToolResult, !text.isEmpty {
                answerAfterLatestTool = text
            }
        }

        return answerAfterLatestTool
    }

    private static func emptySuccessfulRunMessage(
        stdoutSummary: StdoutSummary,
        stderrTail: String
    ) -> String {
        let stdoutTail = stdoutSummary.unparsedTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeTruncatedUserToolResult(stdoutTail) {
            var message = "Claude exited before producing an answer. The stream was cut off mid-tool-result — this is usually a transient Claude CLI error, please retry."
            if !stderrTail.isEmpty {
                message += "\n\nstderr:\n\(diagnosticPreview(stderrTail))"
            }
            return message
        }
        if !stdoutTail.isEmpty {
            return """
            Claude exited before producing an answer. The last stream output was incomplete or not valid JSON:

            \(diagnosticPreview(stdoutTail))
            """
        }
        if let preview = stdoutSummary.lastToolResultPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preview.isEmpty {
            return """
            Claude exited after a tool result without producing an answer. Last tool output:

            \(diagnosticPreview(preview))
            """
        }
        if !stderrTail.isEmpty {
            return """
            Claude exited before producing an answer. stderr:

            \(diagnosticPreview(stderrTail))
            """
        }
        return "Claude exited before producing an answer."
    }

    private static func looksLikeTruncatedUserToolResult(_ tail: String) -> Bool {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lastLine = trimmed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        guard lastLine.hasPrefix(#"{"type":"user""#) else { return false }
        guard lastLine.contains(#""tool_result""#) else { return false }
        guard let data = lastLine.data(using: .utf8) else { return true }
        return (try? JSONSerialization.jsonObject(with: data)) == nil
    }

    private static func diagnosticPreview(_ text: String, limit: Int = 800) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "\n..."
    }

    private static func isResumeSessionUnavailable(_ message: String) -> Bool {
        let normalized = message.lowercased()
        guard normalized.contains("session") || normalized.contains("conversation") else {
            return false
        }
        return normalized.contains("not found")
            || normalized.contains("no conversation")
            || normalized.contains("could not find")
            || normalized.contains("cannot find")
            || normalized.contains("does not exist")
            || normalized.contains("expired")
            || normalized.contains("no such")
            || normalized.contains("unavailable")
    }
}
