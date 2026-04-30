# Rhizome — visual redesign proposals

> Mockups below are inline SVG. They render in GitHub and in VS Code's markdown preview.
> They are layout/typography sketches, not pixel-perfect comps — treat them as wireframes
> with a color mood, not final art.

---

## 1. What's going wrong right now

Looking at `LauncherView.swift`, the popover has **four competing visual languages fighting each other**:

1. **Rainbow gradients.** The background is black + purple + cyan radial gradients. The header `sparkles` icon is a cyan→purple gradient. The primary button is a cyan→purple gradient. The drop border animates into a cyan→purple gradient. Then each of the three launch tiles introduces a *different* gradient (cyan/blue, purple/violet, pink/magenta). That's five saturated gradients on a 460pt window.
2. **AI-generic iconography.** `sparkles` appears in the header, in the "Ask the Wiki" button state, and in the query response status glyph. Sparkles is the universal "AI slop" signifier in 2025 — every Gemini/ChatGPT/Copilot wrapper uses it. It reads as generic, not yours.
3. **Glow everywhere.** The header icon has a cyan shadow. The primary button has a cyan shadow. Each LaunchTile has a colored drop shadow that intensifies on hover. Glows are a cheap way to fake depth and they date rapidly.
4. **No typographic hierarchy.** Everything is SF Pro at 10–13pt with opacity variations (0.9 / 0.85 / 0.55 / 0.45 / 0.35 / 0.3). You're relying on opacity instead of weight + size to establish rank, so the composition feels flat.

**The root issue:** it looks like a 2023 AI-product template. It's not committing to an aesthetic — it's pastiching several.

Below are three directions that each pick one aesthetic and commit.

---

