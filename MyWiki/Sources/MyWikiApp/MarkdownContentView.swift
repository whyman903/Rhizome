import AppKit
import Darwin
import SwiftUI
import WebKit
import cmark_gfm
import cmark_gfm_extensions
import MyWikiCore

struct MarkdownContentView: View {
    let text: String
    let workspaceURL: URL?
    let onOpenWiki: (String) -> Void
    @State private var contentHeight: CGFloat = 1

    init(text: String, workspaceURL: URL? = nil, onOpenWiki: @escaping (String) -> Void) {
        self.text = text
        self.workspaceURL = workspaceURL
        self.onOpenWiki = onOpenWiki
    }

    var body: some View {
        MarkdownWebView(
            text: text,
            workspaceURL: workspaceURL,
            contentHeight: $contentHeight,
            onOpenWiki: onOpenWiki
        )
        .frame(maxWidth: .infinity, minHeight: 1, idealHeight: contentHeight, maxHeight: contentHeight)
    }

    static func preprocessMarkdown(_ text: String, workspaceURL: URL? = nil) -> String {
        var converted = replaceObsidianEmbeds(in: text, workspaceURL: workspaceURL)

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

    static func renderHTMLBody(_ text: String, workspaceURL: URL? = nil) -> String {
        let markdown = preprocessMarkdown(text, workspaceURL: workspaceURL)
        let protected = protectMathSpans(in: markdown)
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

        return restoreProtectedMathSpans(
            in: postprocessRenderedHTML(String(cString: html)),
            spans: protected.spans
        )
    }

    static func renderHTMLDocument(_ text: String, workspaceURL: URL? = nil) -> String {
        MarkdownWebView.documentHTML(for: text, workspaceURL: workspaceURL)
    }

    static func postprocessRenderedHTML(_ html: String) -> String {
        decorateInternalLinks(in: transformMermaidCodeBlocks(in: html))
    }

    private static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private struct ProtectedMathSpan {
        let placeholder: String
        let html: String
    }

    private struct ProtectedMarkdown {
        let markdown: String
        let spans: [ProtectedMathSpan]
    }

    private static func protectMathSpans(in markdown: String) -> ProtectedMarkdown {
        var protected = ""
        var spans: [ProtectedMathSpan] = []
        var index = markdown.startIndex

        func appendProtectedSpan(_ range: Range<String.Index>) {
            let placeholder = "MYWIKI_MATH_SPAN_\(spans.count)_END"
            protected += placeholder
            spans.append(ProtectedMathSpan(
                placeholder: placeholder,
                html: escapedHTML(String(markdown[range]))
            ))
        }

        while index < markdown.endIndex {
            if hasPrefix("$$", in: markdown, at: index),
               let range = delimitedRange(in: markdown, from: index, opener: "$$", closer: "$$") {
                appendProtectedSpan(range)
                index = range.upperBound
                continue
            }

            if hasPrefix(#"\("#, in: markdown, at: index),
               let range = delimitedRange(in: markdown, from: index, opener: #"\("#, closer: #"\)"#) {
                appendProtectedSpan(range)
                index = range.upperBound
                continue
            }

            if hasPrefix(#"\["#, in: markdown, at: index),
               let range = delimitedRange(in: markdown, from: index, opener: #"\["#, closer: #"\]"#) {
                appendProtectedSpan(range)
                index = range.upperBound
                continue
            }

            if markdown[index] == "$",
               !isEscaped(in: markdown, at: index),
               !hasPrefix("$$", in: markdown, at: index),
               let range = singleDollarRange(in: markdown, from: index) {
                appendProtectedSpan(range)
                index = range.upperBound
                continue
            }

            protected.append(markdown[index])
            index = markdown.index(after: index)
        }

        return ProtectedMarkdown(markdown: protected, spans: spans)
    }

    private static func restoreProtectedMathSpans(in html: String, spans: [ProtectedMathSpan]) -> String {
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

    private static func replaceObsidianEmbeds(in text: String, workspaceURL: URL?) -> String {
        var converted = text

        while let open = converted.range(of: "![["), let close = converted.range(of: "]]", range: open.upperBound..<converted.endIndex) {
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
                converted.replaceSubrange(
                    open.lowerBound..<close.upperBound,
                    with: "![\(display)](\(url))"
                )
            } else if let url = workspaceAssetURL(for: target) {
                converted.replaceSubrange(
                    open.lowerBound..<close.upperBound,
                    with: "[\(display)](\(url))"
                )
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
            .map { component in
                String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
            }
            .joined(separator: "/")

        return "\(BundleAssetSchemeHandler.scheme):///workspace/\(encodedPath)"
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

            let body = converted[bodyRange]
            converted.replaceSubrange(fullRange, with: "<pre class=\"mermaid\">\(body)</pre>")
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

private final class ScrollForwardingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let text: String
    let workspaceURL: URL?
    @Binding var contentHeight: CGFloat
    let onOpenWiki: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            context.coordinator.assetSchemeHandler,
            forURLScheme: BundleAssetSchemeHandler.scheme
        )
        configuration.userContentController.add(context.coordinator, name: "contentHeight")

        let webView = ScrollForwardingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateWebView(webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenWiki = onOpenWiki
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.assetSchemeHandler.setWorkspaceURL(workspaceURL)
        updateWebView(webView, context: context)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, onOpenWiki: onOpenWiki)
    }

    private func updateWebView(_ webView: WKWebView, context: Context) {
        let key = RenderKey(text: text, workspacePath: workspaceURL?.path, font: activeFont, theme: activeTheme)
        guard context.coordinator.renderKey != key else {
            return
        }

        context.coordinator.renderKey = key
        context.coordinator.assetSchemeHandler.setWorkspaceURL(workspaceURL)
        webView.loadHTMLString(Self.documentHTML(for: text, workspaceURL: workspaceURL), baseURL: Self.assetBaseURL)
    }

    fileprivate static func documentHTML(for text: String, workspaceURL: URL? = nil) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(BundleAssetSchemeHandler.scheme): data:; font-src \(BundleAssetSchemeHandler.scheme):; style-src \(BundleAssetSchemeHandler.scheme): 'unsafe-inline'; script-src \(BundleAssetSchemeHandler.scheme): 'unsafe-inline';">
        <link rel="stylesheet" href="/web/katex/katex.min.css">
        <script src="/web/dompurify/purify.min.js"></script>
        <script src="/web/katex/katex.min.js"></script>
        <script src="/web/katex/auto-render.min.js"></script>
        <script src="/web/mermaid/mermaid.min.js"></script>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        <div id="content">
        \(MarkdownContentView.renderHTMLBody(text, workspaceURL: workspaceURL))
        </div>
        <script>
        function postHeight() {
            const body = document.body;
            const html = document.documentElement;
            const height = Math.max(
                body.scrollHeight,
                body.offsetHeight,
                html.clientHeight,
                html.scrollHeight,
                html.offsetHeight
            );
            window.webkit.messageHandlers.contentHeight.postMessage(height);
        }

        var didEnhanceContent = false;

        function renderMath() {
            if (!window.renderMathInElement) return;
            renderMathInElement(document.getElementById('content'), {
                delimiters: [
                    {left: '$$', right: '$$', display: true},
                    {left: '$', right: '$', display: false},
                    {left: '\\\\(', right: '\\\\)', display: false},
                    {left: '\\\\[', right: '\\\\]', display: true}
                ],
                ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code', 'option'],
                throwOnError: false,
                trust: false,
                maxSize: 10,
                maxExpand: 1000
            });
        }

        function enhanceCallouts() {
            document.querySelectorAll('blockquote').forEach((blockquote) => {
                const first = blockquote.querySelector('p');
                if (!first) return;
                const text = first.textContent || '';
                const match = text.match(/^\\[!([a-zA-Z0-9_-]+)\\]([+-])?\\s*(.*)$/);
                if (!match) return;
                const type = match[1].toLowerCase();
                const title = match[3] || type;
                blockquote.classList.add('callout', 'callout-' + type);
                const titleNode = document.createElement('div');
                titleNode.className = 'callout-title';
                titleNode.textContent = title;
                blockquote.insertBefore(titleNode, blockquote.firstChild);
                first.remove();
            });
        }

        async function renderMermaid() {
            const blocks = Array.from(document.querySelectorAll('pre.mermaid'));
            if (!blocks.length || !window.mermaid) return;

            mermaid.initialize({
                startOnLoad: false,
                securityLevel: 'strict',
                theme: 'base',
                deterministicIds: true,
                deterministicIDSeed: 'mywiki',
                maxTextSize: 50000,
                suppressErrorRendering: true,
                fontFamily: \(javascriptStringLiteral(fontFamily)),
                themeVariables: {
                    fontFamily: \(javascriptStringLiteral(fontFamily)),
                    primaryColor: \(javascriptStringLiteral(surfaceColor)),
                    primaryTextColor: \(javascriptStringLiteral(textColor)),
                    primaryBorderColor: \(javascriptStringLiteral(borderColor)),
                    lineColor: \(javascriptStringLiteral(secondaryColor)),
                    secondaryColor: \(javascriptStringLiteral(surfaceColor)),
                    tertiaryColor: 'transparent',
                    noteTextColor: \(javascriptStringLiteral(textColor)),
                    noteBkgColor: \(javascriptStringLiteral(surfaceColor)),
                    noteBorderColor: \(javascriptStringLiteral(borderColor))
                }
            });

            for (const [index, block] of blocks.entries()) {
                const source = block.textContent || '';
                const replacement = document.createElement('div');
                replacement.className = 'mermaid-rendered';
                try {
                    const result = await mermaid.render('mywiki-mermaid-' + index, source);
                    replacement.innerHTML = window.DOMPurify
                        ? DOMPurify.sanitize(result.svg, { ADD_TAGS: ['style'], ADD_ATTR: ['dominant-baseline'] })
                        : result.svg;
                    if (result.bindFunctions) result.bindFunctions(replacement);
                    block.replaceWith(replacement);
                } catch (error) {
                    replacement.classList.add('mermaid-error');
                    const title = document.createElement('div');
                    title.className = 'mermaid-error-title';
                    title.textContent = 'Mermaid diagram failed to render';
                    const detail = document.createElement('pre');
                    detail.textContent = String(error && error.message ? error.message : error);
                    replacement.append(title, detail);
                    block.replaceWith(replacement);
                }
                postHeight();
            }
        }

        async function enhanceContent() {
            if (didEnhanceContent) {
                postHeight();
                return;
            }
            didEnhanceContent = true;
            enhanceCallouts();
            renderMath();
            await renderMermaid();
            postHeight();
        }

        window.addEventListener('load', () => { enhanceContent(); });
        window.addEventListener('resize', postHeight);
        if (window.ResizeObserver) {
            new ResizeObserver(postHeight).observe(document.body);
        }
        enhanceContent();
        setTimeout(postHeight, 0);
        setTimeout(postHeight, 100);
        </script>
        </body>
        </html>
        """
    }

    private static var assetBaseURL: URL {
        URL(string: "\(BundleAssetSchemeHandler.scheme):///")!
    }

    private static var textColor: String {
        cssColor(NSColor(EditorialPalette.textPrimary))
    }

    private static var secondaryColor: String {
        cssColor(NSColor(EditorialPalette.textSecondary))
    }

    private static var surfaceColor: String {
        cssColor(NSColor(EditorialPalette.surface))
    }

    private static var borderColor: String {
        cssColor(NSColor(EditorialPalette.border))
    }

    private static var stylesheet: String {
        let text = textColor
        let secondary = secondaryColor
        let surface = surfaceColor
        let border = borderColor
        let link = cssColor(NSColor(EditorialPalette.link))
        let accent = cssColor(NSColor(EditorialPalette.accent))
        let pillHover = cssColor(NSColor(EditorialPalette.surfaceHover))
        let pillBorderHover = cssColor(NSColor(EditorialPalette.borderHover))

        return """
        :root { color-scheme: light dark; }
        html, body {
            background: transparent;
            color: \(text);
            font-family: \(fontFamily);
            font-size: 14px;
            line-height: 1.45;
            margin: 0;
            overflow: hidden;
            padding: 0;
            user-select: text;
            -webkit-user-select: text;
        }
        * { box-sizing: border-box; }
        body > *:first-child { margin-top: 0; }
        body > *:last-child { margin-bottom: 0; }
        p { margin: 0 0 0.7em; }
        h1, h2, h3, h4, h5, h6 {
            color: \(text);
            font-weight: 650;
            line-height: 1.2;
            margin: 1em 0 0.45em;
        }
        h1 { font-size: 1.45em; }
        h2 { font-size: 1.25em; }
        h3 { font-size: 1.1em; }
        a { color: \(link); text-decoration: underline; }
        a.wiki-link,
        a.file-link {
            background: \(surface);
            border: 1px solid \(border);
            border-radius: 999px;
            color: \(secondary);
            display: inline-block;
            font-size: 0.82em;
            font-weight: 650;
            line-height: 1.15;
            margin: 0 0.08em;
            max-width: min(32rem, 100%);
            overflow: hidden;
            padding: 0.08em 0.58em 0.1em;
            text-decoration: none;
            text-overflow: ellipsis;
            vertical-align: middle;
            white-space: nowrap;
        }
        a.wiki-link:hover,
        a.file-link:hover {
            background: \(pillHover);
            border-color: \(pillBorderHover);
            color: \(text);
        }
        code {
            background: \(surface);
            border-radius: 4px;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.92em;
            padding: 0.08em 0.28em;
        }
        pre {
            background: \(surface);
            border: 1px solid \(border);
            border-radius: 6px;
            margin: 0.8em 0;
            overflow-x: auto;
            padding: 10px 12px;
        }
        pre code { background: transparent; padding: 0; }
        blockquote {
            border-left: 3px solid \(accent);
            color: \(secondary);
            margin: 0.8em 0;
            padding: 0.1em 0 0.1em 0.9em;
        }
        ul, ol { margin: 0.4em 0 0.8em 1.4em; padding: 0; }
        li { margin: 0.2em 0; }
        table {
            border-collapse: collapse;
            display: block;
            margin: 0.9em 0;
            max-width: 100%;
            overflow-x: auto;
            width: max-content;
        }
        th, td {
            border: 1px solid \(border);
            padding: 6px 8px;
            text-align: left;
            vertical-align: top;
        }
        th { background: \(surface); color: \(text); font-weight: 650; }
        td { color: \(text); }
        img {
            border-radius: 6px;
            display: block;
            height: auto;
            margin: 0.8em 0;
            max-width: 100%;
        }
        .katex-display {
            margin: 0.9em 0;
            overflow-x: auto;
            overflow-y: hidden;
            padding: 0.15em 0;
        }
        .mermaid-rendered {
            margin: 0.9em 0;
            max-width: 100%;
            overflow-x: auto;
        }
        .mermaid-rendered svg {
            display: block;
            height: auto;
            max-width: 100%;
        }
        .mermaid-error {
            background: \(surface);
            border: 1px solid \(border);
            border-radius: 6px;
            color: \(secondary);
            padding: 10px 12px;
        }
        .mermaid-error-title {
            color: \(text);
            font-weight: 650;
            margin-bottom: 0.45em;
        }
        .mermaid-error pre {
            border: 0;
            margin: 0;
            padding: 0;
            white-space: pre-wrap;
        }
        blockquote.callout {
            background: \(surface);
            border: 1px solid \(border);
            border-left: 3px solid \(accent);
            border-radius: 6px;
            color: \(text);
            padding: 9px 11px;
        }
        .callout-title {
            color: \(text);
            font-weight: 650;
            margin-bottom: 0.45em;
            text-transform: capitalize;
        }
        blockquote.callout > *:last-child { margin-bottom: 0; }
        hr {
            border: 0;
            border-top: 1px solid \(border);
            margin: 1em 0;
        }
        """
    }

    private static var fontFamily: String {
        switch activeFont {
        case .mono:
            return "ui-monospace, SFMono-Regular, Menlo, monospace"
        case .serif:
            return "\"New York\", ui-serif, Georgia, serif"
        case .sans:
            return "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", sans-serif"
        }
    }

    private static func cssColor(_ color: NSColor) -> String {
        guard let converted = color.usingColorSpace(.sRGB) else {
            return "rgba(0, 0, 0, 1)"
        }
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        return "rgba(\(red), \(green), \(blue), \(converted.alphaComponent))"
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }

    struct RenderKey: Equatable {
        let text: String
        let workspacePath: String?
        let font: AppFont
        let theme: AppTheme
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var contentHeight: Binding<CGFloat>
        var onOpenWiki: (String) -> Void
        var renderKey: RenderKey?
        let assetSchemeHandler = BundleAssetSchemeHandler()

        init(contentHeight: Binding<CGFloat>, onOpenWiki: @escaping (String) -> Void) {
            self.contentHeight = contentHeight
            self.onOpenWiki = onOpenWiki
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight" else {
                return
            }

            let rawHeight: Double?
            if let number = message.body as? NSNumber {
                rawHeight = number.doubleValue
            } else {
                rawHeight = message.body as? Double
            }

            guard let rawHeight else {
                return
            }

            contentHeight.wrappedValue = max(1, ceil(rawHeight))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if let target = WikilinkParser.decodeLinkURL(url) {
                onOpenWiki(target)
                decisionHandler(.cancel)
                return
            }

            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
