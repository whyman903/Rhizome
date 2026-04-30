import Foundation

public struct CompileCommandError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

private protocol CommandEnvelope: Decodable {
    var ok: Bool { get }
    var error: String? { get }
}

private struct WorkspaceEnvelope: CommandEnvelope {
    let ok: Bool
    let workspace: WorkspaceInfo?
    let error: String?
}

private struct PageEnvelope: CommandEnvelope {
    let ok: Bool
    let page: WikiPage?
    let error: String?
}

private struct ByteTailBuffer {
    private let limit: Int
    private var buffer = Data()

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ byte: UInt8) {
        buffer.append(byte)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    var stringValue: String {
        String(decoding: buffer, as: UTF8.self)
    }
}

public final class CompileRunner: CompileRunning, @unchecked Sendable {
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

    public func initWorkspace(name: String, at path: URL) async throws -> WorkspaceInfo {
        try await runWorkspaceCommand(arguments: ["init", name, "--path", path.path, "--json-output"])
    }

    public func status(at path: URL) async throws -> WorkspaceInfo {
        try await runWorkspaceCommand(arguments: ["status", "--path", path.path, "--json-output"])
    }

    public func prepareWorkspaceForClaude(at path: URL, force: Bool = false) async throws {
        try installCompileShim(at: path)
        var arguments = ["claude", "setup", path.path]
        if force {
            arguments.append("--force")
        }
        try await runPlainCommand(arguments: arguments)
    }

    public func page(locator: String, at path: URL) async throws -> WikiPage {
        let envelope: PageEnvelope = try await runEnvelopeCommand(
            arguments: ["obsidian", "page", locator, "--path", path.path, "--json-output"]
        )
        guard let page = envelope.page else {
            throw CompileCommandError("Sidecar returned no page payload.")
        }
        return page
    }

