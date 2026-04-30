import XCTest
@testable import RhizomeApp

final class MarkdownContentViewTests: XCTestCase {
    @MainActor
    func testPreprocessMarkdownConvertsWikiLinksToMarkdownLinks() {
        let processed = MarkdownRenderer.preprocessMarkdown("Open [[Planner|the planner]].")
        XCTAssertEqual(processed, "Open [the planner](rhizome://page?target=Planner).")
    }

    @MainActor
    func testPreprocessMarkdownConvertsImageEmbedsToWorkspaceAssets() {
        let processed = MarkdownRenderer.preprocessMarkdown("See ![[wiki/outputs/chart one.png|chart]].")
        XCTAssertEqual(
            processed,
            "See ![chart](rhizome-asset:///workspace/wiki/outputs/chart%20one.png)."
        )
    }

    @MainActor
    func testPreprocessMarkdownDoesNotMangleDollarDelimitedMath() {
        let processed = MarkdownRenderer.preprocessMarkdown("Formula $x^2 + y^2$ in [[Planner]].")
        XCTAssertEqual(
            processed,
            "Formula $x^2 + y^2$ in [Planner](rhizome://page?target=Planner)."
        )
    }

    @MainActor
    func testRenderHTMLBodyPreservesBackslashMathDelimitersThroughMarkdown() {
        let html = MarkdownRenderer.renderHTMLBody(
            #"Graph \(\mathcal{G} = (\mathcal{V}, \mathcal{E})\) has node states \[\mathbf{x}_t = \mathbf{W}_{\tau(t)} \mathbf{x}\]."#
        )

        XCTAssertTrue(html.contains(#"\(\mathcal{G} = (\mathcal{V}, \mathcal{E})\)"#))
        XCTAssertTrue(html.contains(#"\[\mathbf{x}_t = \mathbf{W}_{\tau(t)} \mathbf{x}\]"#))
    }

    @MainActor
    func testRenderHTMLBodyPreservesLatexCommandsThatCommonMarkWouldEscape() {
        let html = MarkdownRenderer.renderHTMLBody(#"Spacing \(x\!+\,y\) stays intact."#)

        XCTAssertTrue(html.contains(#"\(x\!+\,y\)"#))
    }

    @MainActor
    func testRenderHTMLBodyUsesGitHubFlavoredTables() {
        let html = MarkdownRenderer.renderHTMLBody(
            """
            | Name | Score |
            | --- | ---: |
            | [[Planner]] | **42** |
            """
        )

        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>Name</th>"))
        XCTAssertTrue(html.contains("align=\"right\""))
        XCTAssertTrue(html.contains("class=\"wiki-link\" href=\"rhizome://page?target=Planner\""))
        XCTAssertTrue(html.contains("<strong>42</strong>"))
    }

    @MainActor
    func testRenderHTMLBodyDecoratesInternalLinksOnly() {
        let html = MarkdownRenderer.renderHTMLBody(
            "Open [[Planner]], read ![[Cutting Cards - AI.pdf]], then visit https://example.com."
        )

        XCTAssertTrue(html.contains("<a class=\"wiki-link\" href=\"rhizome://page?target=Planner\">Planner</a>"))
        XCTAssertTrue(html.contains("<a class=\"file-link\" href=\"rhizome-asset:///workspace/Cutting%20Cards%20-%20AI.pdf\">Cutting Cards - AI.pdf</a>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
        XCTAssertFalse(html.contains("class=\"wiki-link\" href=\"https://example.com\""))
        XCTAssertFalse(html.contains("class=\"file-link\" href=\"https://example.com\""))
    }

    @MainActor
    func testRenderHTMLBodyTransformsMermaidCodeBlocks() {
        let html = MarkdownRenderer.renderHTMLBody(
            """
            ```mermaid
            flowchart LR
            A --> B
            ```
            """
        )

        XCTAssertTrue(html.contains("<pre class=\"rhizome-mermaid\">"))
        XCTAssertTrue(html.contains("flowchart LR"))
        XCTAssertTrue(html.contains("A --&gt; B"))
        XCTAssertFalse(html.contains("<pre class=\"mermaid\">"))
        XCTAssertFalse(html.contains("language-mermaid"))
    }

    @MainActor
    func testRenderHTMLDocumentIncludesLocalRendererAssets() {
        let html = MarkdownContentView.renderHTMLDocument("Formula \\(x\\).")

        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("/web/katex/katex.min.css"))
        XCTAssertTrue(html.contains("/web/katex/auto-render.min.js"))
        XCTAssertTrue(html.contains("/web/mermaid/mermaid.min.js"))
        XCTAssertTrue(html.contains("/web/dompurify/purify.min.js"))
        XCTAssertTrue(html.contains("/web/markdown.css"))
        XCTAssertTrue(html.contains("/web/markdown.js"))
        XCTAssertTrue(html.contains("window.RhizomeMarkdownConfig"))
        XCTAssertTrue(html.contains("mermaidContrastTextColor"))
    }
}
