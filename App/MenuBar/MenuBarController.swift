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
    private var outsideClicks: Any?
    private lazy var catchToast = CatchToast(model: model)

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarPopover(
            model: model, panel: panel,
            close: { [weak self] in self?.popover.performClose(nil) },
            showMore: { [weak self] in self?.showMoreMenu() }
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
                popover.performClose(nil)
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
        if !panel.showsQuickAdd || panel.quickAdd == nil {
            panel.quickAdd = model.makeNewDownload()
            panel.showsQuickAdd = true
        }
        panel.quickAdd?.draft.addSent(link.url, referrer: link.referrer)
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            open()
        }
    }

    private func open() {
        if let button = item.button {
            catchToast.hide()
            panel.showsQuickAdd = false
            panel.quickAdd = nil
            NSApp.activate()
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            watchOutsideClicks()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        panel.showsQuickAdd = false
        panel.quickAdd = nil
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    /// A click anywhere outside Dowlio closes the popover, even after a menu inside it was used.
    private func watchOutsideClicks() {
        guard outsideClicks == nil else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func showMoreMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Report a Problem", action: #selector(reportProblem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dowlio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        model.showSettings()
    }

    @objc private func reportProblem() {
        popover.performClose(nil)
        model.reportProblem()
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
