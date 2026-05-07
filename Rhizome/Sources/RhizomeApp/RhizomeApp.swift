import SwiftUI
import RhizomeCore

@main
struct RhizomeApp: App {
    @State private var model = AppModel()
    @State private var watchesViewModel: WatchesViewModel
    private let logger: AppLogger

    init() {
        let logger = AppLogger()
        self.logger = logger
        let sidecar = WatchSidecar(logger: logger)
        let modelStorage = self._model
        let viewModel = WatchesViewModel(
            sidecar: sidecar,
            workspaceProvider: { modelStorage.wrappedValue.workspace?.url }
        )
        self._watchesViewModel = State(initialValue: viewModel)
    }

    var body: some Scene {
        Window("Rhizome", id: "query-window") {
            QueryDetailView(model: model)
                .task { await model.bootstrapIfNeeded() }
        }
        .defaultSize(width: 560, height: 580)
        .windowStyle(.hiddenTitleBar)

        Window("Watches", id: "watches-window") {
            WatchesView(viewModel: watchesViewModel)
                .task { await watchesViewModel.reload() }
        }
        .defaultSize(width: 560, height: 480)

        MenuBarExtra {
            LauncherView(model: model)
                .task { await model.bootstrapIfNeeded() }
        } label: {
            Image(nsImage: MenuBarIcon.template)
        }
        .menuBarExtraStyle(.window)
    }
}
