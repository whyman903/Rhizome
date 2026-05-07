import SwiftUI
import RhizomeCore

@MainActor
@Observable
final class WatchesViewModel {
    var watches: [WatchRecord] = []
    var isLoading = false
    var lastError: String?

    private let sidecar: WatchSidecarRunning
    private let workspaceProvider: @MainActor () -> URL?

    init(
        sidecar: WatchSidecarRunning,
        workspaceProvider: @escaping @MainActor () -> URL?
    ) {
        self.sidecar = sidecar
        self.workspaceProvider = workspaceProvider
    }

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

    func add(url urlString: String, frequency: String, intent: String, title: String?) async {
        guard let workspace = workspaceProvider() else { return }
        do {
            _ = try await sidecar.add(
                url: urlString,
                frequency: frequency,
                intent: intent,
                title: title,
                at: workspace
            )
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func runOnce(_ record: WatchRecord) async {
        guard let workspace = workspaceProvider() else { return }
        do {
            _ = try await sidecar.runOnce(record.id, force: false, at: workspace)
            await reload()
        } catch {
            lastError = error.localizedDescription
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

struct WatchesView: View {
    @Bindable var viewModel: WatchesViewModel
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            Divider().overlay(EditorialPalette.border)

            if viewModel.watches.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.watches) { watch in
                            WatchRow(record: watch, viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }

            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(EditorialPalette.warning)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(EditorialPalette.background)
        .task { await viewModel.reload() }
        .sheet(isPresented: $showingAdd) {
            WatchEditorView { url, frequency, intent, title in
                Task {
                    await viewModel.add(url: url, frequency: frequency, intent: intent, title: title)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Watches")
                    .font(.system(size: 20, weight: .medium, design: activeFont.design))
                    .foregroundStyle(EditorialPalette.textPrimary)
                Text("Recurring URL pulls synthesized into wiki pages.")
                    .font(.system(size: 12))
                    .foregroundStyle(EditorialPalette.textTertiary)
            }
            Spacer()
            Button {
                showingAdd = true
            } label: {
                Label("New Watch", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "binoculars")
                .font(.system(size: 28))
                .foregroundStyle(EditorialPalette.textTertiary)
            Text("No watches yet.")
                .foregroundStyle(EditorialPalette.textSecondary)
            Button("New Watch") { showingAdd = true }
        }
    }
}

private struct WatchRow: View {
    let record: WatchRecord
    @Bindable var viewModel: WatchesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(EditorialPalette.textPrimary)
                Spacer()
                statusBadge
            }
            Text(record.url)
                .font(.system(size: 11))
                .foregroundStyle(EditorialPalette.textTertiary)
                .lineLimit(1)
            Text(record.intent)
                .font(.system(size: 12))
                .foregroundStyle(EditorialPalette.textSecondary)
                .lineLimit(2)
            HStack(spacing: 12) {
                Text("Frequency: \(record.frequency)")
                Text("Next: \(record.nextRun ?? "—")")
                if record.runCount > 0 {
                    Text("Runs: \(record.runCount)")
                }
                Spacer()
                Button("Run now") {
                    Task { await viewModel.runOnce(record) }
                }
                .buttonStyle(.borderless)
                Button(record.watchStatus == "paused" ? "Resume" : "Pause") {
                    Task { await viewModel.togglePauseResume(record) }
                }
                .buttonStyle(.borderless)
                Button("Remove") {
                    Task { await viewModel.remove(record) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(EditorialPalette.warning)
            }
            .font(.system(size: 11))
            .foregroundStyle(EditorialPalette.textTertiary)
        }
        .padding(12)
        .background(EditorialPalette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(EditorialPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusBadge: some View {
        Text(record.watchStatus.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch record.watchStatus {
        case "active": return EditorialPalette.accent
        case "paused": return EditorialPalette.textTertiary
        default: return EditorialPalette.warning
        }
    }
}

struct WatchEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url: String = ""
    @State private var frequency: String = "daily"
    @State private var intent: String = ""
    @State private var title: String = ""

    let onSubmit: (String, String, String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Watch")
                .font(.system(size: 18, weight: .medium, design: activeFont.design))
                .foregroundStyle(EditorialPalette.textPrimary)

            field(label: "URL") {
                TextField("https://…", text: $url)
                    .textFieldStyle(.roundedBorder)
            }
            field(label: "Frequency") {
                Picker("", selection: $frequency) {
                    Text("Hourly").tag("hourly")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            field(label: "Title (optional)") {
                TextField("Derived from URL when empty", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            field(label: "Intent") {
                TextEditor(text: $intent)
                    .font(.system(size: 12))
                    .frame(minHeight: 96)
                    .padding(6)
                    .background(EditorialPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(EditorialPalette.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onSubmit(
                        url.trimmingCharacters(in: .whitespacesAndNewlines),
                        frequency,
                        intent.trimmingCharacters(in: .whitespacesAndNewlines),
                        title.isEmpty ? nil : title
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty || intent.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 320)
        .background(EditorialPalette.background)
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EditorialPalette.textSecondary)
            content()
        }
    }
}
