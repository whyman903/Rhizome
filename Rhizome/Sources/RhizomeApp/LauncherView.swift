import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RhizomeCore

struct LauncherView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var draftText: String = ""
    @State private var stagedFiles: [URL] = []
    @State private var isDropTargeted = false
    @State private var hiddenHandoffQuestion: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

            statusStrip
                .padding(.horizontal, 24)

            Divider().overlay(EditorialPalette.border)

            composer
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 14)

            queryResponseSection

            actionRow
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .frame(width: 460)
        .background(backgroundLayer)
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
            Text("Graph view now uses the Advanced URI plugin for this vault. Rhizome will add the plugin files to .obsidian/plugins and enable them without requesting Accessibility access.")
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [EditorialPalette.backgroundTop, EditorialPalette.background],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rhizome")
                    .font(.system(size: 22, weight: .medium, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorialPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Reveal in Finder") { model.revealWorkspaceInFinder() }
                Divider()
                if !model.recentWorkspacePaths.isEmpty {
                    Section("Recent Workspaces") {
                        ForEach(model.recentWorkspacePaths.prefix(5), id: \.self) { path in
                            Button(path) { model.selectRecentWorkspace(path) }
                        }
                    }
                    Divider()
                }
                Button("Open Other Workspace…") { model.chooseOtherWorkspace() }
                Divider()
                Button("Quit Rhizome") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EditorialPalette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var subtitleText: String {
        if let workspace = model.workspace {
            return workspace.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return model.statusMessage
    }

    // MARK: - Status strip

    @ViewBuilder
    private var statusStrip: some View {
        if let error = model.lastError {
            statusPill(text: error, tone: .error, onDismiss: { model.lastError = nil })
                .padding(.bottom, 10)
        } else if let toast = model.launcherToast {
            statusPill(text: toast, tone: .success, onDismiss: nil)
                .padding(.bottom, 10)
        }
    }

    private enum Tone { case success, error }

    private func statusPill(text: String, tone: Tone, onDismiss: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone == .success ? EditorialPalette.accent : EditorialPalette.warning)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(EditorialPalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(EditorialPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(EditorialPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(EditorialPalette.border, lineWidth: 1)
        )
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !stagedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(stagedFiles, id: \.self) { url in
                            FileChip(url: url) {
                                stagedFiles.removeAll { $0 == url }
                            }
                        }
                    }
                    .padding(.bottom, 2)
                }
            }

            ZStack(alignment: .topLeading) {
                if draftText.isEmpty {
                    Text(placeholderText)
                        .font(.system(size: 13).italic())
                        .foregroundStyle(EditorialPalette.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                InsetlessTextEditor(
                    text: $draftText,
                    font: .systemFont(ofSize: 13),
                    textColor: NSColor(EditorialPalette.textPrimary),
                    autoFocus: true
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 104, maxHeight: 160)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EditorialPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? EditorialPalette.accent : EditorialPalette.border,
                        lineWidth: isDropTargeted ? 1.5 : 1.0
                    )
                    .animation(.easeOut(duration: 0.15), value: isDropTargeted)
            )
            .dropDestination(for: URL.self) { items, _ in
                let fresh = items.filter { !stagedFiles.contains($0) }
                guard !fresh.isEmpty else { return false }
                stagedFiles.append(contentsOf: fresh)
                return true
            } isTargeted: { isDropTargeted = $0 }

            HStack(spacing: 10) {
                Button {
                    model.chooseFilesForIngest()
                } label: {
                    Label("Attach", systemImage: "paperclip")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle())

                Spacer()

                Button(action: showQueryWindow) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle())
                .help("Open Rhizome window")

                Button(action: launch) {
                    HStack(spacing: 10) {
                        Text(willRouteInApp ? "Ask the Wiki" : "Send to Claude")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 0)
                        Text("⌘↩")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .opacity(0.72)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canLaunch)
                .opacity(canLaunch ? 1 : 0.5)
                .frame(maxWidth: 240)
            }
        }
    }

    private var placeholderText: String {
        if stagedFiles.isEmpty {
            return "What do you want to ask your wiki?"
        }
        return "Optional context for the attached files."
    }

    private var canLaunch: Bool {
        !stagedFiles.isEmpty
            || !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var plainTextLooksLikeURL: Bool {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            return false
        }
        return !trimmed.contains(where: { $0.isWhitespace })
    }

    private var willRouteInApp: Bool {
        stagedFiles.isEmpty && !plainTextLooksLikeURL
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func launch() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if willRouteInApp {
            hiddenHandoffQuestion = nil
            model.sendQuery(trimmed)
            draftText = ""
            return
        }
        let errorBefore = model.lastError
        model.launchDraftSession(files: stagedFiles, text: draftText)
        if model.lastError == errorBefore {
            stagedFiles = []
            draftText = ""
        }
    }

    // MARK: - Query response

    @ViewBuilder
    private var queryResponseSection: some View {
        if model.querySession.status != .idle,
           hiddenHandoffQuestion != model.querySession.question {
            QueryHandoffView(
                session: model.querySession,
                onOpen: { showQueryWindow() },
                onDismiss: {
                    if model.querySession.status == .running {
                        hiddenHandoffQuestion = model.querySession.question
                    } else {
                        model.dismissQueryResponse()
                    }
                }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 10) {
            EditorialLaunchTile(
                title: "Terminal",
                caption: "Blank session",
                action: { model.launchBareClaude() }
            ) {
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .regular))
            }
            EditorialLaunchTile(
                title: "Obsidian",
                caption: "Open vault",
                action: { model.openWorkspaceInObsidian() }
            ) {
                ObsidianMark(size: 15)
            }
            EditorialLaunchTile(
                title: "Graph",
                caption: "Network view",
                action: { model.openObsidianGraph() }
            ) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14, weight: .regular))
            }
        }
    }

    private func showQueryWindow() {
        dismissMenuBarPopup()
        openWindow(id: "query-window")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func dismissMenuBarPopup() {
        for window in NSApplication.shared.windows {
            let name = String(describing: type(of: window))
            if name.contains("MenuBarExtra") || name.contains("NSStatusBarWindow") {
                window.orderOut(nil)
            }
        }
    }
}

