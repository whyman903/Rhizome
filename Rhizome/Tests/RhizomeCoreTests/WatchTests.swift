import XCTest
@testable import RhizomeCore

final class WatchTests: XCTestCase {
    // MARK: - WatchRecord JSON contract

    func testWatchRecordDecodesFromSidecarPayload() throws {
        let json = """
        {
          "watch_id": "abc123",
          "title": "FT Markets",
          "relative_path": "wiki/watches/FT Markets.md",
          "url": "https://example.com",
          "frequency": "daily",
          "intent": "Top stories",
          "watch_status": "active",
          "last_status": null,
          "last_run": null,
          "next_run": "2026-05-07T09:00:00Z",
          "consecutive_failures": 0,
          "last_error": null
        }
        """

        let record = try JSONDecoder().decode(WatchRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.id, "abc123")
        XCTAssertEqual(record.title, "FT Markets")
        XCTAssertEqual(record.url, "https://example.com")
        XCTAssertEqual(record.frequency, "daily")
        XCTAssertEqual(record.watchStatus, "active")
        XCTAssertNil(record.lastRun)
        XCTAssertEqual(record.nextRun, "2026-05-07T09:00:00Z")
    }

    func testWatchTickEventDecodesAllStatuses() throws {
        let json = """
        {"watch_id":"id1","title":"X","relative_path":"wiki/watches/X.md","status":"ok","raw_path":"raw/watches/x/01.md","error":null,"auto_paused":null}
        """
        let event = try JSONDecoder().decode(WatchTickEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.watchID, "id1")
        XCTAssertEqual(event.status, "ok")
        XCTAssertEqual(event.rawPath, "raw/watches/x/01.md")
        XCTAssertNil(event.error)
    }

    // MARK: - WatchScheduler active-workspace pointer

    /// `writePointer` is the only piece of `install()` we exercise from tests:
    /// `install()` would also bootout `~/Library/LaunchAgents/app.rhizome.watch-tick.plist`
    /// and bootstrap a real launchd agent, which can mutate launchd state on
    /// the developer's machine.
    func testWritePointerStoresStandardizedWorkspacePath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pointerURL = tmp.appendingPathComponent("active-workspace")
        let workspace = tmp.appendingPathComponent("wiki", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let scheduler = WatchScheduler(pointerURL: pointerURL, logger: nil)
        try scheduler.writePointer(workspaceURL: workspace)

        XCTAssertTrue(FileManager.default.fileExists(atPath: pointerURL.path))
        let written = try String(contentsOf: pointerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            written,
            workspace.resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    func testWritePointerCreatesParentDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pointerURL = tmp
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("active-workspace")
        let workspace = FileManager.default.temporaryDirectory
        let scheduler = WatchScheduler(pointerURL: pointerURL, logger: nil)
        try scheduler.writePointer(workspaceURL: workspace)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pointerURL.path))
    }

    func testDefaultPointerURLLivesUnderApplicationSupport() {
        let url = WatchScheduler.defaultPointerURL()
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Rhizome/active-workspace"))
    }

    // MARK: - WatchSidecar end-to-end via fake binary

    func testWatchSidecarParsesListEnvelopeFromFakeBinary() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeURL = tmpDir.appendingPathComponent("fake-compile.sh")
        let payload = """
        {"ok":true,"watches":[{"watch_id":"x","title":"X","relative_path":"wiki/watches/X.md","url":"https://e.com","frequency":"daily","intent":"","watch_status":"active","last_status":null,"last_run":null,"next_run":null,"consecutive_failures":0,"last_error":null}]}
        """
        let script = """
        #!/bin/bash
        echo '\(payload)'
        """
        try script.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeURL.path)

        let sidecar = WatchSidecar(logger: AppLogger()) {
            fakeURL
        }
        let watches = try await sidecar.list(at: tmpDir)
        XCTAssertEqual(watches.count, 1)
        XCTAssertEqual(watches.first?.title, "X")
    }

    func testWatchSidecarSurfacesErrorMessage() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeURL = tmpDir.appendingPathComponent("fake-compile-fail.sh")
        let script = """
        #!/bin/bash
        echo "boom" >&2
        exit 1
        """
        try script.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeURL.path)

        let sidecar = WatchSidecar(logger: AppLogger()) { fakeURL }
        do {
            _ = try await sidecar.list(at: tmpDir)
            XCTFail("expected failure")
        } catch let error as CompileCommandError {
            XCTAssertTrue(error.message.contains("boom"), "got: \(error.message)")
        }
    }

    func testWatchSidecarRunOnceSurfacesFailedEnvelope() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeURL = tmpDir.appendingPathComponent("fake-compile-run-fail.sh")
        let payload = """
        {"ok":false,"event":{"watch_id":"x","title":"X","relative_path":"wiki/watches/X.md","status":"failed","error":"claude failed","auto_paused":null,"raw_path":null}}
        """
        let script = """
        #!/bin/bash
        echo '\(payload)'
        """
        try script.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeURL.path)

        let sidecar = WatchSidecar(logger: AppLogger()) { fakeURL }
        do {
            _ = try await sidecar.runOnce("x", force: false, at: tmpDir)
            XCTFail("expected failed watch run to throw")
        } catch let error as CompileCommandError {
            XCTAssertTrue(error.message.contains("claude failed"), "got: \(error.message)")
        }
    }

    func testWatchSidecarUpdateIntentPassesWatchUpdateArguments() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeURL = tmpDir.appendingPathComponent("fake-compile-update.sh")
        let argsURL = tmpDir.appendingPathComponent("args.txt")
        let payload = """
        {"ok":true,"watch":{"watch_id":"x","title":"X","relative_path":"wiki/watches/X.md","url":"https://e.com","frequency":"daily","intent":"Updated prompt","watch_status":"active","last_status":null,"last_run":null,"next_run":null,"consecutive_failures":0,"last_error":null}}
        """
        let script = """
        #!/bin/bash
        printf '%s\\n' "$@" > '\(argsURL.path)'
        echo '\(payload)'
        """
        try script.write(to: fakeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeURL.path)

        let sidecar = WatchSidecar(logger: AppLogger()) {
            fakeURL
        }
        let watch = try await sidecar.updateIntent("x", intent: "Updated prompt", at: tmpDir)
        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(watch.intent, "Updated prompt")
        XCTAssertEqual(Array(args.prefix(3)), ["watch", "update", "x"])
        XCTAssertEqual(Array(args.drop(while: { $0 != "--intent" }).prefix(2)), ["--intent", "Updated prompt"])
        XCTAssertTrue(args.contains(tmpDir.path))
        XCTAssertTrue(args.contains("--json-output"))
    }
}