## 2. Current state (for reference)

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 460 660" width="460" height="660">
  <defs>
    <radialGradient id="curBgA" cx="15%" cy="10%" r="90%">
      <stop offset="0%" stop-color="#3B1F5E" stop-opacity="0.55"/>
      <stop offset="100%" stop-color="#0A0617" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="curBgB" cx="90%" cy="95%" r="80%">
      <stop offset="0%" stop-color="#0E4A66" stop-opacity="0.55"/>
      <stop offset="100%" stop-color="#061221" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="curBtn" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#5AD4FF"/>
      <stop offset="100%" stop-color="#8C66FF"/>
    </linearGradient>
    <linearGradient id="curT1" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#4DD8F2"/>
      <stop offset="100%" stop-color="#1A99E6"/>
    </linearGradient>
    <linearGradient id="curT2" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#A673FF"/>
      <stop offset="100%" stop-color="#734DF2"/>
    </linearGradient>
    <linearGradient id="curT3" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#FF80D9"/>
      <stop offset="100%" stop-color="#D94DA6"/>
    </linearGradient>
  </defs>
  <rect width="460" height="660" rx="12" fill="#05030F"/>
  <rect width="460" height="660" rx="12" fill="url(#curBgA)"/>
  <rect width="460" height="660" rx="12" fill="url(#curBgB)"/>

  <!-- sparkles icon -->
  <text x="22" y="58" font-family="-apple-system" font-size="30" fill="#6EE7FF">✦</text>
  <text x="58" y="50" font-family="-apple-system" font-size="19" font-weight="600" fill="#FFFFFF">walker/wiki</text>
  <text x="58" y="66" font-family="SF Mono, monospace" font-size="11" fill="#FFFFFF" opacity="0.45">~/Downloads/rhizome</text>
  <text x="422" y="54" font-family="-apple-system" font-size="15" fill="#FFFFFF" opacity="0.55">⋯</text>
  <line x1="0" y1="88" x2="460" y2="88" stroke="#FFFFFF" opacity="0.06"/>

  <!-- composer -->
  <rect x="22" y="112" width="416" height="140" rx="14" fill="#FFFFFF" fill-opacity="0.04" stroke="#FFFFFF" stroke-opacity="0.12"/>
  <text x="38" y="142" font-family="-apple-system" font-size="13" fill="#FFFFFF" opacity="0.35">Drop files, paste a URL, or ask Claude anything… ⌘↩ to send.</text>
  <rect x="36" y="212" width="100" height="30" rx="9" fill="#FFFFFF" fill-opacity="0.05" stroke="#FFFFFF" stroke-opacity="0.12"/>
  <text x="54" y="232" font-family="-apple-system" font-size="12" fill="#FFFFFF" opacity="0.75">📎 Choose File</text>
  <rect x="160" y="212" width="264" height="30" rx="11" fill="url(#curBtn)"/>
  <text x="212" y="232" font-family="-apple-system" font-size="13" font-weight="600" fill="#FFFFFF">✦ Ask the Wiki   ⌘↩</text>

  <!-- action row: 3 saturated tiles -->
  <g transform="translate(22, 272)">
    <rect x="0" y="0" width="134" height="98" rx="14" fill="#FFFFFF" fill-opacity="0.04" stroke="#FFFFFF" stroke-opacity="0.12"/>
    <circle cx="67" cy="34" r="23" fill="url(#curT1)"/>
    <text x="58" y="40" font-family="-apple-system" font-size="16" fill="#FFFFFF">⌘</text>
    <text x="46" y="74" font-family="-apple-system" font-size="12" font-weight="600" fill="#FFFFFF">Terminal</text>
    <text x="33" y="88" font-family="-apple-system" font-size="10" fill="#FFFFFF" opacity="0.45">Blank Claude session</text>

    <rect x="141" y="0" width="134" height="98" rx="14" fill="#FFFFFF" fill-opacity="0.04" stroke="#FFFFFF" stroke-opacity="0.12"/>
    <circle cx="208" cy="34" r="23" fill="url(#curT2)"/>
    <text x="200" y="40" font-family="-apple-system" font-size="15" fill="#FFFFFF">◈</text>
    <text x="190" y="74" font-family="-apple-system" font-size="12" font-weight="600" fill="#FFFFFF">Obsidian</text>
    <text x="192" y="88" font-family="-apple-system" font-size="10" fill="#FFFFFF" opacity="0.45">Open vault</text>

    <rect x="282" y="0" width="134" height="98" rx="14" fill="#FFFFFF" fill-opacity="0.04" stroke="#FFFFFF" stroke-opacity="0.12"/>
    <circle cx="349" cy="34" r="23" fill="url(#curT3)"/>
    <text x="341" y="40" font-family="-apple-system" font-size="15" fill="#FFFFFF">⬢</text>
    <text x="334" y="74" font-family="-apple-system" font-size="12" font-weight="600" fill="#FFFFFF">Graph</text>
    <text x="326" y="88" font-family="-apple-system" font-size="10" fill="#FFFFFF" opacity="0.45">Network view</text>
  </g>

  <line x1="0" y1="390" x2="460" y2="390" stroke="#FFFFFF" opacity="0.06"/>

  <text x="22" y="416" font-family="-apple-system" font-size="10" font-weight="600" fill="#FFFFFF" opacity="0.45" letter-spacing="1.2">RECENT SESSIONS</text>
  <text x="380" y="416" font-family="-apple-system" font-size="10" fill="#FFFFFF" opacity="0.35">12 total</text>

  <g transform="translate(22, 430)">
    <rect x="0" y="0" width="416" height="38" rx="9" fill="#FFFFFF" fill-opacity="0.025" stroke="#FFFFFF" stroke-opacity="0.06"/>
    <text x="14" y="17" font-family="-apple-system" font-size="11" fill="#6EE7FF">✓</text>
    <text x="30" y="18" font-family="SF Mono, monospace" font-size="12" fill="#FFFFFF" opacity="0.9">how does compile handle source ex…</text>
    <text x="30" y="31" font-family="-apple-system" font-size="10" fill="#FFFFFF" opacity="0.4">Claude session</text>
    <text x="380" y="23" font-family="SF Mono, monospace" font-size="10" fill="#FFFFFF" opacity="0.35">2m</text>
  </g>
  <g transform="translate(22, 476)">
    <rect x="0" y="0" width="416" height="38" rx="9" fill="#FFFFFF" fill-opacity="0.025" stroke="#FFFFFF" stroke-opacity="0.06"/>
    <text x="14" y="17" font-family="-apple-system" font-size="11" fill="#6EE7FF">✓</text>
    <text x="30" y="18" font-family="SF Mono, monospace" font-size="12" fill="#FFFFFF" opacity="0.9">ingest https://example.com/essay</text>
    <text x="30" y="31" font-family="-apple-system" font-size="10" fill="#FFFFFF" opacity="0.4">URL ingest</text>
    <text x="374" y="23" font-family="SF Mono, monospace" font-size="10" fill="#FFFFFF" opacity="0.35">14m</text>
  </g>
  <g transform="translate(22, 522)">
    <rect x="0" y="0" width="416" height="38" rx="9" fill="#FFFFFF" fill-opacity="0.025" stroke="#FFFFFF" stroke-opacity="0.06"/>
    <text x="14" y="17" font-family="-apple-system" font-size="11" fill="#6EE7FF">✓</text>
    <text x="30" y="18" font-family="SF Mono, monospace" font-size="12" fill="#FFFFFF" opacity="0.9">summarize recent notes on attent…</text>
    <text x="30" y="31" font-family="-apple-system" font-size="10" fill="#FFFFFF" opacity="0.4">Claude session</text>
    <text x="378" y="23" font-family="SF Mono, monospace" font-size="10" fill="#FFFFFF" opacity="0.35">1h</text>
  </g>
