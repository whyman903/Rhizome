import Foundation
import XCTest
@testable import RhizomeCore

final class TerminalLauncherTests: XCTestCase {
    func testShellQuoteWrapsPlainValue() {
        XCTAssertEqual(TerminalLauncher.shellQuote("/tmp/wiki"), "'/tmp/wiki'")
    }

    func testShellQuoteEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(
            TerminalLauncher.shellQuote("/tmp/rhizome's wiki"),
            "'/tmp/rhizome'\\''s wiki'"
        )
    }

    func testBuildLaunchScriptIncludesCdAndRunCommand() {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let script = TerminalLauncher.buildLaunchScript(
            directory: url,
            runningCommand: "claude"
        )
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh"), "script was: \(script)")
        XCTAssertTrue(script.contains("cd '/tmp/wiki'"), "script was: \(script)")
        XCTAssertTrue(script.contains("\nclaude\n") || script.hasSuffix("claude\nexec $SHELL -l\n"),
                      "script was: \(script)")
        XCTAssertTrue(script.contains("exec $SHELL -l"), "script was: \(script)")
    }

    func testBuildLaunchScriptOmitsCommandLineWhenNil() {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let script = TerminalLauncher.buildLaunchScript(
            directory: url,
            runningCommand: nil
        )
        XCTAssertTrue(script.contains("cd '/tmp/wiki'"))
        // PATH export mentions claude/local but no actual `claude` invocation should appear.
        let lines = script.split(separator: "\n")
        XCTAssertFalse(lines.contains { $0 == "claude" || $0.hasPrefix("claude ") },
                      "script was: \(script)")
        XCTAssertTrue(script.contains("exec $SHELL -l"))
    }

    func testBuildLaunchScriptQuotesWorkspaceWithSingleQuote() {
        let url = URL(fileURLWithPath: "/tmp/rhizome's wiki")
        let script = TerminalLauncher.buildLaunchScript(directory: url, runningCommand: nil)
        XCTAssertTrue(script.contains("cd '/tmp/rhizome'\\''s wiki'"), "script was: \(script)")
    }

    func testBuildLaunchScriptPrependsClaudePathEntries() {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let script = TerminalLauncher.buildLaunchScript(directory: url, runningCommand: nil)
        XCTAssertTrue(script.contains("$PWD/.compile/rhizome-bin"))
        XCTAssertTrue(script.contains("$HOME/.claude/local"))
        XCTAssertTrue(script.contains("/opt/homebrew/bin"))
    }

    func testBuildLaunchScriptWithPendingPromptUsesPbcopyBannerAndKeystrokeInjection() {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let script = TerminalLauncher.buildLaunchScript(
            directory: url,
            runningCommand: "claude",
            pendingPrompt: "/ingest raw/sample.md"
        )
        XCTAssertTrue(
            script.contains("printf '%s' '/ingest raw/sample.md' | pbcopy"),
            "script was: \(script)"
        )
        XCTAssertTrue(script.contains("Drafting into Claude"), "script was: \(script)")
        XCTAssertTrue(
            script.contains("keystroke \"v\" using command down"),
            "script was: \(script)"
        )
        XCTAssertTrue(
            script.contains("sleep 1.6"),
            "script was: \(script)"
        )
        // Banner + keystroke scheduling must appear before `claude` is executed.
        guard let bannerRange = script.range(of: "Drafting into Claude"),
              let claudeRange = script.range(of: "\nclaude") else {
            XCTFail("expected banner and claude line in: \(script)")
            return
        }
        XCTAssertTrue(bannerRange.lowerBound < claudeRange.lowerBound)
    }

    func testBuildLaunchScriptEscapesSingleQuoteInPendingPrompt() {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let script = TerminalLauncher.buildLaunchScript(
            directory: url,
            runningCommand: "claude",
            pendingPrompt: "can't stop the clipboard"
        )
        XCTAssertTrue(
            script.contains("printf '%s' 'can'\\''t stop the clipboard' | pbcopy"),
            "script was: \(script)"
        )
    }

    func testBuildLaunchScriptOmitsPbcopyWhenPromptIsNil() {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let script = TerminalLauncher.buildLaunchScript(
            directory: url,
            runningCommand: "claude",
            pendingPrompt: nil
        )
        XCTAssertFalse(script.contains("pbcopy"), "script was: \(script)")
        XCTAssertFalse(script.contains("Draft prompt"), "script was: \(script)")
    }

    func testWriteLaunchScriptProducesExecutableCommandFile() throws {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let scriptURL = try TerminalLauncher.writeLaunchScript(
            directory: url,
            runningCommand: "claude"
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        XCTAssertEqual(scriptURL.pathExtension, "command")
        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o755)
        let contents = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("cd '/tmp/wiki'"))
        XCTAssertTrue(contents.contains("claude"))
    }

    func testWriteLaunchScriptEmbedsPendingPrompt() throws {
        let url = URL(fileURLWithPath: "/tmp/wiki")
        let scriptURL = try TerminalLauncher.writeLaunchScript(
            directory: url,
            runningCommand: "claude",
            pendingPrompt: "/query where did I put that paper on compulsory vaccination"
        )
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        let contents = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("pbcopy"))
        XCTAssertTrue(contents.contains("/query where did I put that paper on compulsory vaccination"))
    }
}
