import AppKit
import SwiftUI
import MyWikiCore

struct QueryDetailView: View {
    @Bindable var model: AppModel
    @State private var followUpText = ""
    @State private var sidebarVisible = false
    @State private var showSettings = false
    @FocusState private var isInputFocused: Bool

    private let minSidebarWidth: CGFloat = 140
    private let maxSidebarWidth: CGFloat = 420
    private let topBarHeight: CGFloat = 42

    var body: some View {
        ZStack(alignment: .top) {
            SplitViewContainer(
                sidebarCollapsed: !sidebarVisible,
                minSidebarWidth: minSidebarWidth,
                maxSidebarWidth: maxSidebarWidth,
                autosaveName: "MyWikiSidebar"
            ) {
                historySidebar
            } detail: {
                VStack(spacing: 0) {
                    if showSettings {
                        SettingsView(model: model, onDismiss: { showSettings = false })
                    } else {
                        conversationArea
                        bottomPanel
                    }
                }
            }
            .padding(.top, topBarHeight)

            topBar
                .frame(height: topBarHeight)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.all, edges: .top)
        .background(WindowChromeConfigurator())
        .background(EditorialPalette.background)
        .id("\(model.theme.rawValue).\(model.font.rawValue)")
        .preferredColorScheme(model.theme.prefersDarkMode ? .dark : .light)
        .alert("Install Advanced URI?", isPresented: $model.showGraphPluginInstallPrompt) {
            Button("Install") {
                Task {
                    await model.installGraphPluginForCurrentWorkspace()
                }
            }
            Button("Not Now", role: .cancel) {
                model.dismissGraphPluginInstallPrompt()
            }
        } message: {
            Text("Graph view now uses the Advanced URI plugin for this vault. MyWiki will add the plugin files to .obsidian/plugins and enable them without requesting Accessibility access.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 70, height: 1)

            ChromeIconButton(
                systemName: "sidebar.left",
                isActive: sidebarVisible,
                help: sidebarVisible ? "Hide history" : "Show history"
            ) {
                sidebarVisible.toggle()
            }

            Spacer(minLength: 12)

            TitleChip(
                text: model.querySession.firstQuestion.isEmpty
                    ? "New Query"
                    : String(model.querySession.firstQuestion.prefix(50))
            )

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                ChromeIconButton(
                    systemName: "plus",
                    isActive: false,
                    help: "New query"
                ) {
                    model.startNewQuery()
                    followUpText = ""
                    isInputFocused = true
                }

                ChromeIconButton(
                    systemName: "gearshape",
                    isActive: showSettings,
                    help: showSettings ? "Back" : "Settings"
                ) {
                    showSettings.toggle()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Conversation

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.querySession.turns) { turn in
                        turnView(turn)
                    }

                    if model.querySession.status == .running || model.querySession.status == .failed {
                        activeTurnView
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(EditorialPalette.background)
            .onChange(of: model.querySession.turns.count) {
                withAnimation {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.querySession.assistantText) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private func turnView(_ turn: QueryTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionHeader(turn.question)
            MarkdownContentView(text: turn.answer, workspaceURL: model.workspace?.url) { target in
                model.openWikiPage(target: target)
            }
            .padding(.leading, 15)
        }
    }

    @ViewBuilder
    private var activeTurnView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                questionHeader(model.querySession.question)
                Spacer(minLength: 8)
                if model.querySession.status == .running {
                    Button(action: { model.cancelQuery() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(EditorialPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop query")
                }
            }

            if model.querySession.status == .running && model.querySession.assistantText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.querySession.statusDetail.isEmpty
                         ? "Starting…" : model.querySession.statusDetail)
                        .font(.system(size: 13, design: activeFont.design).italic())
                        .foregroundStyle(EditorialPalette.textTertiary)
                }
                .padding(.leading, 15)
            } else if model.querySession.status == .failed {
                Text(model.querySession.errorMessage ?? "Query failed")
                    .font(.system(size: 13))
                    .foregroundStyle(EditorialPalette.warning)
                    .textSelection(.enabled)
                    .padding(.leading, 15)
            } else if !model.querySession.assistantText.isEmpty {
                MarkdownContentView(text: model.querySession.assistantText, workspaceURL: model.workspace?.url) { target in
                    model.openWikiPage(target: target)
                }
                .padding(.leading, 15)
            }
        }
    }

    private func questionHeader(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Circle()
                .fill(EditorialPalette.accent)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: activeFont.design))
                .foregroundStyle(EditorialPalette.textPrimary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Follow-up input

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            followUpBar
            launchRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(EditorialPalette.backgroundTop)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(EditorialPalette.border)
                .frame(height: 1)
        }
    }

    private var followUpBar: some View {
        HStack(spacing: 10) {
            TextField(
                model.querySession.turns.isEmpty ? "Ask the wiki…" : "Ask a follow-up…",
                text: $followUpText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: activeFont.design))
            .foregroundStyle(EditorialPalette.textPrimary)
            .focused($isInputFocused)
            .lineLimit(1...4)
            .onSubmit { submitFollowUp() }

            Button(action: submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? EditorialPalette.textTertiary
                                    : EditorialPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(EditorialPalette.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(EditorialPalette.border, lineWidth: 1)
        )
    }

    private func submitFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpText = ""

        if model.querySession.turns.isEmpty && model.querySession.status == .idle {
            model.sendQuery(text)
        } else {
            model.sendFollowUp(text)
        }
    }

    // MARK: - Launch row

    private var launchRow: some View {
        HStack(spacing: 8) {
            QueryActionButton(
                title: "Terminal",
                action: { model.launchBareClaude() }
            ) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .regular))
            }
            QueryActionButton(
                title: "Obsidian",
                action: { model.openWorkspaceInObsidian() }
            ) {
                ObsidianMark(size: 13)
            }
            QueryActionButton(
                title: "Graph",
                action: { model.openObsidianGraph() }
            ) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .regular))
            }
            QueryActionButton(
                title: "Files",
                action: { model.chooseFilesForIngest() }
            ) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 12, weight: .regular))
            }
        }
    }

    private var hasAnySessions: Bool {
        model.hasActiveQuerySession || !model.sidebarQueryHistory.isEmpty
    }

    // MARK: - History sidebar

    private var historySidebar: some View {
        VStack(spacing: 0) {
            Text("HISTORY")
                .font(.system(size: 10, weight: .bold))
                .kerning(1.3)
                .foregroundStyle(EditorialPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if !hasAnySessions {
                Spacer()
                Text("No queries yet")
                    .font(.system(size: 12, design: activeFont.design).italic())
                    .foregroundStyle(EditorialPalette.textTertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Active session
                        if model.hasActiveQuerySession {
                            sidebarRow(
                                label: model.querySession.firstQuestion,
                                isActive: true,
                                action: {}
                            )
                        }
                        // Archived history
                        ForEach(model.sidebarQueryHistory) { record in
                            sidebarRow(
                                label: record.firstQuestion,
                                isActive: false,
                                action: {
                                    model.selectHistorySession(record)
                                    followUpText = ""
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(EditorialPalette.backgroundTop)
    }

    private func sidebarRow(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, design: activeFont.design))
                .foregroundStyle(isActive
                                 ? EditorialPalette.textPrimary
                                 : EditorialPalette.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    isActive
                        ? RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(EditorialPalette.surface)
                        : nil
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}

private struct ChromeIconButton: View {
    let systemName: String
    let isActive: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(ChromeIconButtonStyle(
            isActive: isActive,
            isHovering: isHovering
        ))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .help(help)
    }

    private var iconColor: Color {
        if isActive { return EditorialPalette.accent }
        if isHovering { return EditorialPalette.textPrimary }
        return EditorialPalette.textSecondary
    }
}

private struct ChromeIconButtonStyle: ButtonStyle {
    let isActive: Bool
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fillColor(pressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(strokeColor, lineWidth: 0.5)
                    )
                    .shadow(
                        color: shadowColor,
                        radius: shadowRadius,
                        x: 0,
                        y: shadowOffset
                    )
                    .opacity(showsBackground(pressed: configuration.isPressed) ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }

    private func showsBackground(pressed: Bool) -> Bool {
        isActive || isHovering || pressed
    }

    private func fillColor(pressed: Bool) -> Color {
        if pressed {
            return EditorialPalette.textPrimary.opacity(0.18)
        }
        if isActive {
            return EditorialPalette.accent.opacity(0.14)
        }
        if isHovering {
            return EditorialPalette.textPrimary.opacity(0.08)
        }
        return Color.clear
    }

    private var strokeColor: Color {
        if isActive {
            return EditorialPalette.accent.opacity(0.22)
        }
        if isHovering {
            return EditorialPalette.textPrimary.opacity(0.08)
        }
        return Color.clear
    }

    private var shadowColor: Color {
        guard isHovering || isActive else { return .clear }
        return Color.black.opacity(0.06)
    }

    private var shadowRadius: CGFloat {
        isHovering || isActive ? 4 : 0
    }

    private var shadowOffset: CGFloat {
        isHovering || isActive ? 1 : 0
    }
}

private struct TitleChip: View {
    let text: String

    @State private var isHovering = false

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium, design: activeFont.design))
            .foregroundStyle(EditorialPalette.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(EditorialPalette.surface.opacity(isHovering ? 0.85 : 0.65))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                EditorialPalette.border.opacity(isHovering ? 0.55 : 0.35),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isHovering = hovering
                }
            }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
    }
}

private struct SplitViewContainer<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let sidebarCollapsed: Bool
    let minSidebarWidth: CGFloat
    let maxSidebarWidth: CGFloat
    let autosaveName: String
    let sidebar: Sidebar
    let detail: Detail

    init(
        sidebarCollapsed: Bool,
        minSidebarWidth: CGFloat,
        maxSidebarWidth: CGFloat,
        autosaveName: String,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebarCollapsed = sidebarCollapsed
        self.minSidebarWidth = minSidebarWidth
        self.maxSidebarWidth = maxSidebarWidth
        self.autosaveName = autosaveName
        self.sidebar = sidebar()
        self.detail = detail()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = autosaveName

        let sidebarHost = NSHostingController(rootView: sidebar)
        let sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = minSidebarWidth
        sidebarItem.maximumThickness = maxSidebarWidth
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.isCollapsed = sidebarCollapsed

        let detailHost = NSHostingController(rootView: detail)
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.canCollapse = false
        detailItem.minimumThickness = 320
        detailItem.holdingPriority = .defaultLow

        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(detailItem)

        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        if let sidebarHost = controller.splitViewItems.first?.viewController as? NSHostingController<Sidebar> {
            sidebarHost.rootView = sidebar
        }
        if let detailHost = controller.splitViewItems.last?.viewController as? NSHostingController<Detail> {
            detailHost.rootView = detail
        }

        if let sidebarItem = controller.splitViewItems.first,
           sidebarItem.isCollapsed != sidebarCollapsed {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                sidebarItem.animator().isCollapsed = sidebarCollapsed
            }
        }
    }
}

private struct QueryActionButton<Icon: View>: View {
    let title: String
    let action: () -> Void
    let icon: Icon

    init(
        title: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.action = action
        self.icon = icon()
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                    .foregroundStyle(isHovering ? EditorialPalette.accent : EditorialPalette.textSecondary)
                    .frame(width: 15, height: 15)
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? EditorialPalette.surface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovering ? EditorialPalette.border : Color.clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
