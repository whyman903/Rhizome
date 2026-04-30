import Foundation

public struct TerminalLaunchError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum TerminalLauncher {
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build the contents of a `.command` shell script that `cd`s into `directory`,
    /// optionally runs `runningCommand`, and then hands control to an interactive login
    /// shell so the Terminal window stays open after the command finishes.
    ///
    /// If `pendingPrompt` is provided, the prompt is copied to the clipboard and a
    /// background `osascript` fires `⌘V` at the new Terminal window once Claude has
    /// had a moment to boot. Claude sees the text land in its input buffer and the
    /// user can edit or hit return to submit — no manual paste required.
    public static func buildLaunchScript(
        directory: URL,
        runningCommand: String?,
        pendingPrompt: String? = nil
    ) -> String {
        var lines: [String] = ["#!/bin/zsh", "set -o pipefail"]
        lines.append("cd " + shellQuote(directory.path))
        lines.append(
            "export PATH=\"$PWD/.compile/rhizome-bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH\""
        )
        lines.append("clear")
        if let pendingPrompt, !pendingPrompt.isEmpty {
            lines.append("printf '%s' " + shellQuote(pendingPrompt) + " | pbcopy")
            lines.append(
                "printf '\\n\\033[38;5;51m⚡ Drafting into Claude…\\033[0m\\n"
                + "\\033[2m  Prompt will land in the input when Claude is ready — edit freely, then return to submit.\\033[0m\\n\\n'"
            )
            // Fire-and-forget: wait for Claude to finish booting, then send ⌘V to the
            // frontmost window (which is the Terminal tab we just opened). First run
            // prompts the user to grant Accessibility permission; after that it is silent.
            lines.append(
                "( sleep 1.6 && "
                + "osascript -e 'tell application \"System Events\" to keystroke \"v\" using command down' "
                + ">/dev/null 2>&1 ) &"
            )
        }
        if let runningCommand, !runningCommand.isEmpty {
            lines.append(runningCommand)
        }
        lines.append("exec $SHELL -l")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func launchScriptsDirectory() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "Rhizome-launchers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    @discardableResult
    public static func writeLaunchScript(
        directory: URL,
        runningCommand: String?,
        pendingPrompt: String? = nil
    ) throws -> URL {
        let dir = launchScriptsDirectory()
        let scriptURL = dir.appending(
            path: "launch-\(UUID().uuidString.prefix(8)).command",
            directoryHint: .notDirectory
        )
        let script = buildLaunchScript(
            directory: directory,
            runningCommand: runningCommand,
            pendingPrompt: pendingPrompt
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    /// Launches Terminal.app with a `.command` script that cd's to the workspace and runs
    /// the given command. Uses `/usr/bin/open -a Terminal <script>` instead of AppleScript
    /// to avoid the macOS Automation permission prompt.
    @discardableResult
    public static func launch(
        directory: URL,
        runningCommand: String? = nil,
        pendingPrompt: String? = nil
    ) throws -> URL {
        let scriptURL = try writeLaunchScript(
            directory: directory,
            runningCommand: runningCommand,
            pendingPrompt: pendingPrompt
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", scriptURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw TerminalLaunchError("Failed to spawn /usr/bin/open: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = errText.isEmpty
                ? "open exited with code \(process.terminationStatus)"
                : "open exited with code \(process.terminationStatus): \(errText)"
            throw TerminalLaunchError("Terminal launch failed: \(hint)")
        }

        return scriptURL
    }
}
