import Foundation
import WebKit

final class BundleAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "mywiki-asset"

    private let fileManager: FileManager
    private let resourceRoots: [URL]
    private let lock = NSLock()
    private var workspaceRoot: URL?

    init(
        workspaceURL: URL? = nil,
        resourceRoots: [URL] = BundleAssetSchemeHandler.defaultResourceRoots(),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.resourceRoots = resourceRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.workspaceRoot = workspaceURL?.resolvingSymlinksInPath().standardizedFileURL
        super.init()
    }

    func setWorkspaceURL(_ workspaceURL: URL?) {
        lock.lock()
        workspaceRoot = workspaceURL?.resolvingSymlinksInPath().standardizedFileURL
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme?.lowercased() == Self.scheme,
              let fileURL = resolveFileURL(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: url,
                mimeType: Self.mimeType(for: fileURL.pathExtension),
                expectedContentLength: data.count,
                textEncodingName: Self.textEncodingName(for: fileURL.pathExtension)
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func resolveFileURL(for url: URL) -> URL? {
        let components = safePathComponents(for: url)
        guard !components.isEmpty else {
            return nil
        }

        if components.first == "workspace" {
            return resolveWorkspaceFile(components: Array(components.dropFirst()))
        }

        for root in resourceRoots {
            if let candidate = resolve(components: components, under: root) {
                return candidate
            }
        }

        return nil
    }

    private func resolveWorkspaceFile(components: [String]) -> URL? {
        guard let root = currentWorkspaceRoot() else {
            return nil
        }
        return resolve(components: components, under: root)
    }

    private func resolve(components: [String], under root: URL) -> URL? {
        guard !components.isEmpty else {
            return nil
        }

        let candidate = components.reduce(root) { url, component in
            url.appending(path: component, directoryHint: .notDirectory)
        }
        .resolvingSymlinksInPath()
        .standardizedFileURL

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath),
              fileManager.fileExists(atPath: candidate.path) else {
            return nil
        }

        return candidate
    }

    private func currentWorkspaceRoot() -> URL? {
        lock.lock()
        let root = workspaceRoot
        lock.unlock()
        return root
    }

    private func safePathComponents(for url: URL) -> [String] {
        let decodedPath = url.path.removingPercentEncoding ?? url.path
        let components = decodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard components.allSatisfy({ component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.contains("/")
                && !component.contains("\\")
        }) else {
            return []
        }

        return components
    }

    private static func defaultResourceRoots() -> [URL] {
        var roots: [URL] = []
        if let appResources = Bundle.main.resourceURL {
            roots.append(appResources)
        }

        let sourceResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: sourceResources.path) {
            roots.append(sourceResources)
        }

        return roots
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "mjs": return "text/javascript"
        case "json": return "application/json"
        case "woff2": return "font/woff2"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "pdf": return "application/pdf"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    private static func textEncodingName(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "css", "js", "mjs", "json", "svg", "html", "htm":
            return "utf-8"
        default:
            return nil
        }
    }
}