</svg>

---

## 3. Option A — "Editorial" (warm, literary, calm)

**Inspiration:** iA Writer, Reader (Readwise), Things 3, Kindle's serif mode.

**The pitch:** Your app is a *wiki*. It's where you keep what you've read and thought. The interface should feel like a well-kept notebook on a warm desk, not a sci-fi HUD. Warm near-black background, a single muted brass accent, and a serif display face to signal "this is a place for reading and writing," not "this is a chatbot."

### Palette

| Role | Value | Use |
|---|---|---|
| `background`  | `#17120E` | window fill (warm, faintly rust) |
| `surface`     | `#1F1A14` | cards, composer, tiles |
| `border`      | `#2D2620` | 1px hairlines |
| `text.primary`   | `#F5EEDF` | titles, questions |
| `text.secondary` | `#C3B8A0` | body copy, answers |
| `text.tertiary`  | `#7F7260` | metadata, captions |
| `accent`      | `#D4A85A` | primary CTA only — brass, not gold |
| `accent.hover`| `#E4B968` | |

**One accent, used sparingly.** The brass only appears on the Send button and status affirmatives. Everything else is monochrome warm-grey.

### Typography

- **Display** (title, section headers): `.system(.title2, design: .serif)` — that maps to **New York** on macOS. Feels editorial.
- **UI** (buttons, labels, metadata): `.system(.body, design: .default)` — SF Pro Text.
- **Body** (placeholder, long-form answers): `.system(.body, design: .serif)` italic for placeholders, regular for answers. Lets the response feel like it's from a book rather than a terminal.
- **Mono**: avoid except for the very occasional path. SF Mono if you need it.
- **Weight is the hierarchy, not opacity.** Title 500, label 600, body 400, caption 400. Stop doing 0.3 / 0.45 / 0.55 / 0.85 / 0.9.

### Layout changes

- Drop the sparkles. Replace with the workspace topic *as* the title — that's the brand mark.
- Collapse the three launch tiles into a single row of compact cards (no colored icon circles).
- Replace the glowing gradient button with a flat brass rectangle.
- Remove all drop shadows. Replace with a single 1px hairline border and subtle inner fill.

