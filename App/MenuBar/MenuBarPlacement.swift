import AppKit

enum MenuBarPlacement {
    static func frame(size: NSSize, under anchor: NSRect, gap: CGFloat, screens: [NSScreen] = NSScreen.screens) -> NSRect {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let anchored = anchor.width > 0 ? screens.first { $0.frame.contains(center) } : nil
        guard let screen = anchored ?? screens.first else { return NSRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        let midX = anchored == nil ? visible.maxX : anchor.midX
        let x = min(max(midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let top = anchored == nil ? visible.maxY - gap : min(anchor.minY - gap, visible.maxY)
        let y = max(top - size.height, visible.minY)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
