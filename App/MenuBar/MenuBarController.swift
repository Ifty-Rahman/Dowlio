import AppKit
import DowlioLibrary
import Observation
import SwiftUI

/// Dowlio's menu bar item: an icon with a thin progress ring while downloading, and a popover.
/// AppKit owns it, because SwiftUI's menu bar extra can't be opened from code, and later phases
/// open the catch toast and the Send panel from it.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let panel = MenuBarPanel()
    private var drawnFraction: Double??

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarPopover(model: model, panel: panel) { [weak self] in
            self?.popover.performClose(nil)
        })
        item.button?.target = self
        item.button?.action = #selector(toggle)
        follow()
        if DebugLaunch.opensPopover {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.toggle()
                if DebugLaunch.quickAddLink != nil { self?.panel.showsQuickAdd = true }
            }
        }
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            panel.showsQuickAdd = false
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        panel.showsQuickAdd = false
    }

    private func follow() {
        withObservationTracking {
            redraw(MenuBarSummary(rows: model.rows))
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    private func redraw(_ summary: MenuBarSummary) {
        let fraction = summary.ringFraction.map { ($0 * 40).rounded() / 40 }
        item.button?.setAccessibilityLabel("Dowlio, \(summary.status)")
        guard drawnFraction != .some(fraction) else { return }
        drawnFraction = .some(fraction)
        item.button?.image = StatusIcon.image(ring: fraction)
    }
}

/// The popover goes back to the list each time it opens.
@MainActor
@Observable
final class MenuBarPanel {
    var showsQuickAdd = false
}

/// The menu bar icon, with a ring around a smaller icon while something downloads. Both are
/// templates, so macOS draws them in the menu bar's own colour.
enum StatusIcon {
    @MainActor
    static func image(ring fraction: Double?) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        guard let fraction else {
            base.isTemplate = true
            return base
        }
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset: CGFloat = 4.5
            base.draw(in: rect.insetBy(dx: inset, dy: inset))
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = side / 2 - 1
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