### Mockup

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 460 660" width="460" height="660">
  <defs>
    <linearGradient id="aBg" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#1C1711"/>
      <stop offset="100%" stop-color="#17120E"/>
    </linearGradient>
    <radialGradient id="aVignette" cx="50%" cy="30%" r="80%">
      <stop offset="0%" stop-color="#261E15" stop-opacity="0.5"/>
      <stop offset="100%" stop-color="#17120E" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="460" height="660" rx="12" fill="url(#aBg)"/>
  <rect width="460" height="660" rx="12" fill="url(#aVignette)"/>

  <!-- Header: serif title, no icon -->
  <text x="24" y="58" font-family="'New York', Georgia, serif" font-size="24" font-weight="500" fill="#F5EEDF">walker/wiki</text>
  <text x="24" y="78" font-family="-apple-system, SF Pro Text" font-size="11" fill="#7F7260">142 notes · synced 2m ago</text>
  <circle cx="426" cy="50" r="1.6" fill="#7F7260"/>
  <circle cx="420" cy="50" r="1.6" fill="#7F7260"/>
  <circle cx="414" cy="50" r="1.6" fill="#7F7260"/>

  <line x1="24" y1="102" x2="436" y2="102" stroke="#2D2620" stroke-width="1"/>

  <!-- Composer -->
  <rect x="24" y="122" width="412" height="164" rx="8" fill="#1F1A14" stroke="#2D2620"/>
  <text x="40" y="154" font-family="'New York', Georgia, serif" font-size="15" font-style="italic" fill="#7F7260">What do you want to ask your wiki?</text>
  <line x1="24" y1="244" x2="436" y2="244" stroke="#2D2620" stroke-width="0.75"/>

  <!-- composer footer: ghost attach + brass CTA -->
  <text x="40" y="270" font-family="-apple-system" font-size="11" fill="#C3B8A0" font-weight="500">⎘  Attach</text>
  <rect x="288" y="254" width="132" height="26" rx="5" fill="#D4A85A"/>
  <text x="320" y="272" font-family="-apple-system" font-size="12" font-weight="600" fill="#17120E">Ask   ⌘↩</text>

  <!-- Actions row -->
  <text x="24" y="322" font-family="-apple-system" font-size="10" font-weight="700" fill="#7F7260" letter-spacing="1.3">ACTIONS</text>
  <g transform="translate(24, 334)">
    <rect x="0" y="0" width="134" height="52" rx="6" fill="#1F1A14" stroke="#2D2620"/>
    <text x="14" y="22" font-family="-apple-system" font-size="13" font-weight="600" fill="#F5EEDF">Terminal</text>
    <text x="14" y="38" font-family="-apple-system" font-size="10" fill="#7F7260">Blank session</text>

    <rect x="139" y="0" width="134" height="52" rx="6" fill="#1F1A14" stroke="#2D2620"/>
    <text x="153" y="22" font-family="-apple-system" font-size="13" font-weight="600" fill="#F5EEDF">Obsidian</text>
    <text x="153" y="38" font-family="-apple-system" font-size="10" fill="#7F7260">Open vault</text>

    <rect x="278" y="0" width="134" height="52" rx="6" fill="#1F1A14" stroke="#2D2620"/>
    <text x="292" y="22" font-family="-apple-system" font-size="13" font-weight="600" fill="#F5EEDF">Graph</text>
    <text x="292" y="38" font-family="-apple-system" font-size="10" fill="#7F7260">Network view</text>
  </g>

  <!-- Recent -->
  <text x="24" y="422" font-family="-apple-system" font-size="10" font-weight="700" fill="#7F7260" letter-spacing="1.3">RECENT</text>

  <g transform="translate(24, 438)">
    <text x="0" y="16" font-family="'New York', Georgia, serif" font-size="13" fill="#F5EEDF">How does compile handle source extraction?</text>
    <text x="0" y="32" font-family="-apple-system" font-size="10" fill="#7F7260">2 min · $0.004</text>
  </g>
  <line x1="24" y1="488" x2="436" y2="488" stroke="#2D2620" stroke-width="0.75"/>

  <g transform="translate(24, 500)">
    <text x="0" y="16" font-family="'New York', Georgia, serif" font-size="13" fill="#F5EEDF">ingest https://example.com/essay</text>
    <text x="0" y="32" font-family="-apple-system" font-size="10" fill="#7F7260">14 min ago</text>
  </g>
  <line x1="24" y1="550" x2="436" y2="550" stroke="#2D2620" stroke-width="0.75"/>

  <g transform="translate(24, 562)">
    <text x="0" y="16" font-family="'New York', Georgia, serif" font-size="13" fill="#F5EEDF">summarize recent notes on attention</text>
    <text x="0" y="32" font-family="-apple-system" font-size="10" fill="#7F7260">1 h ago</text>
  </g>
</svg>

**Why this works:** no gradients, no glows, no sparkles. The brass CTA is the only saturated element on the whole screen, so it's unmissable. The serif display face is the visual "voice" — it instantly differentiates this from every other Claude wrapper.

---

## 4. Option B — "Graphite" (cold, precise, developer-grade)

**Inspiration:** Raycast, Linear, Warp, Zed.

**The pitch:** The app is a power tool. Treat it like one. Cold charcoal background, mono for anything with structure (paths, commands, metrics), a single bright accent (mint), crisp 1px borders everywhere. No blur, no gradients — just precise surfaces.

### Palette

