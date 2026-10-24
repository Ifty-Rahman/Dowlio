import DowlioCore
import SwiftUI

@main
struct DowlioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Dowlio", id: LibraryWindow.sceneID) {
            LibraryWindow(model: model)
        }
        .commands {
            NewDownloadCommands(model: model)
            DownloadCommands()
            InspectorCommands()
        }

        WindowGroup("Download", id: DetailWindow.sceneID, for: DownloadID.self) { $id in
            if let id { DetailWindow(id: id, model: model) }
        }
        .defaultSize(width: 620, height: 520)
    }
}

struct NewDownloadCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Download…") {
                openWindow(id: LibraryWindow.sceneID)
                model.requestNewDownload()
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
