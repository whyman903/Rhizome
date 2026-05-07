import AppKit
import SwiftUI
import RhizomeCore

enum QueryDetailPane {
    case conversation
    case watches
    case settings
}

struct QueryDetailView: View {
    @Bindable var model: AppModel
    @Bindable var watchesViewModel: WatchesViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var followUpText = ""
    @AppStorage("RhizomeSidebarVisible") private var sidebarVisible = false
    @State private var activePane: QueryDetailPane = .conversation
    @State private var showingDeleted = false
    @State private var isInputFocused: Bool = false
    @State private var composerHeight: CGFloat = 17

    private let minSidebarWidth: CGFloat = 140
    private let defaultSidebarWidth: CGFloat = 260
    private let maxSidebarWidth: CGFloat = 420
    private let topBarHeight: CGFloat = 42

    var body: some View {
        ZStack(alignment: .top) {
            SplitViewContainer(
                sidebarCollapsed: !sidebarVisible,
                minSidebarWidth: minSidebarWidth,
                defaultSidebarWidth: defaultSidebarWidth,
                maxSidebarWidth: maxSidebarWidth,
                autosaveName: "RhizomeSidebar"
            ) {
                historySidebar
            } detail: {
                VStack(spacing: 0) {
                    switch activePane {
                    case .conversation:
                        conversationArea
                        bottomPanel
                    case .watches:
                        WatchesView(viewModel: watchesViewModel)
                    case .settings:
                        SettingsView(model: model)
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
        .onChange(of: model.watchesPaneRequestToken) { _, _ in
            activePane = .watches
            Task { await watchesViewModel.reload() }
        }
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
            Text("Graph view now uses the Advanced URI plugin for this vault. Rhizome will add the plugin files to .obsidian/plugins and enable them without requesting Accessibility access.")
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
                    systemName: "binoculars",
                    isActive: activePane == .watches,
                    help: activePane == .watches ? "Back" : "Watches"
                ) {
                    if activePane == .watches {
                        activePane = .conversation
                    } else {
                        activePane = .watches
                        Task { await watchesViewModel.reload() }
                    }
                }

                ChromeIconButton(
                    systemName: "plus",
                    isActive: false,
                    help: "New query"
                ) {
                    activePane = .conversation
                    model.startNewQuery()
                    followUpText = ""
                    isInputFocused = true
                }

                ChromeIconButton(
                    systemName: "gearshape",
                    isActive: activePane == .settings,
                    help: activePane == .settings ? "Back" : "Settings"
                ) {
                    activePane = activePane == .settings ? .conversation : .settings
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
            .overlayScrollers()
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
        VStack(alignment: .leading, spacing: 6) {
            questionHeader(turn.question)
            MarkdownContentView(text: turn.answer, workspaceURL: model.workspace?.url) { target in
                model.openWikiPage(target: target)
            }
            .padding(.leading, 15)
            if !turn.answer.isEmpty {
                CopyMarkdownButton(text: turn.answer)
                    .padding(.leading, 11)
            }
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
                    QueryGraphLoadingIndicator(color: EditorialPalette.accent)
                        .frame(width: 24, height: 24)
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
        ZStack(alignment: .bottomTrailing) {
            ChatComposer(
                text: $followUpText,
                contentHeight: $composerHeight,
                isFocused: $isInputFocused,
                placeholder: model.querySession.turns.isEmpty ? "Ask the wiki…" : "Ask a follow-up…",
                font: composerNSFont,
                textColor: NSColor(EditorialPalette.textPrimary),
                placeholderColor: NSColor(EditorialPalette.textTertiary),
                onSubmit: submitFollowUp
            )
            .frame(height: clampedComposerHeight)

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
            .padding(.trailing, 16)
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

    private var composerNSFont: NSFont {
        activeFont.nsFont(size: 13)
    }

    private var composerLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: composerNSFont)
    }

    private var clampedComposerHeight: CGFloat {
        let line = composerLineHeight
        let maxHeight = line * 18
        return Swift.min(Swift.max(composerHeight, line), maxHeight)
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
                title: "Watches",
                action: {
                    activePane = .watches
                    Task { await watchesViewModel.reload() }
                }
            ) {
                Image(systemName: "binoculars")
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
        model.hasActiveQuerySession
            || !model.sidebarPendingQuerySessions.isEmpty
            || !model.sidebarQueryHistory.isEmpty
    }

    // MARK: - History sidebar

    private var historySidebar: some View {
        VStack(spacing: 0) {
            if showingDeleted {
                deletedSidebarContent
            } else {
                historySidebarContent
            }

            sidebarFooter
        }
        .background(EditorialPalette.backgroundTop)
    }

    private var historySidebarContent: some View {
        VStack(spacing: 0) {
            sidebarSectionHeader("HISTORY")
                .padding(.top, 14)

            if !hasAnySessions {
                Spacer()
                Text("No queries yet")
                    .font(.system(size: 12, design: activeFont.design).italic())
                    .foregroundStyle(EditorialPalette.textTertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.hasUnsavedActiveQuerySession {
                            sidebarRow(
                                label: model.querySession.firstQuestion,
                                isActive: true,
                                action: {
                                    activePane = .conversation
                                }
                            )
                        }
                        ForEach(model.sidebarPendingQuerySessions) { session in
                            sidebarRow(
                                label: session.firstQuestion,
                                isActive: session.id == model.querySession.id,
                                action: {
                                    model.selectPendingQuerySession(session)
                                    followUpText = ""
                                    showSettings = false
                                }
                            )
                        }
                        ForEach(model.sidebarQueryHistory) { record in
                            sidebarRow(
                                label: record.firstQuestion,
                                isActive: record.id == model.querySession.id,
                                action: {
                                    model.selectHistorySession(record)
                                    followUpText = ""
                                    activePane = .conversation
                                },
                                onDelete: {
                                    model.deleteHistorySession(record)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .overlayScrollers()
            }
        }
    }

    private var deletedSidebarContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { showingDeleted = false }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(EditorialPalette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to history")

                Text("RECENTLY DELETED")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(1.3)
                    .foregroundStyle(EditorialPalette.textTertiary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if model.sidebarDeletedQueryHistory.isEmpty {
                Spacer()
                Text("Nothing recently deleted")
                    .font(.system(size: 12, design: activeFont.design).italic())
                    .foregroundStyle(EditorialPalette.textTertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sidebarDeletedQueryHistory) { record in
                            deletedSidebarRow(record: record)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .overlayScrollers()
            }
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 0) {
            if showingDeleted {
                if !model.sidebarDeletedQueryHistory.isEmpty {
                    Button(action: { model.emptyDeletedHistory() }) {
                        Text("Empty")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(EditorialPalette.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Permanently delete everything in Recently Deleted")
                }
                Spacer()
            } else {
                Spacer()
                Button(action: { showingDeleted = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(EditorialPalette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Recently Deleted")
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(EditorialPalette.textTertiary.opacity(0.18))
                .frame(height: 1)
        }
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .kerning(1.3)
            .foregroundStyle(EditorialPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }

    private func deletedSidebarRow(record: QueryHistoryRecord) -> some View {
        SidebarHistoryRow(
            label: record.firstQuestion,
            isActive: false,
            font: activeFont,
            isDimmed: true,
            action: {
                model.restoreHistorySession(record)
                followUpText = ""
                activePane = .conversation
                showingDeleted = false
            },
            onDelete: {
                model.permanentlyDeleteHistorySession(record)
            },
            deleteIcon: "xmark",
            deleteHelp: "Delete permanently",
            extraContextActions: [
                .init(title: "Restore Chat", systemImage: "arrow.uturn.backward", role: nil) {
                    model.restoreHistorySession(record)
                    followUpText = ""
                    activePane = .conversation
                    showingDeleted = false
                }
            ],
            deleteContextTitle: "Delete Permanently"
        )
        .padding(.horizontal, 4)
    }

    private func sidebarRow(
        label: String,
        isActive: Bool,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        SidebarHistoryRow(
            label: label,
            isActive: isActive,
            font: activeFont,
            action: action,
            onDelete: onDelete
        )
        .padding(.horizontal, 4)
    }
}

struct SidebarRowContextAction {
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    init(title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.action = action
    }
}

private struct SidebarHistoryRow: View {
    let label: String
    let isActive: Bool
    let font: AppFont
    var isDimmed: Bool = false
    let action: () -> Void
    let onDelete: (() -> Void)?
    var deleteIcon: String = "trash"
    var deleteHelp: String = "Delete chat"
    var extraContextActions: [SidebarRowContextAction] = []
    var deleteContextTitle: String = "Delete Chat"

    @State private var isHovering = false

    private var foreground: Color {
        if isActive { return EditorialPalette.textPrimary }
        if isDimmed { return EditorialPalette.textTertiary }
        return EditorialPalette.textSecondary
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 12, design: font.design))
                    .foregroundStyle(foreground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .padding(.trailing, onDelete != nil ? 22 : 0)
                    .background(
                        isActive
                            ? RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(EditorialPalette.surface)
                            : nil
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDelete, isHovering {
                Button(action: onDelete) {
                    Image(systemName: deleteIcon)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(EditorialPalette.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(deleteHelp)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            ForEach(0..<extraContextActions.count, id: \.self) { idx in
                let item = extraContextActions[idx]
                Button(role: item.role, action: item.action) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label(deleteContextTitle, systemImage: "trash")
                }
            }
        }
    }
}

private struct QueryGraphLoadingIndicator: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let nodes: [GraphNode] = [
        GraphNode(x: 380, y: 380, radius: 74),
        GraphNode(x: 640, y: 540, radius: 60),
        GraphNode(x: 200, y: 220, radius: 42),
        GraphNode(x: 600, y: 280, radius: 42),
        GraphNode(x: 280, y: 600, radius: 42),
        GraphNode(x: 820, y: 420, radius: 42),
        GraphNode(x: 780, y: 780, radius: 42),
        GraphNode(x: 500, y: 800, radius: 42),
    ]
    private let edges: [(Int, Int)] = [
        (0, 2), (0, 3), (0, 4), (0, 1),
        (1, 5), (1, 6), (1, 7),
        (4, 7), (3, 5),
    ]
    private let pulseOrder = [2, 0, 3, 5, 1, 6, 7, 4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                drawGraph(
                    in: &context,
                    size: size,
                    elapsed: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func drawGraph(in context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let scale = min(size.width, size.height) / 1024
        let xOffset = (size.width - 1024 * scale) / 2
        let yOffset = (size.height - 1024 * scale) / 2
        let edgeWidth = max(1.1, 40 * scale)

        for (a, b) in edges {
            let start = point(for: nodes[a], scale: scale, xOffset: xOffset, yOffset: yOffset)
            let end = point(for: nodes[b], scale: scale, xOffset: xOffset, yOffset: yOffset)
            let activity = max(pulseAmount(for: a, elapsed: elapsed), pulseAmount(for: b, elapsed: elapsed))
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(
                path,
                with: .color(color.opacity(0.16 + activity * 0.18)),
                style: StrokeStyle(lineWidth: edgeWidth, lineCap: .round)
            )
        }

        for (index, node) in nodes.enumerated() {
            let activity = pulseAmount(for: index, elapsed: elapsed)
            let center = point(for: node, scale: scale, xOffset: xOffset, yOffset: yOffset)
            let radius = max(1.8, node.radius * scale * (1 + activity * 0.26))
            let glowRadius = radius * (2.0 + activity * 1.25)

            if activity > 0.02 {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - glowRadius,
                        y: center.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )),
                    with: .color(color.opacity(activity * 0.14))
                )
            }

            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(color.opacity(0.34 + activity * 0.66))
            )
        }
    }

    private func pulseAmount(for nodeIndex: Int, elapsed: TimeInterval) -> Double {
        guard let orderIndex = pulseOrder.firstIndex(of: nodeIndex) else {
            return 0
        }

        let stepDuration = 0.23
        let cycleDuration = stepDuration * Double(pulseOrder.count)
        let nodeTime = Double(orderIndex) * stepDuration
        let age = (elapsed - nodeTime).truncatingRemainder(dividingBy: cycleDuration)
        let normalizedAge = age >= 0 ? age : age + cycleDuration

        guard normalizedAge < 0.48 else {
            return 0
        }

        let attack = min(normalizedAge / 0.12, 1)
        let fade = max(0, 1 - ((normalizedAge - 0.12) / 0.36))
        return max(0, min(1, attack * fade))
    }

    private func point(
        for node: GraphNode,
        scale: CGFloat,
        xOffset: CGFloat,
        yOffset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: xOffset + node.x * scale,
            y: yOffset + node.y * scale
        )
    }

    private struct GraphNode {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
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
    let defaultSidebarWidth: CGFloat
    let maxSidebarWidth: CGFloat
    let autosaveName: String
    let sidebar: Sidebar
    let detail: Detail

    init(
        sidebarCollapsed: Bool,
        minSidebarWidth: CGFloat,
        defaultSidebarWidth: CGFloat,
        maxSidebarWidth: CGFloat,
        autosaveName: String,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebarCollapsed = sidebarCollapsed
        self.minSidebarWidth = minSidebarWidth
        self.defaultSidebarWidth = defaultSidebarWidth
        self.maxSidebarWidth = maxSidebarWidth
        self.autosaveName = autosaveName
        self.sidebar = sidebar()
        self.detail = detail()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hasAutosavedSidebarWidth: Self.hasAutosavedSplitViewFrames(named: autosaveName))
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = autosaveName

        let sidebarHost = NSHostingController(rootView: sidebar)
        sidebarHost.sizingOptions = []
        sidebarHost.view.frame.size.width = defaultSidebarWidth
        let sidebarItem = NSSplitViewItem(viewController: sidebarHost)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = minSidebarWidth
        sidebarItem.maximumThickness = maxSidebarWidth
        sidebarItem.preferredThicknessFraction = 0.25
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.isCollapsed = sidebarCollapsed

        let detailHost = NSHostingController(rootView: detail)
        detailHost.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.canCollapse = false
        detailItem.minimumThickness = 320
        detailItem.holdingPriority = .defaultLow

        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(detailItem)

        scheduleDefaultSidebarWidthIfNeeded(for: controller, coordinator: context.coordinator)

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
            scheduleDefaultSidebarWidthIfNeeded(
                for: controller,
                coordinator: context.coordinator,
                delay: sidebarCollapsed ? 0 : 0.24
            )
        } else {
            scheduleDefaultSidebarWidthIfNeeded(for: controller, coordinator: context.coordinator)
        }
    }

    private func scheduleDefaultSidebarWidthIfNeeded(
        for controller: NSSplitViewController,
        coordinator: Coordinator,
        delay: TimeInterval = 0
    ) {
        guard !coordinator.hasAutosavedSidebarWidth,
              !coordinator.didApplyDefaultSidebarWidth,
              !sidebarCollapsed else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            applyDefaultSidebarWidthIfNeeded(for: controller, coordinator: coordinator)
        }
    }

    private func applyDefaultSidebarWidthIfNeeded(
        for controller: NSSplitViewController,
        coordinator: Coordinator
    ) {
        guard !coordinator.hasAutosavedSidebarWidth,
              !coordinator.didApplyDefaultSidebarWidth,
              let sidebarItem = controller.splitViewItems.first,
              !sidebarItem.isCollapsed else {
            return
        }

        controller.splitView.layoutSubtreeIfNeeded()

        let detailMinimumWidth: CGFloat = 320
        let availableSidebarWidth = controller.splitView.bounds.width
            - controller.splitView.dividerThickness
            - detailMinimumWidth
        let upperBound = min(maxSidebarWidth, max(minSidebarWidth, availableSidebarWidth))
        let width = min(max(defaultSidebarWidth, minSidebarWidth), upperBound)

        controller.splitView.setPosition(width, ofDividerAt: 0)
        coordinator.didApplyDefaultSidebarWidth = true
    }

    private static func hasAutosavedSplitViewFrames(named autosaveName: String) -> Bool {
        UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
    }

    final class Coordinator {
        let hasAutosavedSidebarWidth: Bool
        var didApplyDefaultSidebarWidth = false

        init(hasAutosavedSidebarWidth: Bool) {
            self.hasAutosavedSidebarWidth = hasAutosavedSidebarWidth
        }
    }
}

private struct CopyMarkdownButton: View {
    let text: String

    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 11, design: activeFont.design))
            }
            .foregroundStyle(iconColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? EditorialPalette.surface : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(copied ? 1 : (isHovering ? 1 : 0.55))
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.15), value: copied)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Copy markdown")
    }

    private var iconColor: Color {
        if copied { return EditorialPalette.accent }
        if isHovering { return EditorialPalette.textPrimary }
        return EditorialPalette.textTertiary
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
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
