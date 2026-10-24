import AppKit
import SwiftUI

/// Hands the library window to `AppModel`. When Dowlio starts in the menu bar or at login, it
/// hides the window before it first shows, so the start never flashes it.
struct LibraryWindowAccessor: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        Probe(model: model)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let model: AppModel

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
                guard !AppDelegate.launchWindowDecided else { return }
                AppDelegate.launchWindowDecided = true
                guard !UserDefaults.standard.presence.opensWindowAtLaunch(launchedAtLogin: AppDelegate.launchedAtLogin) else { return }
                window.alphaValue = 0
                DispatchQueue.main.async {
                    window.orderOut(nil)
                    window.alphaValue = 1
                }
            }
        }
    }
}