    public func ingest(
        source: String,
        at path: URL,
        jobID: String,
        onEvent: @escaping @Sendable (CompileEvent) -> Void
    ) async throws -> String? {
        let executableURL = try sidecarURLProvider()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["ingest", source, "--path", path.path, "--json-stream", "--job-id", jobID]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task { [decoder, logger] () -> Bool in
            var sawTerminal = false
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    guard !line.isEmpty else {
                        continue
                    }
                    do {
                        let event = try decoder.decode(CompileEvent.self, from: Data(line.utf8))
                        if event.isTerminal {
                            sawTerminal = true
                        }
                        onEvent(event)
                    } catch {
                        logger.log("Failed to decode sidecar event: \(line)")
                    }
                }
            } catch {
                logger.log("Failed while reading sidecar stdout: \(error)")
            }
            return sawTerminal
        }

        let stderrTask = Task { [logger] () -> String in
            var collector = ByteTailBuffer(limit: 8 * 1024)
            do {
                for try await byte in stderrPipe.fileHandleForReading.bytes {
                    collector.append(byte)
                }
            } catch {
                logger.log("Failed while reading sidecar stderr: \(error)")
            }
            return collector.stringValue
        }

        let termination = try await run(process: process)
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let sawTerminal = await stdoutTask.value
        let stderrTail = await stderrTask.value.trimmingCharacters(in: .whitespacesAndNewlines)

        if !stderrTail.isEmpty {
            logger.log("Sidecar stderr for \(source): \(stderrTail)")
        }

        if !sawTerminal {
            let message: String
            if !stderrTail.isEmpty {
                message = "compile-bin exited with code \(termination.status): \(stderrTail)"
            } else {
                message = "compile-bin exited with code \(termination.status) without a terminal event."
            }
            onEvent(.failed(id: jobID, source: source, rawPath: nil, message: message))
        }
        return stderrTail.isEmpty ? nil : stderrTail
    }

    private func runWorkspaceCommand(arguments: [String]) async throws -> WorkspaceInfo {
        let envelope: WorkspaceEnvelope = try await runEnvelopeCommand(arguments: arguments)
        guard let workspace = envelope.workspace else {
            throw CompileCommandError("Sidecar returned no workspace payload.")
        }
        return workspace
    }

    private func runPlainCommand(arguments: [String]) async throws {
        let executableURL = try sidecarURLProvider()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = readAllData(from: stdoutPipe, label: "stdout")
        let stderrTask = readAllData(from: stderrPipe, label: "stderr")

        let termination: (status: Int32, reason: Process.TerminationReason)
        do {
            termination = try await run(process: process)
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        let stdout = String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if !stdout.isEmpty {
            logger.log("Sidecar output for \(arguments.joined(separator: " ")): \(stdout)")
        }
        if !stderr.isEmpty {
            logger.log("Sidecar stderr for \(arguments.joined(separator: " ")): \(stderr)")
        }
        guard termination.status == 0 else {
            throw CompileCommandError(stderr.isEmpty ? "compile-bin failed with code \(termination.status)." : stderr)
        }
    }

    private func runEnvelopeCommand<T: CommandEnvelope>(arguments: [String]) async throws -> T {
        let executableURL = try sidecarURLProvider()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = readAllData(from: stdoutPipe, label: "stdout")
        let stderrTask = readAllData(from: stderrPipe, label: "stderr")

        let termination: (status: Int32, reason: Process.TerminationReason)
        do {
            termination = try await run(process: process)
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()
        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        let stderr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            logger.log("Sidecar stderr for \(arguments.joined(separator: " ")): \(stderr)")
        }

        let envelope: T
        do {
            envelope = try decoder.decode(T.self, from: stdoutData)
        } catch {
            let stdout = String(decoding: stdoutData, as: UTF8.self)
            throw CompileCommandError("Failed to decode sidecar response: \(stdout)")
        }
        if !envelope.ok || termination.status != 0 {
            throw CompileCommandError(envelope.error ?? "compile-bin failed.")
        }
        return envelope
    }

    private func run(process: Process) async throws -> (status: Int32, reason: Process.TerminationReason) {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: (process.terminationStatus, process.terminationReason))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func readAllData(from pipe: Pipe, label: String) -> Task<Data, Never> {
        // Drain the pipe with blocking `readToEnd()` on a GCD worker, bridged
        // into Swift concurrency via a checked continuation. The async
        // `FileHandle.bytes` iterator stops pumping mid-stream and deadlocks
        // once the child fills the 64KB pipe buffer, which hung every wiki-link
        // click that shells out to `compile obsidian page`. Running the blocking
        // read on `DispatchQueue.global` keeps the cooperative thread pool free
        // — a `Task.detached { readToEnd() }` would pin a pool thread per pipe.
        Task { [logger] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                        continuation.resume(returning: data)
                    } catch {
                        logger.log("Failed while reading sidecar \(label): \(error)")
                        continuation.resume(returning: Data())
                    }
                }
            }
        }
    }

    private func installCompileShim(at workspaceURL: URL) throws {
        let sidecarURL = try sidecarURLProvider()
        let binDirectory = workspaceURL
            .appending(path: ".compile", directoryHint: .isDirectory)
            .appending(path: "rhizome-bin", directoryHint: .isDirectory)
        let shimURL = binDirectory.appending(path: "compile", directoryHint: .notDirectory)

        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let script = """
        #!/bin/zsh
        exec \(TerminalLauncher.shellQuote(sidecarURL.path)) "$@"
        """
        try script.write(to: shimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
        logger.log("Installed compile shim at \(shimURL.path) -> \(sidecarURL.path)")
    }
}

public enum SidecarLocator {
    public static func defaultURL() throws -> URL {
        if let explicitPath = ProcessInfo.processInfo.environment["RHIZOME_SIDECAR_PATH"], !explicitPath.isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "compile-bin", directoryHint: .notDirectory),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        throw CompileCommandError("Unable to locate bundled compile-bin.")
    }
}
