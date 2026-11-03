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

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        func tearDown() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDown()
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self, weak window] note in
                let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let closing, closing == self?.model.libraryWindow.map(ObjectIdentifier.init), closing != window.map(ObjectIdentifier.init) else { return }
                    window?.close()
                }
            })
        }
    }
}
