import AppKit
import SwiftUI

/// Hands the library window to `AppModel`. After a start at login it hides the window before it
/// first shows, so a quiet start never flashes it.
struct LibraryWindowAccessor: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        Probe(model: model)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let model: AppModel
        private var hidOnce = false

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                model.libraryWindow = window
                guard AppDelegate.launchedAtLogin, !hidOnce else { return }
                hidOnce = true
                window.alphaValue = 0
                DispatchQueue.main.async {
                    window.orderOut(nil)
                    window.alphaValue = 1
                }
            }
        }
    }
}
