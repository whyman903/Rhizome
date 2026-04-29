import Foundation
import cmark_gfm
import cmark_gfm_extensions
import MyWikiCore

enum MarkdownRenderer {
    static func preprocessMarkdown(_ text: String) -> String {
        var converted = replaceObsidianEmbeds(in: text)

        while let open = converted.range(of: "[[") {
            guard let close = converted.range(of: "]]", range: open.upperBound..<converted.endIndex) else {
                break
            }

            let body = converted[open.upperBound..<close.lowerBound]
            let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            let display = parts.count == 2
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : target

            if target.isEmpty {
                converted.replaceSubrange(open.lowerBound..<close.upperBound, with: String(body))
            } else if let url = WikilinkParser.linkURL(for: target) {
                converted.replaceSubrange(
                    open.lowerBound..<close.upperBound,
                    with: "[\(display)](\(url.absoluteString))"
                )
            } else {
                converted.replaceSubrange(open.lowerBound..<close.upperBound, with: display)
            }
        }

        return converted
    }

    static func renderHTMLBody(_ text: String) -> String {
        let markdown = preprocessMarkdown(text)
        let protected = MarkdownMathProtector.protect(markdown)
        cmark_gfm_core_extensions_ensure_registered()

        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return "<pre>\(escapedHTML(markdown))</pre>"
        }
        defer { cmark_parser_free(parser) }

        for extensionName in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntaxExtension = cmark_find_syntax_extension(extensionName) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        protected.markdown.withCString { buffer in
            cmark_parser_feed(parser, buffer, protected.markdown.utf8.count)
        }

        guard let document = cmark_parser_finish(parser) else {
            return "<pre>\(escapedHTML(markdown))</pre>"
        }
        defer { cmark_node_free(document) }

        guard let html = cmark_render_html(document, CMARK_OPT_DEFAULT, nil) else {
            return "<pre>\(escapedHTML(markdown))</pre>"
        }
        defer { free(html) }

        return MarkdownMathProtector.restore(
            in: MarkdownHTMLPostprocessor.process(String(cString: html)),
            spans: protected.spans
        )
    }

    private static func replaceObsidianEmbeds(in text: String) -> String {
        var converted = text

        while let open = converted.range(of: "![["),
              let close = converted.range(of: "]]", range: open.upperBound..<converted.endIndex) {
            let body = converted[open.upperBound..<close.lowerBound]
            let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let display = parts.count == 2
                ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                : target

            guard !target.isEmpty else {
                converted.replaceSubrange(open.lowerBound..<close.upperBound, with: String(body))
                continue
            }

            if isImageTarget(target), let url = workspaceAssetURL(for: target) {
                converted.replaceSubrange(open.lowerBound..<close.upperBound, with: "![\(display)](\(url))")
            } else if let url = workspaceAssetURL(for: target) {
                converted.replaceSubrange(open.lowerBound..<close.upperBound, with: "[\(display)](\(url))")
            } else {
                converted.replaceSubrange(open.lowerBound..<close.upperBound, with: display)
            }
        }

        return converted
    }

    private static func isImageTarget(_ target: String) -> Bool {
        let path = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let ext = (path as NSString).pathExtension.lowercased()
        return ["avif", "bmp", "gif", "jpeg", "jpg", "png", "svg", "webp"].contains(ext)
    }

    private static func workspaceAssetURL(for target: String) -> String? {
        let path = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (trimmed as NSString).pathExtension.isEmpty == false else {
            return nil
        }

        let encodedPath = trimmed
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        return "\(BundleAssetSchemeHandler.scheme):///workspace/\(encodedPath)"
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
