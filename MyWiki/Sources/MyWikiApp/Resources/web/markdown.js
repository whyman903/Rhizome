(() => {
    const config = window.MyWikiMarkdownConfig || {};

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

    function renderMath() {
        if (!window.renderMathInElement) return;

        renderMathInElement(document.getElementById("content"), {
            delimiters: [
                { left: "$$", right: "$$", display: true },
                { left: "$", right: "$", display: false },
                { left: "\\(", right: "\\)", display: false },
                { left: "\\[", right: "\\]", display: true }
            ],
            ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code", "option"],
            throwOnError: false,
            trust: false,
            maxSize: 10,
            maxExpand: 1000
        });
    }

    function enhanceCallouts() {
        document.querySelectorAll("blockquote").forEach((blockquote) => {
            const first = blockquote.querySelector("p");
            if (!first) return;

            const match = (first.textContent || "").match(/^\[!([a-zA-Z0-9_-]+)\]([+-])?\s*(.*)$/);
            if (!match) return;

            blockquote.classList.add("callout", `callout-${match[1].toLowerCase()}`);

            const title = document.createElement("div");
            title.className = "callout-title";
            title.textContent = match[3] || match[1].toLowerCase();

            blockquote.insertBefore(title, blockquote.firstChild);
            first.remove();
        });
    }

    function interceptWikiLinks() {
        document.addEventListener("click", (event) => {
            const link = event.target.closest && event.target.closest("a[href]");
            if (!link || !link.href.startsWith("mywiki://page?")) return;

            event.preventDefault();
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wikiLink;
            if (handler) handler.postMessage(link.href);
        });
    }

    async function renderMermaid() {
        const blocks = Array.from(document.querySelectorAll("pre.mermaid"));
        if (!blocks.length || !window.mermaid) return;

        mermaid.initialize({
            startOnLoad: false,
            securityLevel: "strict",
            theme: "base",
            deterministicIds: true,
            deterministicIDSeed: "mywiki",
            maxTextSize: 50000,
            suppressErrorRendering: true,
            fontFamily: config.fontFamily,
            themeVariables: config.mermaidThemeVariables || {}
        });

        for (const [index, block] of blocks.entries()) {
            const replacement = document.createElement("div");
            replacement.className = "mermaid-rendered";

            try {
                const result = await mermaid.render(`mywiki-mermaid-${index}`, block.textContent || "");
                replacement.innerHTML = window.DOMPurify
                    ? DOMPurify.sanitize(result.svg, { ADD_TAGS: ["style"], ADD_ATTR: ["dominant-baseline"] })
                    : result.svg;
                if (result.bindFunctions) result.bindFunctions(replacement);
            } catch (error) {
                replacement.classList.add("mermaid-error");

                const title = document.createElement("div");
                title.className = "mermaid-error-title";
                title.textContent = "Mermaid diagram failed to render";

                const detail = document.createElement("pre");
                detail.textContent = String(error && error.message ? error.message : error);

                replacement.append(title, detail);
            }

            block.replaceWith(replacement);
            postHeight();
        }
    }

    async function enhanceContent() {
        enhanceCallouts();
        renderMath();
        await renderMermaid();
        postHeight();
    }

    interceptWikiLinks();
    window.addEventListener("load", enhanceContent);
    window.addEventListener("resize", postHeight);

    if (window.ResizeObserver) {
        new ResizeObserver(postHeight).observe(document.body);
    }
})();
