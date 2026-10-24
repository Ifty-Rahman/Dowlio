import AppKit
import SwiftUI

/// The sidebar's frosted material, behind a whole window, so the desktop shows softly through
/// every part of it. It dims like a sidebar does when the window isn't active.
private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    func windowGlass() -> some View {
        background(WindowGlass().ignoresSafeArea())
    }
}
