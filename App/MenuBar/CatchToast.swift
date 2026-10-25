import AppKit
import DowlioConnect
import DowlioLibrary
import Observation
import SwiftUI

@MainActor
final class CatchToast {
    static let shownFor: Duration = .seconds(4)
    static let afterPointerLeaves: Duration = .milliseconds(1500)

    private let model: AppModel
    private let shown = ShownNotice()
    private let panel: ToastPanel
    private var hiding: Task<Void, Never>?
    private var isShowing = false

    init(model: AppModel) {
        self.model = model
        panel = ToastPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView: CatchToastView(model: model, shown: shown) { [weak self] hovering in
            self?.keepOpen(hovering)
        } close: { [weak self] in
            self?.hide()
        })
    }

    func show(_ notice: CatchNotice, under button: NSStatusBarButton) {
        shown.notice = notice
        guard let content = panel.contentView, let buttonWindow = button.window else { return }
        let size = content.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        isShowing = true
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            fade(to: 1)
        }
        scheduleHide(after: Self.shownFor)
    }

    func hide() {
        hiding?.cancel()
        hiding = nil
        isShowing = false
        guard panel.isVisible else { return }
        fade(to: 0) { [weak self] in
            guard let self, !isShowing else { return }
            panel.orderOut(nil)
        }
    }

    private func fade(to alpha: CGFloat, then finish: (@MainActor () -> Void)? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = alpha
            finish?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { finish?() }
        }
    }

    private func keepOpen(_ hovering: Bool) {
        if hovering {
            hiding?.cancel()
            hiding = nil
        } else {
            scheduleHide(after: Self.afterPointerLeaves)
        }
    }

    private func scheduleHide(after delay: Duration) {
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
@Observable
final class ShownNotice {
    var notice: CatchNotice?
}

private struct CatchToastView: View {
    let model: AppModel
    let shown: ShownNotice
    let hovering: (Bool) -> Void
    let close: () -> Void

    var body: some View {
        Group {
            if let notice = shown.notice {
                content(notice)
            }
        }
        .padding(DowlioDesign.Spacing.lg)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.container))
        .onHover(perform: hovering)
    }

    private func content(_ notice: CatchNotice) -> some View {
        let row = notice.single.flatMap { model.row($0.id) }
        return VStack(alignment: .leading, spacing: DowlioDesign.Spacing.md) {
            HStack(spacing: DowlioDesign.Spacing.md) {
                if let single = notice.single {
                    FileTypeBadge(text: row?.badge ?? URL(filePath: single.fileName).pathExtension.uppercased())
                } else {
                    SeveralFilesBadge()
                }
                VStack(alignment: .leading, spacing: DowlioDesign.Spacing.xs) {
                    Text(notice.title).font(DowlioDesign.TypeRole.title)
                    Text(notice.detail)
                        .font(DowlioDesign.TypeRole.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            if let row {
                SegmentedBar(segments: row.displaySegments, fraction: row.fractionDone, tint: row.state.tone, height: 3)
            }
            HStack {
                Spacer()
                if notice.offersDownloadInBrowser {
                    Button("Download in Browser Instead") {
                        close()
                        model.downloadInBrowser(notice)
                    }
                }
                Button(notice.showTitle) {
                    close()
                    model.show(notice)
                }
            }
        }
    }
}

private struct SeveralFilesBadge: View {
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 44

    var body: some View {
        Image(systemName: "square.stack")
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: DowlioDesign.Radius.nested))
            .accessibilityHidden(true)
    }
}
