import DowlioCore
import SwiftUI

@main
struct DowlioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Dowlio", id: "library") {
            LibraryWindow(model: model)
        }
        .commands {
            DownloadCommands()
            InspectorCommands()
        }

        WindowGroup("Download", id: DetailWindow.sceneID, for: DownloadID.self) { $id in
            if let id { DetailWindow(id: id, model: model) }
        }
        .defaultSize(width: 620, height: 520)
    }
}
