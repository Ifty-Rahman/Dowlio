import AppKit
import SwiftUI

struct SettingsWindowBehavior: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        Probe(model: model)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? Probe)?.tearDown()
    }

    fileprivate final class Probe: NSView {
        private let model: AppModel
        private var observers: [NSObjectProtocol] = []
        private var keyMonitor: Any?

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        func tearDown() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDown()
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak window] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Self.closeIfLeft(window) } }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self, weak window] note in
                let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let closing, closing == self?.model.libraryWindow.map(ObjectIdentifier.init), closing != window.map(ObjectIdentifier.init) else { return }
                    window?.close()
                }
            })
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
                guard event.keyCode == 53, let window, event.window === window, window.attachedSheet == nil else { return event }
                window.close()
                return nil
            }
        }

        @MainActor
        private static func closeIfLeft(_ window: NSWindow?) {
            guard let window, window.isVisible, !window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            if let key = NSApp.keyWindow, key.sheetParent === window || key is NSOpenPanel || key is NSSavePanel || key.parent === window { return }
            window.close()
        }
    }
}
