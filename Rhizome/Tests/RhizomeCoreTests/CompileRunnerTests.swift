import Foundation
import XCTest
@testable import RhizomeCore

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CompileEvent] = []

    func append(_ event: CompileEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [CompileEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class CompileRunnerTests: XCTestCase {
    func testPrepareWorkspaceInstallsCompileShimAndRunsClaudeSetup() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let workspaceURL = tempDirectory.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: workspaceURL.appending(path: ".compile", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let scriptURL = tempDirectory.appending(path: "compile-bin", directoryHint: .notDirectory)
        let argsURL = tempDirectory.appending(path: "args.txt", directoryHint: .notDirectory)
        try """
        #!/bin/zsh
        printf "%s\\n" "$@" > \(TerminalLauncher.shellQuote(argsURL.path))
        exit 0
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let logger = AppLogger(logDirectory: tempDirectory.appending(path: "logs", directoryHint: .isDirectory))
        let runner = CompileRunner(logger: logger) { scriptURL }

        try await runner.prepareWorkspaceForClaude(at: workspaceURL, force: true)

        let shimURL = workspaceURL
            .appending(path: ".compile", directoryHint: .isDirectory)
            .appending(path: "rhizome-bin", directoryHint: .isDirectory)
            .appending(path: "compile", directoryHint: .notDirectory)
        let shim = try String(contentsOf: shimURL, encoding: .utf8)
        XCTAssertTrue(shim.contains(TerminalLauncher.shellQuote(scriptURL.path)))

        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(args, ["claude", "setup", workspaceURL.path, "--force"])
    }

    func testSynthesizesFailedEventWhenProcessExitsWithoutTerminalEvent() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let scriptURL = tempDirectory.appending(path: "compile-bin", directoryHint: .notDirectory)
        try """
        #!/bin/zsh
        echo '{"event":"started","id":"job-1","kind":"ingest","source":"paper.md"}'
        echo "stderr details" >&2
        exit 1
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let logger = AppLogger(logDirectory: tempDirectory.appending(path: "logs", directoryHint: .isDirectory))
        let runner = CompileRunner(logger: logger) { scriptURL }
        let collector = EventCollector()

        let stderrTail = try await runner.ingest(
            source: "paper.md",
            at: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
            jobID: "job-1"
        ) { event in
            collector.append(event)
        }
        let received = collector.snapshot()

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.first, .started(id: "job-1", source: "paper.md", workspace: nil))
        XCTAssertEqual(
            received.last,
            .failed(
                id: "job-1",
                source: "paper.md",
                rawPath: nil,
                message: "compile-bin exited with code 1: stderr details"
            )
        )
        XCTAssertEqual(stderrTail, "stderr details")
    }
}
