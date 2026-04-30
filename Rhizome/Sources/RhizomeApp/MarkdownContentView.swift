import AppKit
import SwiftUI
import WebKit
import RhizomeCore

struct MarkdownContentView: View {
    let text: String
    var workspaceURL: URL? = nil
    let onOpenWiki: (String) -> Void
    @State private var contentHeight: CGFloat = 1

    var body: some View {
        MarkdownWebView(
            text: text,
            workspaceURL: workspaceURL,
            contentHeight: $contentHeight,
            onOpenWiki: onOpenWiki
        )
        .frame(maxWidth: .infinity, minHeight: 1, idealHeight: contentHeight, maxHeight: contentHeight)
    }

    static func renderHTMLDocument(_ text: String) -> String {
        MarkdownWebView.documentHTML(for: text)
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
        configuration.userContentController.add(context.coordinator, name: "wikiLink")

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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wikiLink")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight, onOpenWiki: onOpenWiki)
    }

    private func updateWebView(_ webView: WKWebView, context: Context) {
        let key = RenderKey(text: text, workspacePath: workspaceURL?.path, font: activeFont, theme: activeTheme)
        guard context.coordinator.renderKey != key else {
            return
        }

        context.coordinator.assetSchemeHandler.setWorkspaceURL(workspaceURL)
        context.coordinator.renderKey = key
        webView.loadHTMLString(Self.documentHTML(for: text), baseURL: Self.assetBaseURL)
    }

    fileprivate static func documentHTML(for text: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(BundleAssetSchemeHandler.scheme): data:; font-src \(BundleAssetSchemeHandler.scheme):; style-src \(BundleAssetSchemeHandler.scheme): 'unsafe-inline'; script-src \(BundleAssetSchemeHandler.scheme): 'unsafe-inline';">
        <link rel="stylesheet" href="/web/katex/katex.min.css">
        <link rel="stylesheet" href="/web/markdown.css">
        <style>
        \(themeStyle)
        </style>
        <script>
        \(configurationScript)
        </script>
        <script src="/web/dompurify/purify.min.js"></script>
        <script src="/web/katex/katex.min.js"></script>
        <script src="/web/katex/auto-render.min.js"></script>
        <script src="/web/mermaid/mermaid.min.js"></script>
        </head>
        <body>
        <div id="content">
        \(MarkdownRenderer.renderHTMLBody(text))
        </div>
        <script src="/web/markdown.js"></script>
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

    private static var backgroundColor: String {
        cssColor(NSColor(EditorialPalette.background))
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

    private static var themeStyle: String {
        let link = cssColor(NSColor(EditorialPalette.link))
        let accent = cssColor(NSColor(EditorialPalette.accent))

        return """
        :root {
            --rhizome-font-family: \(fontFamily);
            --rhizome-background: \(backgroundColor);
            --rhizome-text: \(textColor);
            --rhizome-secondary: \(secondaryColor);
            --rhizome-surface: \(surfaceColor);
            --rhizome-surface-hover: \(cssColor(NSColor(EditorialPalette.surfaceHover)));
            --rhizome-border: \(borderColor);
            --rhizome-border-hover: \(cssColor(NSColor(EditorialPalette.borderHover)));
            --rhizome-link: \(link);
            --rhizome-accent: \(accent);
        }
        """
    }

    private static var configurationScript: String {
        let payload: [String: Any] = [
            "fontFamily": fontFamily,
            "mermaidContrastTextColor": backgroundColor,
            "mermaidThemeVariables": [
                "fontFamily": fontFamily,
                "primaryColor": surfaceColor,
                "primaryTextColor": textColor,
                "primaryBorderColor": borderColor,
                "lineColor": secondaryColor,
                "secondaryColor": surfaceColor,
                "tertiaryColor": "transparent",
                "noteTextColor": textColor,
                "noteBkgColor": surfaceColor,
                "noteBorderColor": borderColor
            ]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            if let json = String(data: data, encoding: .utf8) {
                return "window.RhizomeMarkdownConfig = \(json);"
            }
        } catch {
            assertionFailure("Failed to encode markdown configuration: \(error)")
        }
        return "window.RhizomeMarkdownConfig = {};"
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
            switch message.name {
            case "contentHeight":
                handleContentHeightMessage(message)
            case "wikiLink":
                handleWikiLinkMessage(message)
            default:
                return
            }
        }

        private func handleContentHeightMessage(_ message: WKScriptMessage) {
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

        private func handleWikiLinkMessage(_ message: WKScriptMessage) {
            guard let href = message.body as? String,
                  let url = URL(string: href),
                  let target = WikilinkParser.decodeLinkURL(url) else {
                return
            }

            onOpenWiki(target)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if let target = WikilinkParser.decodeLinkURL(url) {
                onOpenWiki(target)
                decisionHandler(.cancel)
                return
            }

            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
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
