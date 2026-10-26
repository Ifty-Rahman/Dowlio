import AppKit
import DowlioLibrary
import DowlioMedia
import SwiftUI

@MainActor
final class SentPagePanel {
    private let model: AppModel
    private let host: SentPageHost
    private lazy var panel = makePanel()
    private var centresOnNextSize = false

    init(model: AppModel) {
        self.model = model
        host = SentPageHost(analyze: model.analyze)
    }

    func show(_ page: SentPage, handBack: @escaping (URL) -> Void) {
        host.send(page) { [weak self] file in
            self?.hide()
            handBack(file)
        }
        centresOnNextSize = true
        center(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func hide() {
        host.backToLinks()
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = SentPagePanelContent(
            model: model, host: host,
            close: { [weak self] in self?.hide() },
            resize: { [weak self] size in self?.resize(to: size) }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    private func resize(to size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel, size.height > 0, panel.contentLayoutRect.size != size else { return }
            var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
            panel.setFrame(frame, display: true)
            if self?.centresOnNextSize == true {
                self?.centresOnNextSize = false
                self?.center(panel)
            }
        }
    }

    private func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct SentPagePanelContent: View {
    let model: AppModel
    let host: SentPageHost
    let close: () -> Void
    let resize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sentPage = host.current {
                SentPageView(model: model, sentPage: sentPage, close: close)
                    .padding(DowlioDesign.Spacing.lg)
                    .frame(width: 360, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self, of: \.size) { resize($0) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand(perform: close)
    }
}
