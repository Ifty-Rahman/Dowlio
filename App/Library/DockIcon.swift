import AppKit
import DowlioLibrary

/// Shows the Dock icon as Settings › General says, and while any Dowlio window is open even with
/// Show in Dock off, so the icon leaves with the last window.
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
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
    }

    func refresh() {
        let showing = UserDefaults.standard.presence.showsDockIcon(windowOpen: Self.windowOpen)
        let policy: NSApplication.ActivationPolicy = showing ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// The menu bar popover, toasts, alerts and the hidden player don't count.
    private static var windowOpen: Bool {
        NSApp.windows.contains { window in
            !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
        }
    }
}