| Role | Value | Use |
|---|---|---|
| `background`  | `#0E1013` | window fill |
| `surface`     | `#161920` | composer, cards |
| `surface.raised` | `#1B1F28` | hovered rows |
| `border`      | `#252832` | hairlines |
| `text.primary`   | `#E5E7EC` | |
| `text.secondary` | `#8B919E` | |
| `text.tertiary`  | `#555B68` | metadata |
| `accent`      | `#7DF7A9` | mint — CTA, success, focus |
| `accent.dim`  | `#4AB87A` | pressed state |

One accent only. The mint is used for:
- the primary Send hint (`⌘↩ SEND` bottom-right of the composer),
- recent-item status dots when successful,
- the small square brand mark in the top-left.

That's it. Everything else is grey.

### Typography

- **Display / body**: SF Pro Text (or Inter if you want to feel even more Linear-ish).
- **Mono**: **JetBrains Mono** or **Berkeley Mono** for anything that's structurally code-like — paths, metrics (`$0.004`, `2m`), keyboard hints (`⌘↩`), section labels (`RECENT`). This is the big tell that it's a dev tool, not a consumer app.
- **Weights**: 400 body, 500 labels, 600 titles. Stop at three weights.
- **No italics.** Raycast-language is blocky.

### Layout changes

- Replace sparkles with a small `18×18` filled square brand mark (mint inside a graphite frame).
- The composer is the hero — make it taller and put the attach/send controls on a divider-separated footer inside the composer box (Raycast style).
- Launch tiles become compact rows with a small square icon on the left, not big colored circles.
- Mono-format all metadata: `2m · $0.004 · 3 tools`.

