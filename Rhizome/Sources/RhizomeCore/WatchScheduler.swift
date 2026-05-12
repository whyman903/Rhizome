import Foundation
import ServiceManagement

/// Installs the launchd user agent that fires `compile watch tick` every 15
/// minutes.
///
/// The agent is registered as a classic per-user LaunchAgent at
/// `~/Library/LaunchAgents/app.rhizome.watch-tick.plist` with an absolute
/// `Program` path pointing at the bundled `compile-bin`. The bundled
/// `Contents/Library/LaunchAgents/...plist` is intentionally **not** used:
/// SMAppService loads it as a `BundleProgram`, which on macOS 14+ triggers a
/// launch-constraint check that rejects adhoc-signed executables with
/// `OS_REASON_CODESIGNING`. Going through the user-domain LaunchAgent escapes
/// the bundle-context constraint at the cost of attribution — macOS lists the
/// background activity as "compile-bin" rather than "Rhizome".
///
/// The plist does not bake in a workspace path. The Mac app writes
/// ``pointerURL`` (`~/Library/Application Support/Rhizome/active-workspace`)
/// whenever the user opens a workspace, and `compile watch tick` resolves it
/// when invoked without `--path`.
public struct WatchScheduler: Sendable {
    public static let plistName = "app.rhizome.watch-tick.plist"
    public static let label = "app.rhizome.watch-tick"

    public let plistName: String
    public let pointerURL: URL
    public let logger: AppLogger?

    public init(
        plistName: String = WatchScheduler.plistName,
        pointerURL: URL? = nil,
        logger: AppLogger? = nil
    ) {
        self.plistName = plistName
        self.pointerURL = pointerURL ?? WatchScheduler.defaultPointerURL()
        self.logger = logger
    }

    /// Path the Mac app writes when a workspace is selected. Read by
    /// `compile watch tick` when invoked without `--path`.
    public static func defaultPointerURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Rhizome", directoryHint: .isDirectory)
            .appending(path: "active-workspace", directoryHint: .notDirectory)
    }

    /// Write the active-workspace pointer file and (re)install the user-domain
    /// LaunchAgent. Re-bootstraps on every call so that an in-place rebuild of
    /// `Rhizome.app` is picked up without manual `launchctl bootout`.
    public func install(workspaceURL: URL) throws {
        try writePointer(workspaceURL: workspaceURL)
        unregisterSMAppServiceAgentIfPresent()

        let programURL = try resolveProgramURL()
        let plistURL = userAgentPlistURL()
        try writeUserAgentPlist(at: plistURL, programURL: programURL)

        bootoutUserAgent(plistURL: plistURL)
        try bootstrapUserAgent(plistURL: plistURL)

        logger?.log("WatchScheduler: bootstrapped \(plistName) program=\(programURL.path)")
    }

    /// Unregister the agent and clear the pointer file.
    public func uninstall() {
        let plistURL = userAgentPlistURL()
        bootoutUserAgent(plistURL: plistURL)
        try? FileManager.default.removeItem(at: plistURL)
        unregisterSMAppServiceAgentIfPresent()
        try? FileManager.default.removeItem(at: pointerURL)
    }

    public var isRegistered: Bool {
        FileManager.default.fileExists(atPath: userAgentPlistURL().path)
    }

    /// Write the active-workspace pointer file. Pure filesystem op — no
    /// `launchctl`, no SMAppService side effects. Exposed so tests can verify
    /// the pointer contract without risking a real user's launchd state.
    public func writePointer(workspaceURL: URL) throws {
        let directory = pointerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let resolved = workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
        try (resolved + "\n").write(to: pointerURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Internals

    enum WatchSchedulerError: Error, LocalizedError {
        case sidecarNotFound(URL)
        case bootstrapFailed(status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .sidecarNotFound(let url):
                return "Watch agent could not find compile-bin at \(url.path). Rebuild Rhizome.app."
            case .bootstrapFailed(let status, let output):
                return "launchctl bootstrap failed (status \(status)): \(output)"
            }
        }
    }

    private func userAgentPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(plistName)", directoryHint: .notDirectory)
    }

    private func resolveProgramURL() throws -> URL {
        let bundle = Bundle.main
        // Bundle.main.executableURL is …/Contents/MacOS/Rhizome; walk up to Contents/.
        guard let bundleExecutable = bundle.executableURL else {
            throw WatchSchedulerError.sidecarNotFound(bundle.bundleURL)
        }
        let candidate = bundleExecutable
            .deletingLastPathComponent()   // Contents/MacOS
            .deletingLastPathComponent()   // Contents
            .appending(path: "Resources/compile-bin", directoryHint: .notDirectory)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw WatchSchedulerError.sidecarNotFound(candidate)
        }
        return candidate
    }

    private func writeUserAgentPlist(at plistURL: URL, programURL: URL) throws {
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let dict: [String: Any] = [
            "Label": WatchScheduler.label,
            "Program": programURL.path,
            "ProgramArguments": [
                "compile-bin",
                "watch",
                "tick",
                "--json-stream",
            ],
            "StartInterval": 900,
            "RunAtLoad": false,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private func bootoutUserAgent(plistURL: URL) {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", plistURL.path]
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger?.log("WatchScheduler: bootout failed to launch — \(error.localizedDescription)")
        }
    }

    private func bootstrapUserAgent(plistURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", "gui/\(getuid())", plistURL.path]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = (try? stderrPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw WatchSchedulerError.bootstrapFailed(
                status: process.terminationStatus,
                output: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Older builds registered the agent through SMAppService against the
    /// bundled plist. That registration is broken on adhoc-signed dev builds
    /// (launch-constraint violation) and must be cleared before the
    /// user-domain agent can take over.
    private func unregisterSMAppServiceAgentIfPresent() {
        let service = SMAppService.agent(plistName: plistName)
        switch service.status {
        case .enabled, .requiresApproval:
            do {
                try service.unregister()
                logger?.log("WatchScheduler: unregistered prior SMAppService agent")
            } catch {
                logger?.log("WatchScheduler: SMAppService unregister failed — \(error.localizedDescription)")
            }
        case .notRegistered, .notFound:
            return
        @unknown default:
            return
        }
    }
}
