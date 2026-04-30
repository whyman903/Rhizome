import SwiftUI
import RhizomeCore

@main
struct RhizomeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Rhizome", id: "query-window") {
            QueryDetailView(model: model)
                .task { await model.bootstrapIfNeeded() }
        }
        .defaultSize(width: 560, height: 580)
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