### Mockup

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 460 660" width="460" height="660">
  <rect width="460" height="660" rx="12" fill="#0E1013"/>

  <!-- Brand mark: small square -->
  <rect x="24" y="30" width="26" height="26" rx="5" fill="#16191F" stroke="#252832"/>
  <rect x="32" y="38" width="10" height="10" rx="1.5" fill="#7DF7A9"/>

  <text x="60" y="45" font-family="-apple-system, Inter" font-size="14" font-weight="600" fill="#E5E7EC">walker/wiki</text>
  <text x="60" y="60" font-family="'JetBrains Mono', 'SF Mono', monospace" font-size="10" fill="#555B68">~/notes · 142 files</text>

  <circle cx="426" cy="44" r="1.6" fill="#555B68"/>
  <circle cx="420" cy="44" r="1.6" fill="#555B68"/>
  <circle cx="414" cy="44" r="1.6" fill="#555B68"/>

  <!-- Composer: big, Raycast-style -->
  <rect x="24" y="90" width="412" height="150" rx="10" fill="#161920" stroke="#252832"/>
  <text x="40" y="124" font-family="-apple-system" font-size="14" fill="#555B68">Ask a question, drop a file, or paste a URL…</text>

  <!-- composer footer (inside the box, above a divider) -->
  <line x1="24" y1="200" x2="436" y2="200" stroke="#252832"/>
  <text x="40" y="222" font-family="'JetBrains Mono', monospace" font-size="10" fill="#8B919E">⎘ ATTACH</text>
  <text x="348" y="222" font-family="'JetBrains Mono', monospace" font-size="10" fill="#7DF7A9" font-weight="700" letter-spacing="0.5">⌘↩  SEND</text>

  <!-- Actions: compact icon rows -->
  <text x="24" y="278" font-family="'JetBrains Mono', monospace" font-size="9" fill="#555B68" letter-spacing="1.2">ACTIONS</text>
  <g transform="translate(24, 290)">
    <rect x="0" y="0" width="134" height="56" rx="8" fill="#161920" stroke="#252832"/>
    <rect x="14" y="14" width="26" height="26" rx="4" fill="#1B1F28"/>
    <text x="19" y="32" font-family="'JetBrains Mono', monospace" font-size="12" fill="#7DF7A9" font-weight="700">$_</text>
    <text x="50" y="25" font-family="-apple-system" font-size="12" fill="#E5E7EC" font-weight="600">Terminal</text>
    <text x="50" y="39" font-family="-apple-system" font-size="10" fill="#555B68">Blank Claude</text>

    <rect x="139" y="0" width="134" height="56" rx="8" fill="#161920" stroke="#252832"/>
    <rect x="153" y="14" width="26" height="26" rx="4" fill="#1B1F28"/>
    <text x="159" y="33" font-family="-apple-system" font-size="14" fill="#7DF7A9">◈</text>
    <text x="189" y="25" font-family="-apple-system" font-size="12" fill="#E5E7EC" font-weight="600">Vault</text>
    <text x="189" y="39" font-family="-apple-system" font-size="10" fill="#555B68">Open Obsidian</text>

    <rect x="278" y="0" width="134" height="56" rx="8" fill="#161920" stroke="#252832"/>
    <rect x="292" y="14" width="26" height="26" rx="4" fill="#1B1F28"/>
    <circle cx="300" cy="22" r="2.2" fill="#7DF7A9"/>
    <circle cx="314" cy="28" r="2.2" fill="#7DF7A9"/>
    <circle cx="300" cy="34" r="2.2" fill="#7DF7A9"/>
    <line x1="300" y1="22" x2="314" y2="28" stroke="#7DF7A9" stroke-width="0.8"/>
    <line x1="300" y1="22" x2="300" y2="34" stroke="#7DF7A9" stroke-width="0.8"/>
    <line x1="300" y1="34" x2="314" y2="28" stroke="#7DF7A9" stroke-width="0.8"/>
    <text x="328" y="25" font-family="-apple-system" font-size="12" fill="#E5E7EC" font-weight="600">Graph</text>
    <text x="328" y="39" font-family="-apple-system" font-size="10" fill="#555B68">Network view</text>
  </g>

  <!-- Recent -->
  <text x="24" y="378" font-family="'JetBrains Mono', monospace" font-size="9" fill="#555B68" letter-spacing="1.2">RECENT</text>
  <text x="404" y="378" font-family="'JetBrains Mono', monospace" font-size="9" fill="#555B68" letter-spacing="1.2">12 TOTAL</text>

  <g transform="translate(24, 390)">
    <rect x="0" y="0" width="412" height="44" rx="6" fill="#14171D"/>
    <circle cx="18" cy="22" r="3" fill="#7DF7A9"/>
    <text x="34" y="19" font-family="-apple-system" font-size="12" fill="#E5E7EC">How does compile handle source extraction?</text>
    <text x="34" y="34" font-family="'JetBrains Mono', monospace" font-size="10" fill="#555B68">2m · $0.004 · 3 tools</text>
  </g>

  <g transform="translate(24, 444)">
    <rect x="0" y="0" width="412" height="44" rx="6" fill="#14171D"/>
    <circle cx="18" cy="22" r="3" fill="#7DF7A9"/>
    <text x="34" y="19" font-family="-apple-system" font-size="12" fill="#E5E7EC">ingest https://example.com/essay</text>
    <text x="34" y="34" font-family="'JetBrains Mono', monospace" font-size="10" fill="#555B68">14m · indexed</text>
  </g>

  <g transform="translate(24, 498)">
    <rect x="0" y="0" width="412" height="44" rx="6" fill="#14171D"/>
    <circle cx="18" cy="22" r="3" fill="#7DF7A9"/>
    <text x="34" y="19" font-family="-apple-system" font-size="12" fill="#E5E7EC">summarize recent notes on attention</text>
    <text x="34" y="34" font-family="'JetBrains Mono', monospace" font-size="10" fill="#555B68">1h · $0.012 · 5 tools</text>
  </g>
</svg>

**Why this works:** committing to mono for metadata reads as "this is a precise tool for someone who knows what they're doing." The single mint accent is memorable without being loud. No gradient is ever going to feel dated because there's no gradient at all.

---

## 5. Option C — "Native Menu Bar" (defers to macOS)

**Inspiration:** Apple's own menu-bar apps — Shortcuts, Clock, Reminders in the menu bar, Notification Center.

**The pitch:** You're in a `MenuBarExtra`. Stop fighting the OS. Use `.regularMaterial` for the background (vibrancy aware — it'll tint based on the desktop wallpaper), use `Color.accentColor` so it matches whatever the user picked in System Settings, use `.primary`/`.secondary`/`.tertiary` foreground styles. The whole window costs almost no custom styling and feels *absolutely* at home on macOS.

### Palette

Don't declare a palette. Use:

