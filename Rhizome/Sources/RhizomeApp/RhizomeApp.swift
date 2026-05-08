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

        MenuBarExtra {
            LauncherView(model: model)
                .task { await model.bootstrapIfNeeded() }
        } label: {
            Image(nsImage: MenuBarIcon.template)
        }
        .menuBarExtraStyle(.window)
    }
}
