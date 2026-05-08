import AppKit
import Foundation

struct ObsidianVaultRegistry: Decodable {
    struct Vault: Decodable {
        let path: String
    }

    let vaults: [String: Vault]

    static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/obsidian/obsidian.json", directoryHint: .notDirectory)

    static func load(from registryURL: URL = defaultURL) -> ObsidianVaultRegistry? {
        guard let data = try? Data(contentsOf: registryURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ObsidianVaultRegistry.self, from: data)
    }

    func identifier(for workspaceURL: URL) -> String? {
        let expectedPath = workspaceURL.standardizedFileURL.path
        return vaults.first { identifier, vault in
            _ = identifier
            return URL(fileURLWithPath: vault.path).standardizedFileURL.path == expectedPath
        }?.key
    }
}

enum ObsidianPluginInstallError: LocalizedError {
    case invalidReleaseMetadata
    case missingAsset(String)
    case badResponse(URL)
    case communityPluginsConfigInvalid

    var errorDescription: String? {
        switch self {
        case .invalidReleaseMetadata:
            return "GitHub returned an invalid Advanced URI release payload."
        case .missingAsset(let name):
            return "The Advanced URI release is missing \(name)."
        case .badResponse(let url):
            return "Could not download \(url.lastPathComponent) from GitHub."
        case .communityPluginsConfigInvalid:
            return "The vault's community plugin config is not valid JSON."
        }
    }
}

struct ObsidianCommunityPluginsStore {
    static func configURL(in workspaceURL: URL) -> URL {
        workspaceURL.appending(path: ".obsidian/community-plugins.json", directoryHint: .notDirectory)
    }

    static func enabledPluginIDs(
        in workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws -> [String] {
        let url = configURL(in: workspaceURL)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return []
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw ObsidianPluginInstallError.communityPluginsConfigInvalid
        }
    }

    static func enable(
        pluginID: String,
        in workspaceURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let url = configURL(in: workspaceURL)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var pluginIDs = try enabledPluginIDs(in: workspaceURL, fileManager: fileManager)
        if !pluginIDs.contains(pluginID) {
            pluginIDs.append(pluginID)
        }
        let data = try JSONEncoder().encode(pluginIDs.sorted())
        try data.write(to: url, options: .atomic)
    }
}

public enum ObsidianAdvancedURIInstaller {
    static let pluginID = "obsidian-advanced-uri"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Vinzent03/obsidian-advanced-uri/releases/latest")!
    private static let requiredAssets = ["manifest.json", "main.js"]
    private static let optionalAssets = ["styles.css"]

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let assets: [Asset]
    }

    public static func pluginDirectory(in workspaceURL: URL) -> URL {
        workspaceURL
            .appending(path: ".obsidian/plugins", directoryHint: .isDirectory)
            .appending(path: pluginID, directoryHint: .isDirectory)
    }

    public static func isInstalledAndEnabled(
        in workspaceURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let pluginDirectory = pluginDirectory(in: workspaceURL)
        let manifestURL = pluginDirectory.appending(path: "manifest.json", directoryHint: .notDirectory)
        let mainJSURL = pluginDirectory.appending(path: "main.js", directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: mainJSURL.path) else {
            return false
        }
        return (try? ObsidianCommunityPluginsStore.enabledPluginIDs(in: workspaceURL, fileManager: fileManager)
            .contains(pluginID)) == true
    }

    public static func installAndEnable(
        in workspaceURL: URL,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) async throws {
        let release = try await fetchLatestRelease(session: session)
        let pluginDirectory = pluginDirectory(in: workspaceURL)
        try fileManager.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)

        let releaseAssets = Dictionary(uniqueKeysWithValues: release.assets.map { ($0.name, $0.browserDownloadURL) })
        for assetName in requiredAssets + optionalAssets {
            guard let assetURL = releaseAssets[assetName] else {
                if requiredAssets.contains(assetName) {
                    throw ObsidianPluginInstallError.missingAsset(assetName)
                }
                continue
            }
            let data = try await download(url: assetURL, session: session)
            try data.write(
                to: pluginDirectory.appending(path: assetName, directoryHint: .notDirectory),
                options: .atomic
            )
        }

        try ObsidianCommunityPluginsStore.enable(
            pluginID: pluginID,
            in: workspaceURL,
            fileManager: fileManager
        )
    }

    private static func fetchLatestRelease(session: URLSession) async throws -> Release {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Rhizome", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ObsidianPluginInstallError.invalidReleaseMetadata
        }
        do {
            return try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw ObsidianPluginInstallError.invalidReleaseMetadata
        }
    }

    private static func download(url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Rhizome", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ObsidianPluginInstallError.badResponse(url)
        }
        return data
    }
}

public enum ObsidianURLBuilder {
    public static func openVaultURL(for workspaceURL: URL) -> URL? {
        openVaultURL(for: workspaceURL, registry: ObsidianVaultRegistry.load())
    }