| Role | Token |
|---|---|
| background     | `.regularMaterial` or `.ultraThickMaterial` |
| surface        | `Color.primary.opacity(0.04)` |
| border         | `Color.primary.opacity(0.1)` |
| text.primary   | `Color.primary` |
| text.secondary | `Color.secondary` |
| text.tertiary  | `Color.secondary.opacity(0.6)` |
| accent         | `Color.accentColor` (user's system accent) |

### Typography

- `.font(.title3)`, `.font(.headline)`, `.font(.body)`, `.font(.callout)`, `.font(.caption)`. Use the semantic scale.
- No custom sizes. No custom weights except `.semibold` for titles.

### Layout changes

- Launch tiles become a `List`-style section with a row per action — native sidebar pattern. Each row has a small `.bordered` rounded-rect icon in the user's accent color, then a title on the left.
- Recent sessions become another `List` section below.
- Header is just a title + subtitle — no brand icon at all.
- Composer uses `TextField(..., axis: .vertical)` with a `.bordered` background.

### Mockup

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 460 660" width="460" height="660">
  <defs>
    <linearGradient id="cBg" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="#2C2C2F"/>
      <stop offset="100%" stop-color="#232326"/>
    </linearGradient>
  </defs>
  <rect width="460" height="660" rx="12" fill="url(#cBg)"/>
  <rect x="0.5" y="0.5" width="459" height="659" rx="12" fill="none" stroke="#3F3F44" stroke-width="1"/>

  <!-- Header -->
  <text x="22" y="44" font-family="-apple-system, SF Pro Display" font-size="17" font-weight="600" fill="#FFFFFF">walker/wiki</text>
  <text x="22" y="62" font-family="-apple-system, SF Pro Text" font-size="11" fill="#9E9EA2">142 notes</text>
  <text x="420" y="48" font-family="-apple-system" font-size="18" fill="#9E9EA2">⋯</text>

  <line x1="0" y1="84" x2="460" y2="84" stroke="#3F3F44" stroke-width="0.5"/>

  <!-- Composer -->
  <rect x="20" y="104" width="420" height="116" rx="8" fill="#1F1F23" stroke="#3F3F44"/>
  <text x="32" y="130" font-family="-apple-system" font-size="13" fill="#6D6D72">Ask Claude, or drop a file…</text>

  <!-- composer footer -->
  <rect x="28" y="186" width="28" height="22" rx="5" fill="transparent" stroke="#5B5B60"/>
  <text x="36" y="202" font-family="-apple-system" font-size="13" fill="#9E9EA2">+</text>
  <rect x="348" y="186" width="86" height="22" rx="5" fill="#0A84FF"/>
  <text x="363" y="202" font-family="-apple-system" font-size="11" fill="#FFFFFF" font-weight="600">Send ⌘↩</text>

  <!-- Quick Actions - native list rows -->
  <text x="22" y="254" font-family="-apple-system" font-size="11" fill="#9E9EA2" font-weight="600">Quick Actions</text>

  <g transform="translate(20, 266)">
    <rect x="0" y="0" width="420" height="38" rx="6" fill="transparent"/>
    <rect x="10" y="9" width="20" height="20" rx="4.5" fill="#0A84FF" fill-opacity="0.18"/>
    <text x="16" y="24" font-family="-apple-system" font-size="12" fill="#0A84FF" font-weight="700">⌘</text>
    <text x="42" y="24" font-family="-apple-system" font-size="13" fill="#FFFFFF">Open Claude Terminal</text>
    <text x="404" y="24" font-family="-apple-system" font-size="13" fill="#6D6D72">›</text>

    <rect x="0" y="40" width="420" height="38" rx="6" fill="transparent"/>
    <rect x="10" y="49" width="20" height="20" rx="4.5" fill="#0A84FF" fill-opacity="0.18"/>
    <text x="16" y="64" font-family="-apple-system" font-size="13" fill="#0A84FF" font-weight="700">◈</text>
    <text x="42" y="64" font-family="-apple-system" font-size="13" fill="#FFFFFF">Open Obsidian Vault</text>
    <text x="404" y="64" font-family="-apple-system" font-size="13" fill="#6D6D72">›</text>

    <rect x="0" y="80" width="420" height="38" rx="6" fill="transparent"/>
    <rect x="10" y="89" width="20" height="20" rx="4.5" fill="#0A84FF" fill-opacity="0.18"/>
    <text x="16" y="104" font-family="-apple-system" font-size="13" fill="#0A84FF" font-weight="700">◎</text>
    <text x="42" y="104" font-family="-apple-system" font-size="13" fill="#FFFFFF">Open Graph View</text>
    <text x="404" y="104" font-family="-apple-system" font-size="13" fill="#6D6D72">›</text>
  </g>

  <line x1="20" y1="400" x2="440" y2="400" stroke="#3F3F44" stroke-width="0.5"/>

  <text x="22" y="428" font-family="-apple-system" font-size="11" fill="#9E9EA2" font-weight="600">Recent Sessions</text>

  <g transform="translate(22, 442)">
    <text x="0" y="18" font-family="-apple-system" font-size="13" fill="#FFFFFF">How does compile handle source extraction?</text>
    <text x="0" y="33" font-family="-apple-system" font-size="11" fill="#6D6D72">2 min ago  ·  $0.004</text>

    <text x="0" y="60" font-family="-apple-system" font-size="13" fill="#FFFFFF">ingest https://example.com/essay</text>
    <text x="0" y="75" font-family="-apple-system" font-size="11" fill="#6D6D72">14 min ago</text>

    <text x="0" y="102" font-family="-apple-system" font-size="13" fill="#FFFFFF">summarize recent notes on attention</text>
    <text x="0" y="117" font-family="-apple-system" font-size="11" fill="#6D6D72">1 hour ago</text>
  </g>
</svg>

**Why this works:** it's the lowest-risk, highest-consistency choice. It will look right on any macOS version forever, and it automatically adapts to the user's system accent color and light/dark mode. The tradeoff: it has no personality of its own. If a user opens it next to Control Center they should feel like it belongs — which is exactly the point, but also means the app never gets to *feel like anything*.

---

## 6. Recommendation

**Pick B (Graphite / Raycast-style).** Here's why:

1. **It matches what the app actually is.** This is a CLI-adjacent, keyboard-first, file-dropping, command-dispatching tool. The user is a power user. Raycast-language signals "I'm useful to you" more than either the editorial brass or the neutral Apple defaults.
2. **It ages the slowest.** No gradients means nothing to look dated. Mono-for-metadata has been stable for 40 years.
3. **It preserves the single-accent discipline** without committing to a polarizing color. Mint reads as "go / success / active" universally.
4. **It makes the composer the hero**, which is correct — the composer is where the user will spend 90% of their time in this window.

**Second choice: A (Editorial).** It's the more distinctive of the three. If what you're going for is "this is a place for *thinking*, not for *executing*," A is more on-brand than B. The risk is that the serif face + brass CTA can read as precious if the rest of the app doesn't match.

**Don't pick C** unless you explicitly want the app to disappear into macOS. It's correct, but it's forgettable.

---

## 7. Changes that apply regardless of direction

Independent of which palette you pick, these would land well:

1. **Delete every `sparkles` icon.** Replace the header icon with either nothing (A), a small brand square (B), or the title alone (C).
2. **Stop using opacity for hierarchy.** Move to 2–3 weights × 3 sizes + 3 concrete text colors.
3. **Remove the three colored-gradient `LaunchTile` circles.** They are the most dated element.
4. **Remove all glow shadows** from buttons and icons. Drop shadows cost depth credibility, not earn it.
5. **Replace the `cyan→purple` primary button gradient** with a single flat accent color. A gradient on a 5-character button adds nothing.
6. **Tighten the vertical rhythm.** Current spacing is `18/14/16/14/18` on a 460pt window, which adds up fast. Drop to a consistent 12pt unit so there's more content density.
7. **Consider a brand mark.** "Rhizome" and ✦ are placeholder-grade. Spend 10 minutes on a 2-character monogram or wordmark and you've instantly added identity.
8. **Don't display the workspace path in the header.** It's noise. Move it to the `ellipsis` menu's first item ("Reveal in Finder: /path/..."). The user already knows which workspace they opened.

---

## 8. Caveats on these mockups

- The SVGs above are **wireframes with a mood**, not pixel comps. They don't try to show blur, real material vibrancy, font kerning, or animation. Treat them as "here's the layout and the palette."
- The real decisions that matter are: **one accent, no gradients, weights-not-opacity, commit to a type voice.** If you get those four right, the rest falls into place.
- If you want, I can turn any one of these into actual Swift code on `LauncherView` so you can see it live.
