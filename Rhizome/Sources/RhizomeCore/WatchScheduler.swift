import Foundation

/// Manages the launchd user agent that fires `compile watch tick` on a recurring
/// interval. Default cadence is every 15 minutes — fine-grained enough for hourly
/// watches without burning resources.
///
/// The plist is owned per-workspace: re-installing for a new workspace replaces
/// the previous one. Removing the workspace selection unloads the agent.
public struct WatchScheduler: Sendable {
    public static let label = "app.rhizome.watch-tick"
    public static let defaultIntervalSeconds = 900   // 15 minutes

    public let label: String
    public let intervalSeconds: Int
    public let logURL: URL
    public let plistURL: URL
    public let logger: AppLogger?

    public init(
        label: String = WatchScheduler.label,
        intervalSeconds: Int = WatchScheduler.defaultIntervalSeconds,
        logURL: URL? = nil,
        plistURL: URL? = nil,
        logger: AppLogger? = nil
    ) {
        self.label = label
        self.intervalSeconds = intervalSeconds
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logURL = logURL
            ?? home.appending(path: "Library/Logs/Rhizome/watch-tick.log", directoryHint: .notDirectory)
        self.plistURL = plistURL
            ?? home.appending(path: "Library/LaunchAgents/\(label).plist", directoryHint: .notDirectory)
        self.logger = logger
    }

    /// Render the plist content for *workspaceURL*, using *sidecarPath* as the
    /// `compile-bin` binary. Pure — no filesystem effects.
    public func renderPlist(sidecarPath: String, workspaceURL: URL) -> String {
        let workspacePath = workspaceURL.path
        let escapedSidecar = WatchScheduler.escapeXML(sidecarPath)
        let escapedWorkspace = WatchScheduler.escapeXML(workspacePath)
        let escapedLog = WatchScheduler.escapeXML(logURL.path)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escapedSidecar)</string>
                <string>watch</string>
                <string>tick</string>
                <string>--path</string>
                <string>\(escapedWorkspace)</string>
                <string>--json-stream</string>
            </array>
            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>\(escapedLog)</string>
            <key>StandardErrorPath</key>
            <string>\(escapedLog)</string>
        </dict>
        </plist>
        """
    }

    /// Write the plist for *workspaceURL* and reload the launchd agent.
    @discardableResult
    public func install(sidecarPath: String, workspaceURL: URL) throws -> URL {
        let plist = renderPlist(sidecarPath: sidecarPath, workspaceURL: workspaceURL)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = runLaunchctl(["bootout", "gui/\(uid())", plistURL.path])  // ignore failure on first install
        let bootstrap = runLaunchctl(["bootstrap", "gui/\(uid())", plistURL.path])
        guard bootstrap.status == 0 else {
            throw CompileCommandError(
                bootstrap.stderr.isEmpty
                    ? "launchctl bootstrap failed with code \(bootstrap.status)."
                    : bootstrap.stderr
            )
        }
        logger?.log("WatchScheduler: installed \(plistURL.path) for \(workspaceURL.path)")
        return plistURL
    }

    /// Unload and delete the plist if present.
    public func uninstall() {
        _ = runLaunchctl(["bootout", "gui/\(uid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        logger?.log("WatchScheduler: removed \(plistURL.path)")
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private func runLaunchctl(_ arguments: [String]) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(
                decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus, stderr)
        } catch {
            logger?.log("WatchScheduler: launchctl \(arguments.joined(separator: " ")) failed — \(error)")
            return (-1, error.localizedDescription)
        }
    }

    private func uid() -> String {
        String(getuid())
    }

    static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
