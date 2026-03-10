import SwiftUI

@main
struct MacDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var container: DependencyContainer

    init() {
        let container = DependencyContainer()
        DependencyContainer.shared = container
        _container = State(initialValue: container)
    }

    var body: some Scene {
        Window("Mac Download Manager", id: "main") {
            DownloadListView()
                .environment(container)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: 700, height: 500)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView()
                .environment(container)
        } label: {
            Label("Downloads", systemImage: container.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(container)
        }
    }
}
