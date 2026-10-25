import AppKit
import SwiftUI

private struct Glass: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Takes on the look of its window's own background, such as a popover's.
private final class MatchingGlassView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let frame = window?.contentView?.superview, let background = Self.firstEffect(in: frame, skipping: self) else { return }
        material = background.material
        blendingMode = background.blendingMode
        state = background.state
        isEmphasized = background.isEmphasized
        appearance = background.appearance
    }

    private static func firstEffect(in view: NSView, skipping own: NSView) -> NSVisualEffectView? {
        if let effect = view as? NSVisualEffectView, effect !== own, !(effect is MatchingGlassView) { return effect }
        for child in view.subviews where child !== own {
            if let found = firstEffect(in: child, skipping: own) { return found }
        }
        return nil
    }
}

private struct MatchingGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> MatchingGlassView {
        let view = MatchingGlassView()
        view.material = .popover
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: MatchingGlassView, context: Context) {}
}

extension View {
    func windowGlass() -> some View {
        background(Glass(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
    }

    /// The same background as the window it's in, for a surface drawn on top of a popover.
    func popoverGlass() -> some View {
        background(MatchingGlass())
    }
}
