(() => {
    const config = window.RhizomeMarkdownConfig || {};

    function postHeight() {
        const content = document.getElementById("content");
        if (!content) return;

        const bounds = content.getBoundingClientRect();
        // Measure rendered markdown, not the WKWebView viewport. The viewport can
        // stay taller than the content in SwiftUI and create persistent blank space.
        const height = Math.max(
            content.scrollHeight,
            content.offsetHeight,
            bounds.height
        );
        window.webkit.messageHandlers.contentHeight.postMessage(Math.max(1, Math.ceil(height)));
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
            if (!link || !link.href.startsWith("rhizome://page?")) return;

            event.preventDefault();
            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.wikiLink;
            if (handler) handler.postMessage(link.href);
        });
    }

    function parseColor(value) {
        if (!value || value === "none" || value === "transparent" || value.startsWith("url(")) return null;

        const match = String(value).trim().match(/^rgba?\(([^)]+)\)$/i);
        if (!match) return null;

        const parts = match[1].split(",").map((part) => Number(part.trim()));
        if (parts.length < 3 || parts.slice(0, 3).some((part) => Number.isNaN(part))) return null;

        return {
            r: Math.max(0, Math.min(255, parts[0])),
            g: Math.max(0, Math.min(255, parts[1])),
            b: Math.max(0, Math.min(255, parts[2])),
            a: parts.length > 3 && !Number.isNaN(parts[3]) ? parts[3] : 1
        };
    }

    function luminance(color) {
        const channel = (value) => {
            const normalized = value / 255;
            return normalized <= 0.03928
                ? normalized / 12.92
                : Math.pow((normalized + 0.055) / 1.055, 2.4);
        };

        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
    }

    function contrastRatio(first, second) {
        const lighter = Math.max(luminance(first), luminance(second));
        const darker = Math.min(luminance(first), luminance(second));
        return (lighter + 0.05) / (darker + 0.05);
    }

    function setMermaidLabelColor(node, color) {
        node.querySelectorAll(".nodeLabel, .nodeLabel *, .label, .label *, text, tspan").forEach((label) => {
            label.style.color = color;
            label.style.fill = color;
        });
    }

    function adjustMermaidLabelContrast(root) {
        const themeVariables = config.mermaidThemeVariables || {};
        const candidateColors = [
            themeVariables.primaryTextColor,
            config.mermaidContrastTextColor,
            getComputedStyle(document.body).color
        ]
            .filter(Boolean)
            .filter((value, index, values) => values.indexOf(value) === index);

        const candidates = candidateColors
            .map((value) => ({ value, color: parseColor(value) }))
            .filter((candidate) => candidate.color);

        if (!candidates.length) return;

        root.querySelectorAll("g.node").forEach((node) => {
            const shape = node.querySelector("rect,circle,ellipse,polygon,path");
            if (!shape) return;

            const fillColor = parseColor(getComputedStyle(shape).fill);
            if (!fillColor || fillColor.a < 0.1) return;

            const label = node.querySelector(".nodeLabel, .label, text, tspan");
            if (!label) return;

            const labelStyle = getComputedStyle(label);
            const currentColor = parseColor(labelStyle.color) || parseColor(labelStyle.fill);
            const currentContrast = currentColor ? contrastRatio(fillColor, currentColor) : 0;
            if (currentContrast >= 4.5) return;

            const best = candidates.reduce((selected, candidate) => {
                const contrast = contrastRatio(fillColor, candidate.color);
                return !selected || contrast > selected.contrast
                    ? { ...candidate, contrast }
                    : selected;
            }, null);

            if (best && best.contrast > currentContrast) {
                setMermaidLabelColor(node, best.value);
            }
        });
    }

    async function renderMermaid() {
        const blocks = Array.from(document.querySelectorAll("pre.rhizome-mermaid"));
        if (!blocks.length || !window.mermaid) return;

        mermaid.initialize({
            startOnLoad: false,
            securityLevel: "strict",
            theme: "base",
            deterministicIds: true,
            deterministicIDSeed: "rhizome",
            maxTextSize: 50000,
            suppressErrorRendering: true,
            fontFamily: config.fontFamily,
            themeVariables: config.mermaidThemeVariables || {}
        });

        for (const [index, block] of blocks.entries()) {
            const replacement = document.createElement("div");
            replacement.className = "mermaid-rendered";

            try {
                const result = await mermaid.render(`rhizome-mermaid-${index}`, block.textContent || "");
                replacement.innerHTML = window.DOMPurify
                    ? DOMPurify.sanitize(result.svg, {
                        ADD_TAGS: ["foreignObject", "foreignobject", "style"],
                        ADD_ATTR: ["dominant-baseline"],
                        HTML_INTEGRATION_POINTS: { foreignobject: true }
                    })
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
            adjustMermaidLabelContrast(replacement);
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
        const content = document.getElementById("content");
        if (content) new ResizeObserver(postHeight).observe(content);
    }
})();
