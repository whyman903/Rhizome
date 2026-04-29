import SwiftUI
import MyWikiCore

@main
struct MyWikiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MyWiki", id: "query-window") {
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
