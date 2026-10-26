import AppKit

@MainActor
final class PopoverDismissal {
    struct Hooks: Sendable {
        let popoverWindow: @MainActor @Sendable () -> NSWindow?
        let isPointerOnIcon: @MainActor @Sendable () -> Bool
        let isPopoverShown: @MainActor @Sendable () -> Bool
        let isMoreShown: @MainActor @Sendable () -> Bool
        let hideMore: @MainActor @Sendable () -> Void
        let close: @MainActor @Sendable () -> Void
    }

    private let hooks: Hooks
    private var eventMonitors: [Any] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    func start() {
        guard eventMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let hooks = hooks
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            MainActor.assumeIsolated {
                guard !hooks.isPointerOnIcon() else { return }
                hooks.close()
            }
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { event in
            let clicked = event.window
            MainActor.assumeIsolated {
                let popoverWindow = hooks.popoverWindow()
                if clicked !== popoverWindow, clicked?.parent !== popoverWindow, !hooks.isPointerOnIcon() { hooks.close() }
            }
            return event
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            let window = event.window
            guard event.keyCode == 53 else { return event }
            let closed = MainActor.assumeIsolated {
                guard hooks.isPopoverShown(), window === hooks.popoverWindow() else { return false }
                if hooks.isMoreShown() { hooks.hideMore() } else { hooks.close() }
                return true
            }
            return closed ? nil : event
        }) { eventMonitors.append(monitor) }
        for (center, name) in [
            (NotificationCenter.default, NSApplication.didResignActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hooks.close() }
            }
            observers.append((center, token))
        }
    }

    func stop() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
    }
}
