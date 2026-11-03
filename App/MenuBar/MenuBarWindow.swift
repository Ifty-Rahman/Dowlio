import AppKit
import SwiftUI

@MainActor
final class MenuBarWindow {
    private let panel: MenuBarPanelWindow
    private var anchor: NSRect = .zero

    var window: NSWindow { panel }
    var isShown: Bool { panel.isVisible }

    init<Content: View>(content: Content) {
        panel = MenuBarPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = MenuBarHostingView(rootView: AnyView(
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .fixedSize()
        ))
        host.sizingOptions = [.intrinsicContentSize]
        host.sized = { [weak self] in self?.place() }
        panel.contentView = host
    }

    private static let cornerRadius: CGFloat = 14
    private static let gap: CGFloat = 6

    func show(under button: NSStatusBarButton, makingKey: Bool) {
        guard let buttonWindow = button.window else { return }
        anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.appearance = NSApp.effectiveAppearance
        place()
        panel.orderFrontRegardless()
        if makingKey { panel.makeKey() }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func place() {
        guard let content = panel.contentView else { return }
        panel.setFrame(MenuBarPlacement.frame(size: content.fittingSize, under: anchor, gap: Self.gap), display: true)
        panel.invalidateShadow()
    }
}

private final class MenuBarPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class MenuBarHostingView: NSHostingView<AnyView> {
    var sized: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.sized?() }
    }
}
