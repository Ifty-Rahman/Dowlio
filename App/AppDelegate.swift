import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Downloads keep running with every window closed (architecture.md, process model).
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        IncomingLinks.shared.receive(urls)
    }
}
