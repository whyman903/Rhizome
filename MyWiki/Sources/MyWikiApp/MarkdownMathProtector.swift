import Foundation

struct MarkdownMathProtector {
    struct Span {
        let placeholder: String
        let html: String
    }

    struct Result {
        let markdown: String
        let spans: [Span]
    }

    static func protect(_ markdown: String) -> Result {
        var protected = ""
        var spans: [Span] = []
        var index = markdown.startIndex

        func appendSpan(_ range: Range<String.Index>) {
            let placeholder = "MYWIKI_MATH_SPAN_\(spans.count)_END"
            protected += placeholder
            spans.append(Span(placeholder: placeholder, html: escapedHTML(String(markdown[range]))))
        }

        while index < markdown.endIndex {
            if hasPrefix("$$", in: markdown, at: index),
               let range = delimitedRange(in: markdown, from: index, opener: "$$", closer: "$$") {
                appendSpan(range)
                index = range.upperBound
                continue
            }

            if hasPrefix(#"\("#, in: markdown, at: index),
               let range = delimitedRange(in: markdown, from: index, opener: #"\("#, closer: #"\)"#) {
                appendSpan(range)
                index = range.upperBound
                continue
            }

            if hasPrefix(#"\["#, in: markdown, at: index),
               let range = delimitedRange(in: markdown, from: index, opener: #"\["#, closer: #"\]"#) {
                appendSpan(range)
                index = range.upperBound
                continue
            }

            if markdown[index] == "$",
               !isEscaped(in: markdown, at: index),
               !hasPrefix("$$", in: markdown, at: index),
               let range = singleDollarRange(in: markdown, from: index) {
                appendSpan(range)
                index = range.upperBound
                continue
            }

            protected.append(markdown[index])
            index = markdown.index(after: index)
        }

        return Result(markdown: protected, spans: spans)
    }

    static func restore(in html: String, spans: [Span]) -> String {
        spans.reduce(html) { restored, span in
            restored.replacingOccurrences(of: span.placeholder, with: span.html)
        }
    }

    private static func delimitedRange(
        in text: String,
        from openerStart: String.Index,
        opener: String,
        closer: String
    ) -> Range<String.Index>? {
        let contentStart = text.index(openerStart, offsetBy: opener.count)
        guard let closerRange = text.range(of: closer, range: contentStart..<text.endIndex) else {
            return nil
        }
        return openerStart..<closerRange.upperBound
    }

    private static func singleDollarRange(in text: String, from openerStart: String.Index) -> Range<String.Index>? {
        let contentStart = text.index(after: openerStart)
        guard let closerStart = closingSingleDollar(in: text, from: contentStart) else {
            return nil
        }
        return openerStart..<text.index(after: closerStart)
    }

    private static func closingSingleDollar(in text: String, from start: String.Index) -> String.Index? {
        var searchStart = start
        while let range = text.range(of: "$", range: searchStart..<text.endIndex) {
            let candidate = range.lowerBound
            if !isEscaped(in: text, at: candidate), !hasPrefix("$$", in: text, at: candidate) {
                return candidate
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func hasPrefix(_ prefix: String, in text: String, at index: String.Index) -> Bool {
        text[index...].hasPrefix(prefix)
    }

    private static func isEscaped(in text: String, at index: String.Index) -> Bool {
        var backslashCount = 0
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else {
                break
            }
            backslashCount += 1
            cursor = previous
        }
        return backslashCount % 2 == 1
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
