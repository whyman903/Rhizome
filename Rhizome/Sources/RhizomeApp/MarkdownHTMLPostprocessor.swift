import Foundation

enum MarkdownHTMLPostprocessor {
    static func process(_ html: String) -> String {
        decorateInternalLinks(in: transformCallouts(in: transformMermaidCodeBlocks(in: html)))
    }

    private struct CalloutHeader {
        let type: String
        let titleHTML: String
        let paragraphRemainderHTML: String?
    }

    private static func transformCallouts(in html: String) -> String {
        var converted = ""
        var cursor = html.startIndex

        while let open = html.range(of: "<blockquote>", range: cursor..<html.endIndex) {
            converted += html[cursor..<open.lowerBound]

            guard let close = matchingBlockquoteClose(in: html, after: open.upperBound) else {
                converted += html[open.lowerBound..<html.endIndex]
                return converted
            }

            let inner = String(html[open.upperBound..<close.lowerBound])
            let transformedInner = transformCallouts(in: inner)
            converted += renderCallout(from: transformedInner) ?? "<blockquote>\(transformedInner)</blockquote>"
            cursor = close.upperBound
        }

        converted += html[cursor..<html.endIndex]
        return converted
    }

    private static func matchingBlockquoteClose(
        in html: String,
        after start: String.Index
    ) -> Range<String.Index>? {
        var depth = 1
        var cursor = start

        while let close = html.range(of: "</blockquote>", range: cursor..<html.endIndex) {
            if let nestedOpen = html.range(of: "<blockquote>", range: cursor..<html.endIndex),
               nestedOpen.lowerBound < close.lowerBound {
                depth += 1
                cursor = nestedOpen.upperBound
                continue
            }

            depth -= 1
            if depth == 0 {
                return close
            }
            cursor = close.upperBound
        }

        return nil
    }

    private static func renderCallout(from blockquoteInnerHTML: String) -> String? {
        guard let firstContent = blockquoteInnerHTML.firstIndex(where: { !$0.isWhitespace }) else {
            return nil
        }

        let content = blockquoteInnerHTML[firstContent..<blockquoteInnerHTML.endIndex]
        guard content.hasPrefix("<p>") else {
            return nil
        }

        let paragraphStart = blockquoteInnerHTML.index(firstContent, offsetBy: 3)
        guard let paragraphClose = blockquoteInnerHTML.range(
            of: "</p>",
            range: paragraphStart..<blockquoteInnerHTML.endIndex
        ) else {
            return nil
        }

        let firstParagraphHTML = String(blockquoteInnerHTML[paragraphStart..<paragraphClose.lowerBound])
        guard let header = parseCalloutHeader(from: firstParagraphHTML) else {
            return nil
        }

        var bodyHTML = ""
        if let paragraphRemainderHTML = header.paragraphRemainderHTML,
           !paragraphRemainderHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bodyHTML += "\n<p>\(paragraphRemainderHTML)</p>"
        }
        bodyHTML += blockquoteInnerHTML[paragraphClose.upperBound..<blockquoteInnerHTML.endIndex]

        return """

        <blockquote class="callout callout-\(header.type)" data-callout="\(header.type)">
        <div class="callout-title">\(header.titleHTML)</div>\(bodyHTML)</blockquote>
        """
    }

    private static func parseCalloutHeader(from firstParagraphHTML: String) -> CalloutHeader? {
        let headerLine: String
        let paragraphRemainderHTML: String?

        if let lineBreak = firstParagraphHTML.firstIndex(of: "\n") {
            headerLine = String(firstParagraphHTML[..<lineBreak])
            paragraphRemainderHTML = String(firstParagraphHTML[firstParagraphHTML.index(after: lineBreak)...])
        } else {
            headerLine = firstParagraphHTML
            paragraphRemainderHTML = nil
        }

        let trimmedHeader = headerLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHeader.hasPrefix("[!") else {
            return nil
        }

        let typeStart = trimmedHeader.index(trimmedHeader.startIndex, offsetBy: 2)
        guard let typeEnd = trimmedHeader[typeStart...].firstIndex(of: "]") else {
            return nil
        }

        let rawType = String(trimmedHeader[typeStart..<typeEnd]).lowercased()
        guard !rawType.isEmpty,
              rawType.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }

        var titleStart = trimmedHeader.index(after: typeEnd)
        if titleStart < trimmedHeader.endIndex,
           trimmedHeader[titleStart] == "+" || trimmedHeader[titleStart] == "-" {
            titleStart = trimmedHeader.index(after: titleStart)
        }
        while titleStart < trimmedHeader.endIndex,
              trimmedHeader[titleStart] == " " || trimmedHeader[titleStart] == "\t" {
            titleStart = trimmedHeader.index(after: titleStart)
        }

        let rawTitle = String(trimmedHeader[titleStart..<trimmedHeader.endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CalloutHeader(
            type: rawType,
            titleHTML: rawTitle.isEmpty ? rawType : rawTitle,
            paragraphRemainderHTML: paragraphRemainderHTML
        )
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

            converted.replaceSubrange(fullRange, with: "<pre class=\"rhizome-mermaid\">\(converted[bodyRange])</pre>")
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
        if href.hasPrefix("rhizome://page?") {
            return "wiki-link"
        }

        if href.hasPrefix("\(BundleAssetSchemeHandler.scheme):///workspace/") {
            return "file-link"
        }

        return nil
    }
}