// MARK: - Subviews

struct InsetlessTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    var autoFocus: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            container.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.string = text
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.font != font { textView.font = font }
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { self._text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}

private struct FileChip: View {
    let url: URL
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .foregroundStyle(EditorialPalette.accent)
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorialPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(EditorialPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(EditorialPalette.surface))
        .overlay(Capsule().strokeBorder(EditorialPalette.border, lineWidth: 1))
    }

    private var iconName: String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "md", "markdown", "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "heic": return "photo"
        default: return "doc"
        }
    }
}

struct EditorialLaunchTile<Icon: View>: View {
    let title: String
    let caption: String
    let action: () -> Void
    let icon: Icon

    init(
        title: String,
        caption: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.caption = caption
        self.action = action
        self.icon = icon()
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                icon
                    .foregroundStyle(
                        isHovering ? EditorialPalette.accent : EditorialPalette.textSecondary
                    )
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: activeFont.design))
                        .foregroundStyle(EditorialPalette.textPrimary)
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(EditorialPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? EditorialPalette.surfaceHover : EditorialPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHovering ? EditorialPalette.borderHover : EditorialPalette.border,
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct ObsidianMark: View {
    var size: CGFloat = 15
    var lineWidth: CGFloat = 1.3

    var body: some View {
        let w = size
        let h = size
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: w * 0.5,  y: h * 0.04))
                p.addLine(to: CGPoint(x: w * 0.94, y: h * 0.38))
                p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.96))
                p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.96))
                p.addLine(to: CGPoint(x: w * 0.06, y: h * 0.38))
                p.closeSubpath()
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))

            Path { p in
                p.move(to: CGPoint(x: w * 0.5,  y: h * 0.04))
                p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.58))
                p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.96))
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth * 0.85, lineJoin: .round))
            .opacity(0.65)
        }
        .frame(width: w, height: h)
    }
}

// MARK: - Query handoff

private struct QueryHandoffView: View {
    @Bindable var session: QuerySession
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(session.question)
                .font(.system(size: 12, design: activeFont.design))
                .foregroundStyle(EditorialPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button(action: onOpen) {
                Text("Open")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(PrimaryButtonStyle())

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(EditorialPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(EditorialPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(EditorialPalette.border, lineWidth: 1)
        )
    }
}

// MARK: - Button styles

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(EditorialPalette.background)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? EditorialPalette.accentHover
                            : EditorialPalette.accent
                    )
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(EditorialPalette.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? EditorialPalette.surfaceHover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
