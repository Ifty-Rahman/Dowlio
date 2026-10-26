import AppKit
import DowlioConnect
import DowlioLibrary
import Observation
import SwiftUI

/// Dowlio's menu bar item: an icon whose bar shows progress while downloading, and a popover.
/// AppKit owns it, because SwiftUI's menu bar extra can't be opened from code, and later phases
/// open the catch toast and the Send panel from it.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let panel = MenuBarPanel()
    private var drawnFraction: Double??
    private lazy var dismissal = PopoverDismissal(hooks: .init(
        popoverWindow: { [weak self] in self?.popover.contentViewController?.view.window },
        isPointerOnIcon: { [weak self] in self?.isPointerOnIcon ?? false },
        isPopoverShown: { [weak self] in self?.popover.isShown ?? false },
        isMoreShown: { [weak self] in self?.moreMenu.isShown ?? false },
        hideMore: { [weak self] in self?.moreMenu.hide() },
        close: { [weak self] in self?.close() }
    ))
    private lazy var catchToast = CatchToast(model: model)
    private lazy var moreMenu = MoreMenu(
        settings: { [weak self] in self?.runFromMore { $0.showSettings() } },
        reportProblem: { [weak self] in self?.runFromMore { $0.reportProblem() } },
        quit: { NSApp.terminate(nil) }
    )

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarPopover(
            model: model, panel: panel,
            close: { [weak self] in self?.close() },
            toggleMore: { [weak self] in self?.toggleMore() }
        ))
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.menuBar = self
        item.isVisible = UserDefaults.standard.presence.menuBar
        follow()
        if DebugLaunch.opensPopover {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.toggle()
                if DebugLaunch.quickAddLink != nil { self?.panel.showsQuickAdd = true }
            }
        }
    }

    var isVisible: Bool {
        get { item.isVisible }
        set {
            if !newValue {
                close()
                catchToast.hide()
            }
            item.isVisible = newValue
        }
    }

    func showCatch(_ notice: CatchNotice) {
        guard let button = item.button else { return }
        catchToast.show(notice, under: button)
    }

    func showSent(_ link: SentLink) {
        if !popover.isShown { open() }
        moreMenu.hide()
        if !panel.showsQuickAdd || panel.quickAdd == nil {
            panel.quickAdd = model.makeNewDownload()
            panel.showsQuickAdd = true
        }
        panel.quickAdd?.draft.addSent(link.url, referrer: link.referrer, cookies: link.cookies, browser: link.browser, userAgent: link.userAgent)
    }

    @objc private func toggle() {
        if popover.isShown { close() } else { open() }
    }

    private func toggleMore() {
        if moreMenu.isShown {
            moreMenu.hide()
        } else if let anchor = panel.moreAnchor {
            moreMenu.show(under: anchor)
        }
    }

    private func runFromMore(_ action: (AppModel) -> Void) {
        close()
        action(model)
    }

    private func close() {
        moreMenu.hide()
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func open() {
        guard let button = item.button else { return }
        catchToast.hide()
        panel.showsQuickAdd = false
        panel.quickAdd = nil
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        window?.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        NSApp.activate()
        window?.makeKey()
        dismissal.start()
    }

    func popoverDidClose(_ notification: Notification) {
        moreMenu.hide()
        panel.showsQuickAdd = false
        panel.quickAdd = nil
        dismissal.stop()
    }

    private var isPointerOnIcon: Bool {
        guard let button = item.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    private func follow() {
        withObservationTracking {
            redraw(MenuBarSummary(rows: model.rows))
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func redraw(_ summary: MenuBarSummary) {
        let steps = Double(StatusIcon.progressSteps)
        let fraction = summary.progressFraction.map { ($0 * steps).rounded(.down) / steps }
        item.button?.setAccessibilityLabel("Dowlio, \(summary.status)")
        guard drawnFraction != .some(fraction) else { return }
        drawnFraction = .some(fraction)
        item.button?.image = StatusIcon.image(progress: fraction)
    }
}

/// The popover goes back to the list each time it opens.
@MainActor
@Observable
final class MenuBarPanel {
    var showsQuickAdd = false
    var quickAdd: NewDownloadModel?
    @ObservationIgnored weak var moreAnchor: NSView?
}

/// The menu bar icon: an arrow over a four-piece bar. While something downloads, the four
/// pieces become one bar of the same size that fills with progress. Both are templates, so macOS
/// draws them in the menu bar's own colour, and the arrow never moves.
enum StatusIcon {
    private static let side: CGFloat = 18
    private static let bar = CGRect(x: 1, y: 14.25, width: 16.8, height: 2)
    private static let pieceGap: CGFloat = 0.8

    /// Progress is drawn in steps of about one pixel, so it creeps rather than jumps.
    static let progressSteps = 34

    @MainActor
    static func image(progress fraction: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.setFill()
            arrow().fill()
            if let fraction {
                progressBar(fraction)
            } else {
                segments()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Dowlio"
        return image
    }

    private static func arrow() -> NSBezierPath {
        let path = NSBezierPath(roundedRect: NSRect(x: 7.75, y: 1, width: 2.5, height: 6.5), xRadius: 0.8, yRadius: 0.8)
        path.move(to: NSPoint(x: 4.25, y: 6.75))
        path.line(to: NSPoint(x: 13.75, y: 6.75))
        path.line(to: NSPoint(x: 9, y: 12))
        path.close()
        return path
    }

    private static func segments() {
        let width = (bar.width - pieceGap * 3) / 4
        for index in 0..<4 {
            let piece = NSRect(x: bar.minX + CGFloat(index) * (width + pieceGap), y: bar.minY, width: width, height: bar.height)
            if index < 3 {
                capsule(piece).fill()
            } else {
                let outline = capsule(piece.insetBy(dx: 0.35, dy: 0.35))
                outline.lineWidth = 0.7
                outline.stroke()
            }
        }
    }

    private static func progressBar(_ fraction: Double) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        capsule(bar).fill()
        let filled = bar.width * CGFloat(min(max(fraction, 0), 1))
        guard filled > 0 else { return }
        NSColor.black.setFill()
        capsule(NSRect(x: bar.minX, y: bar.minY, width: max(filled, bar.height), height: bar.height)).fill()
    }

    private static func capsule(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
    }
}
