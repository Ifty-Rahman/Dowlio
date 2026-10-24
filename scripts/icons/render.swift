import AppKit

// Draws Dowlio's 16 and 32 px app icons as vectors, on a 1024-unit canvas matching Flow's art.
// The menu bar icon is drawn by the app itself, in StatusIcon.

func png(size: Int, scale: Int = 1, draw: (CGContext, CGFloat) -> Void) -> Data {
    let pixels = size * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 1, y: -1)
    draw(context, CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The arrow alone, for sizes where the segmented bar would be a smudge.
func smallAppIcon(_ context: CGContext, _ side: CGFloat) {
    let unit = side / 1024
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * unit, y: y * unit, width: w * unit, height: h * unit)
    }
    let tile = CGPath(roundedRect: rect(100, 100, 824, 824), cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)
    context.addPath(tile)
    context.clip()
    let colors = [CGColor(srgbRed: 0.17, green: 0.38, blue: 0.91, alpha: 1), CGColor(srgbRed: 0.13, green: 0.28, blue: 0.77, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100 * unit), end: CGPoint(x: 0, y: 924 * unit), options: [])
    context.resetClip()

    context.setFillColor(.white)
    let shaft = CGPath(roundedRect: rect(450, 250, 124, 300), cornerWidth: 40 * unit, cornerHeight: 40 * unit, transform: nil)
    context.addPath(shaft)
    context.fillPath()
    context.move(to: CGPoint(x: 300 * unit, y: 500 * unit))
    context.addLine(to: CGPoint(x: 724 * unit, y: 500 * unit))
    context.addLine(to: CGPoint(x: 512 * unit, y: 770 * unit))
    context.closePath()
    context.fillPath()
}

let arguments = CommandLine.arguments
let appIconFolder = URL(filePath: arguments[1], directoryHint: .isDirectory)
try png(size: 16, draw: smallAppIcon).write(to: appIconFolder.appending(path: "icon_16x16.png"))
try png(size: 16, scale: 2, draw: smallAppIcon).write(to: appIconFolder.appending(path: "icon_16x16@2x.png"))
try png(size: 32, draw: smallAppIcon).write(to: appIconFolder.appending(path: "icon_32x32.png"))
