import DowlioCore
import DowlioLibrary
import SwiftUI

@main
struct DowlioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var menuBar: MenuBarController

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _menuBar = State(initialValue: MenuBarController(model: model))
    }

    var body: some Scene {
        Window("Dowlio", id: LibraryWindow.sceneID) {
            LibraryWindow(model: model)
        }
        .defaultSize(width: 700, height: 520)
        .windowResizability(.contentMinSize)
        .commands {
            NewDownloadCommands(model: model)
            DownloadCommands(model: model)
            FindCommands()
            PanelCommands()
        }

        WindowGroup("Download", id: DetailWindow.sceneID, for: DownloadID.self) { $id in
            if let id { DetailWindow(id: id, model: model) }
        }
        .defaultSize(width: 620, height: 520)

        Settings {
            ContentUnavailableView("Settings aren't ready yet", systemImage: "gearshape")
                .frame(width: 420, height: 240)
        }
    }
}

struct NewDownloadCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Download…") {
                if NewLinkRoute(entry: .newDownloadCommand, windowIsOpen: model.isLibraryWindowOpen) == .openWindowThenSheet {
                    openWindow(id: LibraryWindow.sceneID)
                }
                model.requestNewDownload()
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
