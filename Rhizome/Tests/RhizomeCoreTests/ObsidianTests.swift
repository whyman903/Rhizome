import Foundation
import XCTest
@testable import RhizomeCore

final class ObsidianTests: XCTestCase {
    func testRegistryResolvesExactWorkspaceIdentifier() {
        let registry = ObsidianVaultRegistry(
            vaults: [
                "alpha1234567890ab": .init(path: "/Users/example/wiki"),
                "beta1234567890cd": .init(path: "/Users/example/wiki/wiki"),
            ]
        )

        let workspaceURL = URL(fileURLWithPath: "/Users/example/wiki")

        XCTAssertEqual(registry.identifier(for: workspaceURL), "alpha1234567890ab")
    }

    func testOpenVaultURLUsesVaultIdentifierFromRegistry() {
        let registry = ObsidianVaultRegistry(
            vaults: [
                "abc123def4567890": .init(path: "/Users/example/wiki"),
            ]
        )
        let workspaceURL = URL(fileURLWithPath: "/Users/example/wiki")

        let url = ObsidianURLBuilder.openVaultURL(for: workspaceURL, registry: registry)

        XCTAssertEqual(url?.absoluteString, "obsidian://open?vault=abc123def4567890")
    }

    func testOpenGraphURLUsesAdvancedURIHostAndCommandID() {
        let registry = ObsidianVaultRegistry(
            vaults: [
                "abc123def4567890": .init(path: "/Users/example/wiki"),
            ]
        )
        let workspaceURL = URL(fileURLWithPath: "/Users/example/wiki")

        let url = ObsidianURLBuilder.openGraphURL(for: workspaceURL, registry: registry)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let queryItems = components?.queryItems ?? []

        XCTAssertEqual(components?.scheme, "obsidian")
        XCTAssertEqual(components?.host, "adv-uri")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") }),
            [
                "vault": "abc123def4567890",
                "commandid": "graph:open",
            ]
        )
    }

    func testOpenVaultURLReturnsNilWithoutRegistryMatch() {
        let registry = ObsidianVaultRegistry(
            vaults: [
                "abc123def4567890": .init(path: "/Users/example/other"),
            ]
        )

        XCTAssertNil(
            ObsidianURLBuilder.openVaultURL(
                for: URL(fileURLWithPath: "/Users/example/wiki"),
                registry: registry
            )
        )
    }

    func testCommunityPluginsStoreAddsPluginIDWithoutDroppingExistingOnes() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appending(path: "ObsidianPluginStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let configURL = workspaceURL.appending(path: ".obsidian/community-plugins.json", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(["calendar"]).write(to: configURL, options: .atomic)

        try ObsidianCommunityPluginsStore.enable(pluginID: "obsidian-advanced-uri", in: workspaceURL)

        let enabled = try ObsidianCommunityPluginsStore.enabledPluginIDs(in: workspaceURL)
        XCTAssertEqual(enabled, ["calendar", "obsidian-advanced-uri"])
    }

    func testInstallerStatusRequiresPluginFilesAndEnabledState() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appending(path: "ObsidianPluginStatus-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let pluginDirectory = ObsidianAdvancedURIInstaller.pluginDirectory(in: workspaceURL)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pluginDirectory.appending(path: "manifest.json", directoryHint: .notDirectory))
        try Data("// main".utf8).write(to: pluginDirectory.appending(path: "main.js", directoryHint: .notDirectory))

        XCTAssertFalse(ObsidianAdvancedURIInstaller.isInstalledAndEnabled(in: workspaceURL))

        try ObsidianCommunityPluginsStore.enable(pluginID: "obsidian-advanced-uri", in: workspaceURL)

        XCTAssertTrue(ObsidianAdvancedURIInstaller.isInstalledAndEnabled(in: workspaceURL))
    }
}
