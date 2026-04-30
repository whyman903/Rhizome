import Foundation

enum MarkdownHTMLPostprocessor {
    static func process(_ html: String) -> String {
        decorateInternalLinks(in: transformMermaidCodeBlocks(in: html))
    }

    private static func transformMermaidCodeBlocks(in html: String) -> String {
        let pattern = #"<pre><code class="language-mermaid">([\s\S]*?)</code></pre>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return html
        }

        var converted = html
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: converted),
                  let bodyRange = Range(match.range(at: 1), in: converted) else {
                continue
            }

            converted.replaceSubrange(fullRange, with: "<pre class=\"mywiki-mermaid\">\(converted[bodyRange])</pre>")
        }

        return converted
    }

    private static func decorateInternalLinks(in html: String) -> String {
        let pattern = #"<a href="([^"]+)">"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return html
        }

        var converted = html
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: converted),
                  let hrefRange = Range(match.range(at: 1), in: converted) else {
                continue
            }

            let href = String(converted[hrefRange])
            guard let linkClass = internalLinkClass(for: href) else {
                continue
            }

            converted.replaceSubrange(fullRange, with: "<a class=\"\(linkClass)\" href=\"\(href)\">")
        }

        return converted
    }

    private static func internalLinkClass(for href: String) -> String? {
        if href.hasPrefix("mywiki://page?") {
            return "wiki-link"
        }

        if href.hasPrefix("\(BundleAssetSchemeHandler.scheme):///workspace/") {
            return "file-link"
        }

        return nil
    }
}