    static func openVaultURL(for workspaceURL: URL, registry: ObsidianVaultRegistry?) -> URL? {
        guard let vaultIdentifier = registry?.identifier(for: workspaceURL) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultIdentifier)
        ]
        return components.url
    }

    public static func openFileURL(for workspaceURL: URL, relativePath: String) -> URL? {
        let absoluteFile = workspaceURL
            .appending(path: relativePath, directoryHint: .notDirectory)
            .standardizedFileURL
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "path", value: absoluteFile.path)
        ]
        return components.url
    }

    /// Advanced URI plugin URL for opening the graph view. Returns nil if the vault
    /// ID can't be resolved from Obsidian's local registry.
    public static func openGraphURL(for workspaceURL: URL) -> URL? {
        openGraphURL(for: workspaceURL, registry: ObsidianVaultRegistry.load())
    }

    static func openGraphURL(for workspaceURL: URL, registry: ObsidianVaultRegistry?) -> URL? {
        guard let vaultIdentifier = registry?.identifier(for: workspaceURL) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "adv-uri"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultIdentifier),
            URLQueryItem(name: "commandid", value: "graph:open"),
        ]
        return components.url
    }
}

@MainActor
public enum ObsidianOpener {
    public enum Result: Equatable {
        case opened
        case openedVaultForRegistration
        case notInstalled
        case requiresAdvancedURI
        case vaultMissing
        case failed(String)
    }

    static func graphCommandArguments(for workspaceURL: URL) -> [String] {
        ["vault=\(workspaceURL.lastPathComponent)", "command", "id=graph:open"]
    }

    public static func canOpenGraphDirectly(workspaceURL: URL) -> Bool {
        canOpenGraphUsingCLI(workspaceURL: workspaceURL)
            || ObsidianAdvancedURIInstaller.isInstalledAndEnabled(in: workspaceURL)
    }

    @discardableResult
    public static func openWorkspace(_ workspaceURL: URL) -> Result {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            return .vaultMissing
        }
        guard isObsidianInstalled() else {
            return .notInstalled
        }
        if let url = ObsidianURLBuilder.openVaultURL(for: workspaceURL),
           NSWorkspace.shared.open(url) {
            return .opened
        }
        if openWithObsidianUsingOpenCommand([workspaceURL]) {
            return .opened
        }
        return .failed("Obsidian refused to open the vault.")
    }

    @discardableResult
    public static func openNote(notePath: String, workspaceURL: URL) -> Result {
        let fileURL = workspaceURL
            .appending(path: notePath, directoryHint: .notDirectory)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .vaultMissing
        }
        guard isObsidianInstalled() else {
            return .notInstalled
        }
        if let url = ObsidianURLBuilder.openFileURL(for: workspaceURL, relativePath: notePath),
           NSWorkspace.shared.open(url) {
            return .opened
        }
        if openWithObsidianUsingOpenCommand([fileURL]) {
            return .opened
        }
        return .failed("Obsidian refused to open the note.")
    }

    @discardableResult
    public static func openGraph(workspaceURL: URL) -> Result {
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            return .vaultMissing
        }
        guard isObsidianInstalled() else {
            return .notInstalled
        }
        if openGraphUsingCLI(workspaceURL: workspaceURL) {
            activateObsidian()
            return .opened
        }
        guard ObsidianAdvancedURIInstaller.isInstalledAndEnabled(in: workspaceURL) else {
            return .requiresAdvancedURI
        }
        guard let url = ObsidianURLBuilder.openGraphURL(for: workspaceURL) else {
            switch openWorkspace(workspaceURL) {
            case .opened, .openedVaultForRegistration:
                return .openedVaultForRegistration
            case .notInstalled:
                return .notInstalled
            case .requiresAdvancedURI:
                return .requiresAdvancedURI
            case .vaultMissing:
                return .vaultMissing
            case .failed(let message):
                return .failed(message)
            }
        }
        if NSWorkspace.shared.open(url) {
            return .opened
        }
        return .failed("Obsidian refused to open the graph view.")
    }

    public static func isObsidianInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Obsidian.app")
    }

    public static func isObsidianRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").isEmpty
    }

    static func canOpenGraphUsingCLI(
        workspaceURL: URL,
        registry: ObsidianVaultRegistry? = ObsidianVaultRegistry.load(),
        cliExecutableURL: URL? = obsidianCLIExecutableURL()
    ) -> Bool {
        guard let cliExecutableURL,
              FileManager.default.isExecutableFile(atPath: cliExecutableURL.path) else {
            return false
        }
        return registry?.identifier(for: workspaceURL) != nil
    }

    @discardableResult
    static func openGraphUsingCLI(
        workspaceURL: URL,
        runner: ([String]) -> Bool = { runObsidianCLI(arguments: $0) }
    ) -> Bool {
        guard canOpenGraphUsingCLI(workspaceURL: workspaceURL) else {
            return false
        }
        return runner(graphCommandArguments(for: workspaceURL))
    }

    @discardableResult
    private static func openWithObsidianUsingOpenCommand(_ urls: [URL]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Obsidian"] + urls.map(\.path)
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func activateObsidian() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian")
        if let app = running.first {
            app.activate()
            return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    private static func obsidianCLIExecutableURL() -> URL? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") {
            let cliURL = appURL.appending(path: "Contents/MacOS/obsidian", directoryHint: .notDirectory)
            if FileManager.default.isExecutableFile(atPath: cliURL.path) {
                return cliURL
            }
        }

        let fallbackURL = URL(fileURLWithPath: "/Applications/Obsidian.app/Contents/MacOS/obsidian")
        guard FileManager.default.isExecutableFile(atPath: fallbackURL.path) else {
            return nil
        }
        return fallbackURL
    }

    @discardableResult
    private static func runObsidianCLI(arguments: [String]) -> Bool {
        guard let executableURL = obsidianCLIExecutableURL() else {
            return false
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

}
