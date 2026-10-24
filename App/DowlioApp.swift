import SwiftUI

@main
struct DowlioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Dowlio", id: "library") {
            LibraryWindow(model: model)
        }
    }
}
