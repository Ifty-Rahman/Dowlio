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
        AppDelegate.model = model
        _model = State(initialValue: model)
        _menuBar = State(initialValue: MenuBarController(model: model))
    }

    var body: some Scene {
        Window("Dowlio", id: LibraryWindow.sceneID) {
            LibraryWindow(model: model)
        }
        .defaultSize(LibraryWindow.firstSize)
        .windowResizability(.contentSize)
        .commands {
            NewDownloadCommands(model: model)
            UpdateCommands(updater: model.updater)
            DownloadCommands(model: model)
            FindCommands()
            PanelCommands()
        }

        WindowGroup("Download", id: DetailWindow.sceneID, for: DownloadID.self) { $id in
            if let id { DetailWindow(id: id, model: model) }
        }
        .defaultSize(width: 620, height: 520)

        Settings {
            SettingsView(model: model)
        }
    }
}

struct UpdateCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkNow() }
                .disabled(!updater.canCheck)
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
