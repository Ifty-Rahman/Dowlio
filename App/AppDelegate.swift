import AppKit
import DowlioLibrary

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    /// Launched by macOS at login, so the library window stays hidden.
    @MainActor static private(set) var launchedAtLogin = false
    /// Whether the first library window of this launch has been shown or hidden. Only that one
    /// can be hidden, so a window opened later always shows.
    @MainActor static var launchWindowDecided = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Self.model?.applyPresence(activating: UserDefaults.standard.presence.opensWindowAtLaunch(launchedAtLogin: Self.launchedAtLogin))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.model?.showLibraryWindow() }
        return true
    }

    /// Asks before quitting stops running or queued downloads, from the menu, ⌘Q and the popover
    /// alike, then pauses them so each keeps its bytes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, let question = QuitGuard(rows: model.rows) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            // Partial files are saved every second anyway, so a stuck pause never keeps Dowlio open.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.stopForQuit() }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
