import AppKit
import SwiftUI
import RhizomeCore

@MainActor
@Observable
final class WatchesViewModel {
    var watches: [WatchRecord] = []
    var isLoading = false
    var lastError: String?
    var pendingRunIDs: Set<String> = []

    private let sidecar: WatchSidecarRunning
    private let workspaceProvider: @MainActor () -> URL?
    private let openPageHandler: @MainActor (String) -> Void

    init(
        sidecar: WatchSidecarRunning,
        workspaceProvider: @escaping @MainActor () -> URL?,
        openPageHandler: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.sidecar = sidecar
        self.workspaceProvider = workspaceProvider
        self.openPageHandler = openPageHandler
    }

    func openPage(_ record: WatchRecord) {
        openPageHandler(record.relativePath)
    }

    var workspaceURL: URL? { workspaceProvider() }

    func reload() async {
        guard let url = workspaceProvider() else {
            watches = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            watches = try await sidecar.list(at: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func add(url urlString: String, frequency: String, intent: String, title: String?) async -> Bool {
        guard let workspace = workspaceProvider() else { return false }
        do {
            _ = try await sidecar.add(
                url: urlString,
                frequency: frequency,
                intent: intent,
                title: title,
                at: workspace
            )
            await reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func runOnce(_ record: WatchRecord) async {
        guard let workspace = workspaceProvider() else { return }
        pendingRunIDs.insert(record.id)
        defer { pendingRunIDs.remove(record.id) }
        do {
            _ = try await sidecar.runOnce(record.id, force: false, at: workspace)
            await reload()
        } catch {
            let message = error.localizedDescription
            await reload()
            lastError = message
        }
    }

    func togglePauseResume(_ record: WatchRecord) async {
        guard let workspace = workspaceProvider() else { return }
        do {
            if record.watchStatus == "paused" {
                _ = try await sidecar.resume(record.id, at: workspace)
            } else {
                _ = try await sidecar.pause(record.id, at: workspace)
            }
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func remove(_ record: WatchRecord) async {
        guard let workspace = workspaceProvider() else { return }
        do {
            try await sidecar.remove(record.id, keepPage: false, at: workspace)
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

private struct CountChipPiece: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
}

// MARK: - WatchesView

struct WatchesView: View {
    @Bindable var viewModel: WatchesViewModel
    @State private var showAddForm = false
    @State private var pendingRemoval: WatchRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider().overlay(EditorialPalette.border)

            if let error = viewModel.lastError {
                errorBanner(error)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            if showAddForm {
                ScrollView {
                    WatchEditorCard(
                        onCancel: { withAnimation(.easeOut(duration: 0.16)) { showAddForm = false } },
                        onSubmit: { url, frequency, intent, title in
                            Task {
                                let ok = await viewModel.add(
                                    url: url,
                                    frequency: frequency,
                                    intent: intent,
                                    title: title
                                )
                                if ok {
                                    withAnimation(.easeOut(duration: 0.16)) { showAddForm = false }
                                }
                            }
                        }
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(EditorialPalette.background)
        .task { await viewModel.reload() }
        .alert(
            "Remove this watch?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { record in
            Button("Remove", role: .destructive) {
                Task { await viewModel.remove(record) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { record in
            Text("“\(record.title)” will stop running and its wiki page will be deleted.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Watches")
                .font(.system(size: 14, weight: .semibold, design: activeFont.design))
                .foregroundStyle(EditorialPalette.textPrimary)

            countChip
                .opacity(viewModel.watches.isEmpty ? 0 : 1)

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeOut(duration: 0.16)) { showAddForm.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showAddForm ? "xmark" : "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text(showAddForm ? "Cancel" : "New Watch")
                        .font(.system(size: 11.5, weight: .semibold, design: activeFont.design))
                }
            }
            .buttonStyle(WatchPrimaryButtonStyle(prominent: !showAddForm))
        }
    }

    private var countChipPieces: [CountChipPiece] {
        let total = viewModel.watches.count
        let active = viewModel.watches.filter { $0.watchStatus == "active" && $0.consecutiveFailures == 0 }.count
        let paused = viewModel.watches.filter { $0.watchStatus == "paused" }.count
        let failing = viewModel.watches.filter { $0.consecutiveFailures > 0 }.count
        var pieces: [CountChipPiece] = []
        if active > 0 { pieces.append(.init(label: "\(active) active", color: EditorialPalette.accent)) }
        if paused > 0 { pieces.append(.init(label: "\(paused) paused", color: EditorialPalette.textTertiary)) }
        if failing > 0 { pieces.append(.init(label: "\(failing) failing", color: EditorialPalette.warning)) }
        if pieces.isEmpty && total > 0 {
            pieces.append(.init(label: "\(total) total", color: EditorialPalette.textTertiary))
        }
        return pieces
    }

    private var countChip: some View {
        HStack(spacing: 6) {
            ForEach(countChipPieces) { piece in
                HStack(spacing: 4) {
                    Circle()
                        .fill(piece.color)
                        .frame(width: 5, height: 5)
                    Text(piece.label)
                        .font(.system(size: 10.5, weight: .medium, design: activeFont.design))
                        .foregroundStyle(EditorialPalette.textSecondary)
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(EditorialPalette.warning)
            Text(message)
                .font(.system(size: 11.5, design: activeFont.design))
                .foregroundStyle(EditorialPalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                viewModel.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(EditorialPalette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(EditorialPalette.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(EditorialPalette.warning.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if viewModel.watches.isEmpty {
            if viewModel.isLoading {
                loadingState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !showAddForm {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.watches) { watch in
                        WatchCard(
                            record: watch,
                            isRunning: viewModel.pendingRunIDs.contains(watch.id),
                            onOpen: { viewModel.openPage(watch) },
                            onRun: { Task { await viewModel.runOnce(watch) } },
                            onPause: { Task { await viewModel.togglePauseResume(watch) } },
                            onRemove: { pendingRemoval = watch }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(EditorialPalette.accent)
            Text("Loading watches…")
                .font(.system(size: 11.5, design: activeFont.design).italic())
                .foregroundStyle(EditorialPalette.textTertiary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(EditorialPalette.accent.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: "binoculars.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(EditorialPalette.accent)
            }
            VStack(spacing: 4) {
                Text("No watches yet")
                    .font(.system(size: 14, weight: .semibold, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                Text("Track a URL on a schedule. Each pull becomes a Claude-written page in your wiki.")
                    .font(.system(size: 12, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showAddForm = true }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("New Watch")
                        .font(.system(size: 12, weight: .semibold, design: activeFont.design))
                }
            }
            .buttonStyle(WatchPrimaryButtonStyle(prominent: true))
        }
        .padding(28)
    }
}

// MARK: - WatchCard

private struct WatchCard: View {
    let record: WatchRecord
    let isRunning: Bool
    let onOpen: () -> Void
    let onRun: () -> Void
    let onPause: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(record.title)
                    .font(.system(size: 13, weight: .semibold, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                statusPill
            }

            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(.system(size: 9))
                    .foregroundStyle(EditorialPalette.textTertiary)
                Text(record.url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(EditorialPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if !record.intent.isEmpty {
                Text(record.intent)
                    .font(.system(size: 12, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            metadataRow

            if let lastError = record.lastError, !lastError.isEmpty,
               record.consecutiveFailures > 0 {
                errorRow(lastError)
            }

            actionRow
        }
        .padding(11)
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
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var statusColor: Color {
        if record.consecutiveFailures > 0 { return EditorialPalette.warning }
        switch record.watchStatus {
        case "active": return EditorialPalette.accent
        case "paused": return EditorialPalette.textTertiary
        default: return EditorialPalette.warning
        }
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.system(size: 9, weight: .bold))
            .kerning(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.13))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
    }

    private var statusLabel: String {
        if record.consecutiveFailures > 0 {
            return "FAILING"
        }
        return record.watchStatus.uppercased()
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            metaItem(icon: "clock", label: WatchFormatting.frequencyLabel(record.frequency))
            metaItem(icon: "calendar", label: nextRunLabel)
            if let lastRun = WatchFormatting.relativeTimeLabel(record.lastRun) {
                metaItem(icon: "checkmark.circle", label: "Last \(lastRun)")
            }
            if record.runCount > 0 {
                metaItem(icon: "number", label: "\(record.runCount) run\(record.runCount == 1 ? "" : "s")")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, design: activeFont.design))
        .foregroundStyle(EditorialPalette.textTertiary)
    }

    private var nextRunLabel: String {
        if record.watchStatus == "paused" {
            return "Paused"
        }
        if let next = WatchFormatting.nextRunLabel(record.nextRun) {
            return next
        }
        return "Scheduled"
    }

    private func metaItem(icon: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(EditorialPalette.warning)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 10.5, design: activeFont.design))
                .foregroundStyle(EditorialPalette.warning.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(EditorialPalette.warning.opacity(0.08))
        )
    }

    private var actionRow: some View {
        HStack(spacing: 5) {
            actionButton(
                icon: "doc.text",
                label: "Open Page",
                help: "Open synthesized page in Obsidian",
                action: onOpen
            )
            actionButton(
                icon: isRunning ? "hourglass" : "arrow.clockwise",
                label: isRunning ? "Running…" : "Run Now",
                help: isRunning ? "Run in progress" : "Run synthesis once now",
                action: onRun,
                isDisabled: isRunning,
                isAnimating: isRunning
            )
            actionButton(
                icon: record.watchStatus == "paused" ? "play.fill" : "pause.fill",
                label: record.watchStatus == "paused" ? "Resume" : "Pause",
                help: record.watchStatus == "paused" ? "Resume schedule" : "Pause schedule",
                action: onPause
            )
            Spacer(minLength: 0)
            actionButton(
                icon: "trash",
                label: "Remove",
                help: "Remove watch and its page",
                action: onRemove,
                isDestructive: true
            )
        }
    }

    @ViewBuilder
    private func actionButton(
        icon: String,
        label: String,
        help: String,
        action: @escaping () -> Void,
        isDisabled: Bool = false,
        isAnimating: Bool = false,
        isDestructive: Bool = false
    ) -> some View {
        WatchActionButton(
            icon: icon,
            label: label,
            help: help,
            action: action,
            isDisabled: isDisabled,
            isAnimating: isAnimating,
            isDestructive: isDestructive
        )
    }
}

private struct WatchActionButton: View {
    let icon: String
    let label: String
    let help: String
    let action: () -> Void
    let isDisabled: Bool
    let isAnimating: Bool
    let isDestructive: Bool

    @State private var isHovering = false
    @State private var spinDegrees: Double = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .rotationEffect(.degrees(isAnimating ? spinDegrees : 0))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium, design: activeFont.design))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1.0)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) { isHovering = hovering }
        }
        .onAppear {
            if isAnimating {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    spinDegrees = 360
                }
            }
        }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                spinDegrees = 0
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    spinDegrees = 360
                }
            }
        }
    }

    private var foreground: Color {
        if isDestructive {
            return isHovering ? EditorialPalette.warning : EditorialPalette.textTertiary
        }
        return isHovering ? EditorialPalette.textPrimary : EditorialPalette.textSecondary
    }

    private var background: Color {
        if isHovering {
            return isDestructive
                ? EditorialPalette.warning.opacity(0.12)
                : EditorialPalette.background.opacity(0.8)
        }
        return Color.clear
    }

    private var border: Color {
        if isHovering {
            return isDestructive
                ? EditorialPalette.warning.opacity(0.4)
                : EditorialPalette.border
        }
        return Color.clear
    }
}

// MARK: - Schedule builder

enum SchedulePreset: String, CaseIterable, Identifiable, Hashable {
    case hourly
    case every6h
    case every12h
    case daily
    case every2days
    case weekly
    case biweekly
    case mon, tue, wed, thu, fri, sat, sun
    case weekdays
    case weekends
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hourly: return "Hourly"
        case .every6h: return "Every 6 hours"
        case .every12h: return "Every 12 hours"
        case .daily: return "Daily"
        case .every2days: return "Every 2 days"
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .mon: return "Every Monday"
        case .tue: return "Every Tuesday"
        case .wed: return "Every Wednesday"
        case .thu: return "Every Thursday"
        case .fri: return "Every Friday"
        case .sat: return "Every Saturday"
        case .sun: return "Every Sunday"
        case .weekdays: return "Every weekday (Mon–Fri)"
        case .weekends: return "Weekends (Sat & Sun)"
        case .custom: return "Custom…"
        }
    }
}

struct ScheduleSpec {
    enum CustomUnit: String, CaseIterable, Identifiable {
        case hours, days, weeks
        var id: String { rawValue }

        func label(count: Int) -> String {
            switch self {
            case .hours: return count == 1 ? "hour" : "hours"
            case .days:  return count == 1 ? "day"  : "days"
            case .weeks: return count == 1 ? "week" : "weeks"
            }
        }
    }

    var preset: SchedulePreset = .daily
    var customCount: Int = 2
    var customUnit: CustomUnit = .hours

    /// Label for the dropdown trigger; shows the live custom value when in custom mode.
    var summary: String {
        guard preset == .custom else { return preset.label }
        let n = max(1, customCount)
        return "Every \(n) \(customUnit.label(count: n))"
    }

    /// Convert into the frequency string `compile watch` expects.
    func toFrequencyString() -> String {
        switch preset {
        case .hourly: return "hourly"
        case .every6h: return "every 6 hours"
        case .every12h: return "every 12 hours"
        case .daily: return "daily"
        case .every2days: return "every 2 days"
        case .weekly: return "weekly"
        case .biweekly: return "every 2 weeks"
        case .mon: return "cron: 0 9 * * 1"
        case .tue: return "cron: 0 9 * * 2"
        case .wed: return "cron: 0 9 * * 3"
        case .thu: return "cron: 0 9 * * 4"
        case .fri: return "cron: 0 9 * * 5"
        case .sat: return "cron: 0 9 * * 6"
        case .sun: return "cron: 0 9 * * 0"
        case .weekdays: return "cron: 0 9 * * 1-5"
        case .weekends: return "cron: 0 9 * * 0,6"
        case .custom:
            let n = max(1, customCount)
            switch customUnit {
            case .hours: return n == 1 ? "hourly" : "every \(n) hours"
            case .days:  return n == 1 ? "daily"  : "every \(n) days"
            case .weeks: return n == 1 ? "weekly" : "every \(n) weeks"
            }
        }
    }
}

private struct ScheduleBuilder: View {
    @Binding var spec: ScheduleSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            scheduleMenu
            if spec.preset == .custom {
                customRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Dropdown

    private var scheduleMenu: some View {
        Menu {
            Section {
                presetItem(.hourly)
                presetItem(.every6h)
                presetItem(.every12h)
                presetItem(.daily)
                presetItem(.every2days)
                presetItem(.weekly)
                presetItem(.biweekly)
            }
            Section("Specific day") {
                presetItem(.mon)
                presetItem(.tue)
                presetItem(.wed)
                presetItem(.thu)
                presetItem(.fri)
                presetItem(.sat)
                presetItem(.sun)
            }
            Section("Patterns") {
                presetItem(.weekdays)
                presetItem(.weekends)
            }
            Divider()
            Button("Custom…") {
                withAnimation(.easeOut(duration: 0.16)) { spec.preset = .custom }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scheduleIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(EditorialPalette.accent)
                Text(spec.summary)
                    .font(.system(size: 12, weight: .semibold, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(EditorialPalette.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(EditorialPalette.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var scheduleIcon: String {
        switch spec.preset {
        case .hourly, .every6h, .every12h:
            return "clock"
        case .daily, .every2days, .weekly, .biweekly:
            return "calendar"
        case .mon, .tue, .wed, .thu, .fri, .sat, .sun, .weekdays, .weekends:
            return "calendar.badge.clock"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    @ViewBuilder
    private func presetItem(_ preset: SchedulePreset) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { spec.preset = preset }
        } label: {
            if spec.preset == preset {
                Label(preset.label, systemImage: "checkmark")
            } else {
                Text(preset.label)
            }
        }
    }

    // MARK: Custom inline row

    private var customRow: some View {
        HStack(spacing: 6) {
            Text("Every")
                .font(.system(size: 11.5, design: activeFont.design))
                .foregroundStyle(EditorialPalette.textSecondary)

            countField

            unitMenu

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    private var countField: some View {
        TextField("", value: countBinding, format: .number)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(EditorialPalette.textPrimary)
            .frame(width: 44)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(EditorialPalette.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { spec.customCount },
            set: { spec.customCount = max(1, min(99, $0)) }
        )
    }

    private var unitMenu: some View {
        Menu {
            ForEach(ScheduleSpec.CustomUnit.allCases) { unit in
                Button(unit.rawValue.capitalized) { spec.customUnit = unit }
            }
        } label: {
            HStack(spacing: 5) {
                Text(spec.customUnit.label(count: spec.customCount))
                    .font(.system(size: 12, weight: .medium, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(EditorialPalette.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(EditorialPalette.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Editor card

private struct WatchEditorCard: View {
    let onCancel: () -> Void
    let onSubmit: (String, String, String, String?) -> Void

    @State private var url: String = ""
    @State private var schedule: ScheduleSpec = ScheduleSpec()
    @State private var intent: String = ""
    @State private var title: String = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case url, intent, title }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(EditorialPalette.accent)
                Text("New Watch")
                    .font(.system(size: 13, weight: .semibold, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                Spacer()
            }

            field(label: "URL", required: true) {
                editorTextField(
                    placeholder: "https://example.com/page",
                    text: $url,
                    focused: .url,
                    monospaced: true
                )
            }

            field(label: "Schedule", required: true) {
                ScheduleBuilder(spec: $schedule)
            }

            field(label: "Title", hint: "optional · derived from URL when empty") {
                editorTextField(
                    placeholder: "Friendly name for the wiki page",
                    text: $title,
                    focused: .title,
                    monospaced: false
                )
            }

            field(label: "Instructions", required: true, hint: "what would you like Claude to do?") {
                multilineEditor(
                    placeholder: "e.g. summarize today's headlines and call out anything that changed since the last pull.",
                    text: $intent
                )
            }

            HStack(spacing: 8) {
                Spacer()
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 11.5, weight: .medium, design: activeFont.design))
                }
                .buttonStyle(WatchSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button { submit() } label: {
                    Text("Create Watch")
                        .font(.system(size: 11.5, weight: .semibold, design: activeFont.design))
                }
                .buttonStyle(WatchPrimaryButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.5)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(EditorialPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(EditorialPalette.border, lineWidth: 1)
        )
        .onAppear { focusedField = .url }
    }

    private var canSubmit: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(
            url.trimmingCharacters(in: .whitespacesAndNewlines),
            schedule.toFrequencyString(),
            intent.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmedTitle.isEmpty ? nil : trimmedTitle
        )
    }

    @ViewBuilder
    private func field<Content: View>(
        label: String,
        required: Bool = false,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: activeFont.design))
                    .kerning(0.6)
                    .foregroundStyle(EditorialPalette.textTertiary)
                if required {
                    Text("•")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(EditorialPalette.accent)
                }
                if let hint {
                    Text(hint)
                        .font(.system(size: 9.5, design: activeFont.design).italic())
                        .foregroundStyle(EditorialPalette.textTertiary)
                }
            }
            content()
        }
    }

    @ViewBuilder
    private func editorTextField(
        placeholder: String,
        text: Binding<String>,
        focused: Field,
        monospaced: Bool
    ) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(monospaced
                          ? .system(size: 12, design: .monospaced)
                          : .system(size: 12, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
            }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: focused)
                .font(monospaced
                      ? .system(size: 12, design: .monospaced)
                      : .system(size: 12, design: activeFont.design))
                .foregroundStyle(EditorialPalette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(EditorialPalette.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    focusedField == focused
                        ? EditorialPalette.accent.opacity(0.45)
                        : EditorialPalette.border,
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private func multilineEditor(placeholder: String, text: Binding<String>) -> some View {
        let nsFont = NSFont.systemFont(ofSize: 12)
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: activeFont.design).italic())
                    .foregroundStyle(EditorialPalette.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
            }
            InsetlessTextEditor(
                text: text,
                font: nsFont,
                textColor: NSColor(EditorialPalette.textPrimary),
                autoFocus: false
            )
            .focused($focusedField, equals: .intent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 70, maxHeight: 110)
        }
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(EditorialPalette.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    focusedField == .intent
                        ? EditorialPalette.accent.opacity(0.45)
                        : EditorialPalette.border,
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Button styles

private struct WatchPrimaryButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? EditorialPalette.background : EditorialPalette.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        prominent
                            ? (configuration.isPressed
                                ? EditorialPalette.accentHover
                                : EditorialPalette.accent)
                            : (configuration.isPressed
                                ? EditorialPalette.surfaceHover
                                : EditorialPalette.surface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        prominent ? Color.clear : EditorialPalette.border,
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct WatchSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(EditorialPalette.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(configuration.isPressed ? EditorialPalette.surfaceHover : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(EditorialPalette.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

// MARK: - Date helpers

enum WatchFormatting {
    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func frequencyLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        switch lower {
        case "hourly": return "Hourly"
        case "daily": return "Daily"
        case "weekly": return "Weekly"
        default: break
        }
        if lower.hasPrefix("every ") {
            let body = trimmed.dropFirst("every ".count)
            return "Every \(body)"
        }
        if lower.hasPrefix("cron:") {
            return cronSummary(trimmed) ?? "Custom"
        }
        return trimmed.capitalized
    }

    private static func cronSummary(_ raw: String) -> String? {
        let body = raw.dropFirst("cron:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = body.split(separator: " ").map(String.init)
        guard parts.count >= 5 else { return nil }
        guard let minute = Int(parts[0]), let hour = Int(parts[1]) else { return nil }
        let timeStr = String(format: "%02d:%02d", hour, minute)
        let dowRaw = parts[4]
        let dowLabel = cronDowLabel(dowRaw)
        if let dowLabel {
            return "\(dowLabel) at \(timeStr)"
        }
        return "Daily at \(timeStr)"
    }

    private static func cronDowLabel(_ field: String) -> String? {
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        if field == "*" { return nil }
        if field == "1-5" { return "Weekdays" }
        if field == "0,6" || field == "6,0" { return "Weekends" }
        if let idx = Int(field), (0...6).contains(idx) {
            return dayNames[idx]
        }
        if field.contains(",") {
            let pieces = field.split(separator: ",").compactMap { Int($0) }
            let labels = pieces.compactMap { (0...6).contains($0) ? dayNames[$0] : nil }
            if !labels.isEmpty { return labels.joined(separator: ", ") }
        }
        if field.contains("-") {
            let bounds = field.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2,
               (0...6).contains(bounds[0]),
               (0...6).contains(bounds[1]) {
                return "\(dayNames[bounds[0]])–\(dayNames[bounds[1]])"
            }
        }
        return nil
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return makeISOFormatter().date(from: raw)
    }

    static func nextRunLabel(_ raw: String?) -> String? {
        guard let date = parseDate(raw) else { return nil }
        let now = Date()
        let interval = date.timeIntervalSince(now)
        if interval <= 0 {
            return "Due now"
        }
        return "Next " + relativeFutureLabel(interval: interval, date: date)
    }

    static func relativeTimeLabel(_ raw: String?) -> String? {
        guard let date = parseDate(raw) else { return nil }
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval < 0 { return nil }
        return relativePastLabel(interval: interval, date: date)
    }

    private static func relativeFutureLabel(interval: TimeInterval, date: Date) -> String {
        if interval < 60 {
            return "in <1m"
        }
        if interval < 60 * 60 {
            let m = Int(interval / 60)
            return "in \(m)m"
        }
        if interval < 60 * 60 * 24 {
            let h = Int(interval / 3600)
            let remainder = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            return remainder >= 5 ? "in \(h)h \(remainder)m" : "in \(h)h"
        }
        if interval < 60 * 60 * 24 * 7 {
            let d = Int(interval / 86_400)
            return "in \(d)d"
        }
        return "on " + Self.shortDate(date)
    }

    private static func relativePastLabel(interval: TimeInterval, date: Date) -> String {
        if interval < 60 {
            return "just now"
        }
        if interval < 60 * 60 {
            let m = Int(interval / 60)
            return "\(m)m ago"
        }
        if interval < 60 * 60 * 24 {
            let h = Int(interval / 3600)
            return "\(h)h ago"
        }
        if interval < 60 * 60 * 24 * 7 {
            let d = Int(interval / 86_400)
            return "\(d)d ago"
        }
        return shortDate(date)
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
