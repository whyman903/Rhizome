import Foundation

/// Thin RPC layer around `compile watch ...`. Exposes async methods that decode
/// the sidecar's JSON envelopes into ``WatchRecord``. Mirrors ``CompileRunner``'s
/// envelope-based pattern.
public protocol WatchSidecarRunning: AnyObject, Sendable {
    func list(at workspace: URL) async throws -> [WatchRecord]
    func add(
        url: String,
        frequency: String,
        intent: String,
        title: String?,
        at workspace: URL
    ) async throws -> WatchRecord
    func pause(_ locator: String, at workspace: URL) async throws -> WatchRecord
    func resume(_ locator: String, at workspace: URL) async throws -> WatchRecord
    func remove(_ locator: String, keepPage: Bool, at workspace: URL) async throws
    func runOnce(
        _ locator: String,
        force: Bool,
        at workspace: URL
    ) async throws -> WatchTickEvent
    func tick(at workspace: URL) async throws -> [WatchTickEvent]
}

private struct WatchListEnvelope: Decodable {
    let ok: Bool
    let watches: [WatchRecord]?
    let error: String?
}

private struct WatchEnvelope: Decodable {
    let ok: Bool
    let watch: WatchRecord?
    let error: String?
}

private struct WatchTickStreamLine: Decodable {
    let event: WatchTickEvent
}

private struct WatchTickSummary: Decodable {
    let ok: Bool
    let count: Int
    let events: [WatchTickEvent]
}

private struct WatchRunEnvelope: Decodable {
    let ok: Bool
    let event: WatchTickEvent?
    let error: String?
}

public final class WatchSidecar: WatchSidecarRunning, @unchecked Sendable {
    private let sidecarURLProvider: @Sendable () throws -> URL
    private let logger: AppLogger
    private let decoder = JSONDecoder()

    public init(
        logger: AppLogger,
        sidecarURLProvider: @escaping @Sendable () throws -> URL = SidecarLocator.defaultURL
    ) {
        self.logger = logger
        self.sidecarURLProvider = sidecarURLProvider
    }

    public func list(at workspace: URL) async throws -> [WatchRecord] {
        let envelope: WatchListEnvelope = try await runEnvelope(
            arguments: ["watch", "list", "--path", workspace.path, "--json-output"]
        )
        guard envelope.ok else {
            throw CompileCommandError(envelope.error ?? "compile-bin watch list failed.")
        }
        return envelope.watches ?? []
    }

    public func add(
        url: String,
        frequency: String,
        intent: String,
        title: String?,
        at workspace: URL
    ) async throws -> WatchRecord {
        var arguments: [String] = [
            "watch", "add", url,
            "--frequency", frequency,
            "--intent", intent,
            "--path", workspace.path,
            "--json-output",
        ]
        if let title, !title.isEmpty {
            arguments.append(contentsOf: ["--title", title])
        }
        return try await decodeWatchEnvelope(arguments: arguments)
    }

    public func pause(_ locator: String, at workspace: URL) async throws -> WatchRecord {
        try await decodeWatchEnvelope(
            arguments: ["watch", "pause", locator, "--path", workspace.path, "--json-output"]
        )
    }

    public func resume(_ locator: String, at workspace: URL) async throws -> WatchRecord {
        try await decodeWatchEnvelope(
            arguments: ["watch", "resume", locator, "--path", workspace.path, "--json-output"]
        )
    }

    public func remove(_ locator: String, keepPage: Bool, at workspace: URL) async throws {
        var arguments = ["watch", "remove", locator, "--path", workspace.path, "--json-output"]
        if keepPage {
            arguments.append("--keep-page")
        }
        let (_, stderr, status) = try await runRaw(arguments: arguments)
        guard status == 0 else {
            throw CompileCommandError(stderr.isEmpty ? "compile-bin watch remove failed." : stderr)
        }
    }

    public func runOnce(
        _ locator: String,
        force: Bool,
        at workspace: URL
    ) async throws -> WatchTickEvent {
        var arguments = ["watch", "run", locator, "--path", workspace.path, "--json-output"]
        if force {
            arguments.append("--force")
        }
        let (stdout, stderr, status) = try await runRaw(arguments: arguments)
        guard status == 0 else {
            throw CompileCommandError(stderr.isEmpty ? "compile-bin watch run failed." : stderr)
        }
        let envelope = try decoder.decode(WatchRunEnvelope.self, from: stdout)
        guard envelope.ok else {
            throw CompileCommandError(
                envelope.error
                    ?? envelope.event?.error
                    ?? "compile-bin watch run failed."
            )
        }
        guard let event = envelope.event else {
            throw CompileCommandError(envelope.error ?? "compile-bin watch run returned no event.")
        }
        return event
    }

    public func tick(at workspace: URL) async throws -> [WatchTickEvent] {
        let arguments = ["watch", "tick", "--path", workspace.path, "--json-output"]
        let (stdout, stderr, status) = try await runRaw(arguments: arguments)
        guard status == 0 else {
            throw CompileCommandError(stderr.isEmpty ? "compile-bin watch tick failed." : stderr)
        }
        let summary = try decoder.decode(WatchTickSummary.self, from: stdout)
        return summary.events
    }

    // MARK: - Private helpers

    private func decodeWatchEnvelope(arguments: [String]) async throws -> WatchRecord {
        let envelope: WatchEnvelope = try await runEnvelope(arguments: arguments)
        guard let watch = envelope.watch, envelope.ok else {
            throw CompileCommandError(envelope.error ?? "compile-bin watch command failed.")
        }
        return watch
    }

    private func runEnvelope<T: Decodable>(arguments: [String]) async throws -> T {
        let (stdout, stderr, status) = try await runRaw(arguments: arguments)
        guard status == 0 else {
            throw CompileCommandError(stderr.isEmpty ? "compile-bin failed." : stderr)
        }
        do {
            return try decoder.decode(T.self, from: stdout)
        } catch {
            let preview = String(decoding: stdout, as: UTF8.self)
            throw CompileCommandError("Failed to decode watch envelope: \(preview)")
        }
    }

    private func runRaw(arguments: [String]) async throws -> (stdout: Data, stderr: String, status: Int32) {
        let executableURL = try sidecarURLProvider()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task.detached { () -> Data in
            (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let stderrTask = Task.detached { () -> Data in
            (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let stdoutData = await stdoutTask.value
        let stderrText = String(decoding: await stderrTask.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrText.isEmpty {
            logger.log("watch sidecar stderr (\(arguments.first ?? "?")): \(stderrText)")
        }
        return (stdoutData, stderrText, status)
    }
}
