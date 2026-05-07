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
          "run_count": 0,
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
        XCTAssertEqual(record.runCount, 0)
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

    // MARK: - WatchScheduler plist content

    func testRenderPlistContainsSidecarAndWorkspacePaths() {
        let scheduler = WatchScheduler(
            label: "test.watch",
            intervalSeconds: 600,
            logURL: URL(fileURLWithPath: "/tmp/log.log"),
            plistURL: URL(fileURLWithPath: "/tmp/plist.plist"),
            logger: nil
        )
        let plist = scheduler.renderPlist(
            sidecarPath: "/usr/local/bin/compile-bin",
            workspaceURL: URL(fileURLWithPath: "/Users/test/wiki")
        )
        XCTAssertTrue(plist.contains("<string>/usr/local/bin/compile-bin</string>"))
        XCTAssertTrue(plist.contains("<string>/Users/test/wiki</string>"))
        XCTAssertTrue(plist.contains("<integer>600</integer>"))
        XCTAssertTrue(plist.contains("<key>Label</key>\n    <string>test.watch</string>"))
        XCTAssertTrue(plist.contains("--json-stream"))
    }

    func testRenderPlistEscapesXMLSpecialCharsInPaths() {
        let scheduler = WatchScheduler(
            label: "test.watch",
            intervalSeconds: 900,
            logURL: URL(fileURLWithPath: "/tmp/l.log"),
            plistURL: URL(fileURLWithPath: "/tmp/p.plist"),
            logger: nil
        )
        let plist = scheduler.renderPlist(
            sidecarPath: "/bin/compile",
            workspaceURL: URL(fileURLWithPath: "/Users/test & friends/wiki")
        )
        XCTAssertTrue(plist.contains("/Users/test &amp; friends/wiki"))
        XCTAssertFalse(plist.contains("/Users/test & friends/wiki"))
    }

    // MARK: - WatchSidecar end-to-end via fake binary

    func testWatchSidecarParsesListEnvelopeFromFakeBinary() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeURL = tmpDir.appendingPathComponent("fake-compile.sh")
        let payload = """
        {"ok":true,"watches":[{"watch_id":"x","title":"X","relative_path":"wiki/watches/X.md","url":"https://e.com","frequency":"daily","intent":"","watch_status":"active","last_status":null,"last_run":null,"next_run":null,"run_count":0,"consecutive_failures":0,"last_error":null}]}
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
}
