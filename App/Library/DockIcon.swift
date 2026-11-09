import AppKit
import DowlioLibrary

@MainActor
final class DockIcon {
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let shown: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in shown {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
    }

    func refresh() {
        guard !NSApp.isHidden else { return }
        let showing = UserDefaults.standard.presence.showsDockIcon(windowOpen: NSApp.windows.contains(where: Self.isOpenDowlioWindow))
        let policy: NSApplication.ActivationPolicy = showing ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular, NSApp.isActive { DispatchQueue.main.async { NSApp.activate() } }
    }

    private static func isOpenDowlioWindow(_ window: NSWindow) -> Bool {
        let isPanel = window is NSPanel
        let hasTitleBar = window.styleMask.contains(.titled)
        return !isPanel && hasTitleBar && (window.isVisible || window.isMiniaturized)
    }
}
