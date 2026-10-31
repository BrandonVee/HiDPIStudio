import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.12, green: 0.39, blue: 0.84, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210).fill()
        NSColor.white.setStroke()
        let monitor = NSBezierPath(roundedRect: NSRect(x: 216, y: 340, width: 592, height: 400), xRadius: 42, yRadius: 42)
        monitor.lineWidth = 36; monitor.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 512, y: 340)); stand.line(to: NSPoint(x: 512, y: 245))
        stand.move(to: NSPoint(x: 385, y: 245)); stand.line(to: NSPoint(x: 639, y: 245))
        stand.lineWidth = 36; stand.lineCapStyle = .round; stand.stroke()
        let text = "2×" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 185, weight: .semibold), .foregroundColor: NSColor.white]
        let dimensions = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (1024 - dimensions.width) / 2, y: 425), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
