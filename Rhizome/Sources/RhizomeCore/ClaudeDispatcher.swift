import Foundation

/// Dispatches a prompt into a new Terminal tab running `claude`. The prompt is
/// copied to the clipboard and a background osascript sends ⌘V once Claude finishes
/// booting so the text lands in the input buffer — user can edit or press return.
@MainActor
public final class TerminalClaudeDispatcher: IngestDispatcher {
    private let logger: AppLogger

    public init(logger: AppLogger) {
        self.logger = logger
    }

    public func dispatch(prompt: String, workspaceURL: URL) throws {
        logger.log("Draft prompt copied for \(workspaceURL.path): \(prompt)")
        try TerminalLauncher.launch(
            directory: workspaceURL,
            runningCommand: "claude",
            pendingPrompt: prompt
        )
    }
}
