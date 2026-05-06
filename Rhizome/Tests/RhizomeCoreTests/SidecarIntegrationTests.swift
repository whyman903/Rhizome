import Foundation
import XCTest
@testable import RhizomeCore

@MainActor
final class SidecarIntegrationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "RhizomeSidecarTests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let cleanupURL = tempDirectory {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    private func sidecarURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RHIZOME_SIDECAR_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundled = repoRoot
            .appending(path: "dist", directoryHint: .isDirectory)
            .appending(path: "Rhizome.app", directoryHint: .isDirectory)
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "compile-bin", directoryHint: .notDirectory)
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            throw XCTSkip("Bundled compile-bin not found at \(bundled.path). Run scripts/build.sh first.")
        }
        return bundled
    }

    /// Verifies that the compile-bin surface Rhizome still relies on (init / status / page)
    /// returns the JSON shapes the Swift decoders expect.
    func testWorkspaceBootstrapAndPageViaRealSidecar() async throws {
        let sidecar = try sidecarURL()
        let logger = AppLogger(logDirectory: tempDirectory.appending(path: "logs"))
        let runner = CompileRunner(logger: logger) { sidecar }

        let workspaceURL = tempDirectory.appending(path: "wiki", directoryHint: .isDirectory)
        let info = try await runner.initWorkspace(name: "Integration Wiki", at: workspaceURL)
        XCTAssertEqual(info.topic, "Integration Wiki")

        let rawFile = URL(fileURLWithPath: info.path, isDirectory: true)
            .appending(path: "raw", directoryHint: .isDirectory)
            .appending(path: "memo.md", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: rawFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Integration Memo\n\nReferences the phrase kumquat so search can find it.\n"
            .write(to: rawFile, atomically: true, encoding: .utf8)

        // Use the real compile-bin to ingest outside of Rhizome's runtime code path — this is
        // the equivalent of what Claude will run inside its session after Rhizome stages the file.
        let process = Process()
        process.executableURL = sidecar
        process.arguments = ["ingest", "raw/memo.md", "--path", info.path, "--json-stream", "--job-id", "test"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let status = try await runner.status(at: URL(fileURLWithPath: info.path, isDirectory: true))
        XCTAssertGreaterThan(status.wikiPageCount, info.wikiPageCount)

        let page = try await runner.page(
            locator: "wiki/sources/Integration Memo.md",
            at: URL(fileURLWithPath: info.path, isDirectory: true)
        )
        XCTAssertEqual(page.title, "Integration Memo")
    }
}
