import SwiftUI
import RhizomeCore

@main
struct RhizomeApp: App {
    @State private var model: AppModel
    @State private var watchesViewModel: WatchesViewModel
    private let logger: AppLogger

    init() {
        let logger = AppLogger()
        self.logger = logger
        let scheduler = WatchScheduler(logger: logger)
        let model = AppModel(
            logger: logger,
            installWatchTrigger: { workspaceURL in
                try scheduler.install(workspaceURL: workspaceURL)
            }
        )
        self._model = State(initialValue: model)
        let sidecar = WatchSidecar(logger: logger)
        let modelStorage = self._model
        let viewModel = WatchesViewModel(
            sidecar: sidecar,
            workspaceProvider: { modelStorage.wrappedValue.workspace?.url },
            openPageHandler: { relativePath in
                modelStorage.wrappedValue.openWikiPage(target: relativePath)
            }
        )
        self._watchesViewModel = State(initialValue: viewModel)
    }

    var body: some Scene {
        Window("Rhizome", id: "query-window") {
            QueryDetailView(model: model, watchesViewModel: watchesViewModel)
                .task { await model.bootstrapIfNeeded() }
        }
        .defaultSize(width: 620, height: 600)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Conversation Tab") {
                    model.requestNewQueryTab()
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandMenu("Tabs") {
                TabSwitchCommands(model: model)
            }
        }

        MenuBarExtra {
            LauncherView(model: model)
                .task { await model.bootstrapIfNeeded() }
        } label: {
            Image(nsImage: MenuBarIcon.template)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct TabSwitchCommands: View {
    @Bindable var model: AppModel

    var body: some View {
        ForEach(Array(model.queryTabs.prefix(9).enumerated()), id: \.element.id) { index, session in
            Button(menuTitle(index: index, session: session)) {
                model.selectQueryTab(at: index)
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        }
    }

    private func menuTitle(index: Int, session: QuerySession) -> String {
        let raw = session.firstQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = raw.isEmpty ? "New Query" : String(raw.prefix(40))
        return "\(index + 1). \(title)"
    }
}
