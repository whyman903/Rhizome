import Foundation
import ServiceManagement

/// Registers the bundled launchd user agent that fires `compile watch tick`
/// every 15 minutes via SMAppService.
///
/// The plist is bundled inside `Rhizome.app/Contents/Library/LaunchAgents/` and
/// runs the sidecar relative to the bundle (`BundleProgram`). It does *not*
/// bake the workspace path into ProgramArguments — instead the Mac app writes
/// ``activeWorkspacePointerURL`` whenever the user selects a workspace, and
/// `compile watch tick` resolves it. This keeps the plist static (which
/// SMAppService requires) and lets macOS attribute the background activity
/// to "Rhizome" rather than to the raw `compile-bin` executable name.
public struct WatchScheduler: Sendable {
    public static let plistName = "app.rhizome.watch-tick.plist"
    public static let legacyLabel = "app.rhizome.watch-tick"

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

    /// Write the active-workspace pointer file and register the bundled agent.
    /// Idempotent — safe to call repeatedly across workspace switches and app
    /// launches. Also clears any legacy `~/Library/LaunchAgents/app.rhizome.watch-tick.plist`
    /// left over from pre-SMAppService installs so we don't double-fire.
    public func install(workspaceURL: URL) throws {
        try writePointer(workspaceURL: workspaceURL)
        removeLegacyAgentIfPresent()
        let service = SMAppService.agent(plistName: plistName)
        // Only `.notRegistered` should trigger register():
        //   .enabled          — already running, register() throws kSMErrorAlreadyRegistered.
        //   .requiresApproval — registered but the user disabled it in System Settings;
        //                       calling register() again fights that explicit choice.
        //   .notFound         — bundled plist is missing or invalid; let register() raise.
        // The pointer rewrite above is enough to retarget the active workspace in every
        // already-registered state.
        switch service.status {
        case .enabled:
            logger?.log("WatchScheduler: already registered, refreshed pointer for \(workspaceURL.path)")
            return
        case .requiresApproval:
            logger?.log("WatchScheduler: agent disabled in Login Items; refreshed pointer for \(workspaceURL.path)")
            return
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        do {
            try service.register()
            logger?.log("WatchScheduler: registered \(plistName) for \(workspaceURL.path)")
        } catch {
            logger?.log("WatchScheduler: register() failed — \(error.localizedDescription)")
            throw error
        }
    }

    /// Unregister the agent and clear the pointer file.
    public func uninstall() {
        let service = SMAppService.agent(plistName: plistName)
        do {
            try service.unregister()
            logger?.log("WatchScheduler: unregistered \(plistName)")
        } catch {
            logger?.log("WatchScheduler: unregister() failed — \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: pointerURL)
    }

    public var isRegistered: Bool {
        SMAppService.agent(plistName: plistName).status == .enabled
    }

    public var status: SMAppService.Status {
        SMAppService.agent(plistName: plistName).status
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

    /// Bootout + delete the pre-SMAppService `~/Library/LaunchAgents/<label>.plist`
    /// if a previous app install wrote one. Failures are logged and ignored —
    /// this is a best-effort cleanup.
    private func removeLegacyAgentIfPresent() {
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(WatchScheduler.legacyLabel).plist", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())", legacyURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: legacyURL)
        logger?.log("WatchScheduler: removed legacy agent at \(legacyURL.path)")
    }
}
