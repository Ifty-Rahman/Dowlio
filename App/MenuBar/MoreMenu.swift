import AppKit
import SwiftUI

@MainActor
final class MoreMenu {
    private let panel: MenuPanel
    private var clicks: Any?
    var isShown: Bool { panel.isVisible }

    init(settings: @escaping () -> Void, reportProblem: @escaping () -> Void, quit: @escaping () -> Void) {
        panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let content = FirstClickHostingView(rootView: MoreMenuView(
            settings: settings, reportProblem: reportProblem, quit: quit
        ))
        content.sizingOptions = [.intrinsicContentSize]
        panel.contentView = content
    }

    func show(under anchor: NSView) {
        guard let window = anchor.window, let content = panel.contentView else { return }
        panel.appearance = window.effectiveAppearance
        let size = content.fittingSize
        let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(button.minX, screen.maxX - size.width - DowlioDesign.Spacing.sm)
        let y = button.minY - DowlioDesign.Spacing.xs - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.invalidateShadow()
        watchClicks()
    }

    func hide() {
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func watchClicks() {
        guard clicks == nil else { return }
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let clicked = event.window
            let closed = MainActor.assumeIsolated {
                guard let self, clicked !== self.panel else { return false }
                self.hide()
                return true
            }
            return closed ? nil : event
        }
    }
}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct MoreMenuAnchor: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private struct MoreMenuView: View {
    let settings: () -> Void
    let reportProblem: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MoreMenuItem(title: "Settings…", shortcut: "⌘,", action: settings)
            MoreMenuItem(title: "Report a Problem", shortcut: nil, action: reportProblem)
            Divider()
                .padding(.horizontal, DowlioDesign.Spacing.sm)
                .padding(.vertical, DowlioDesign.Spacing.xs)
            MoreMenuItem(title: "Quit Dowlio", shortcut: "⌘Q", action: quit)
        }
        .padding(DowlioDesign.Spacing.xs + 1)
        .frame(width: 200)
        .panelGlass(cornerRadius: DowlioDesign.Radius.container)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("More")
    }
}

private struct MoreMenuItem: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(isHovered ? .white.opacity(0.8) : .secondary)
                }
            }
            .padding(.horizontal, DowlioDesign.Spacing.sm)
            .padding(.vertical, DowlioDesign.Spacing.xs)
            .foregroundStyle(isHovered ? .white : .primary)
            .background(isHovered ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
