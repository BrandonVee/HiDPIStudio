import AppKit

// Draw in a 1024-point coordinate space so every icon size shares the same geometry.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha)
}

func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// A superellipse has continuously changing corner curvature, unlike circular arcs.
func squircle(_ rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let exponent = 4.5
    for step in 0..<256 {
        let angle = Double(step) * 2 * Double.pi / 256
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = pow(abs(cosine), 2 / exponent) * (cosine < 0 ? -1 : 1)
        let y = pow(abs(sine), 2 / exponent) * (sine < 0 ? -1 : 1)
        let point = NSPoint(
            x: rect.midX + CGFloat(x) * rect.width / 2,
            y: rect.midY + CGFloat(y) * rect.height / 2)
        if step == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func gradient(_ colors: [NSColor], in path: NSBezierPath, angle: CGFloat) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

func shadow(blur: CGFloat, offset: NSSize, opacity: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(pixels: Int) {
    let tile = squircle(NSRect(x: 64, y: 64, width: 896, height: 896))
    shadow(blur: 24, offset: NSSize(width: 0, height: -12), opacity: 0.18) {
        gradient([color(0xD8E2F0), color(0xFAFCFF)], in: tile, angle: 90)
    }

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    // A quiet upper edge gives the tile depth without competing with the mark.
    let rim = squircle(NSRect(x: 65, y: 65, width: 894, height: 894))
    color(0xFFFFFF, alpha: 0.8).setStroke()
    rim.lineWidth = 2
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 470, y: 356))
    stem.line(to: NSPoint(x: 554, y: 356))
    stem.line(to: NSPoint(x: 572, y: 257))
    stem.curve(
        to: NSPoint(x: 598, y: 238), controlPoint1: NSPoint(x: 575, y: 245), controlPoint2: NSPoint(x: 584, y: 240))
    stem.line(to: NSPoint(x: 426, y: 238))
    stem.curve(
        to: NSPoint(x: 452, y: 257), controlPoint1: NSPoint(x: 440, y: 240), controlPoint2: NSPoint(x: 449, y: 245))
    stem.close()
    gradient([color(0x71859C), color(0xD9E4EE), color(0x9DACC0)], in: stem, angle: 0)

    let foot = rounded(NSRect(x: 354, y: 216, width: 316, height: 32), radius: 16)
    shadow(blur: 18, offset: NSSize(width: 0, height: -10), opacity: 0.32) {
        gradient([color(0x8D9FB5), color(0xF0F5FC)], in: foot, angle: 90)
    }

    let frame = rounded(NSRect(x: 176, y: 326, width: 672, height: 456), radius: 48)
    shadow(blur: 30, offset: NSSize(width: 0, height: -16), opacity: 0.38) {
        gradient([color(0x7C8EA5), color(0xD9E3EF)], in: frame, angle: 90)
    }

    let bezel = rounded(NSRect(x: 187, y: 361, width: 650, height: 410), radius: 38)
    color(0x0A1528).setFill()
    bezel.fill()

    let screen = rounded(NSRect(x: 198, y: 372, width: 628, height: 388), radius: 28)
    NSGraphicsContext.saveGraphicsState()
    screen.addClip()
    gradient([color(0x1747D1), color(0x3267F5), color(0x61D9ED)], in: screen, angle: 32)

    // Broad, overlapping ribbons suggest a crisp, luminous display at Dock sizes.
    let violet = NSBezierPath()
    violet.move(to: NSPoint(x: 320, y: 372))
    violet.curve(
        to: NSPoint(x: 826, y: 760), controlPoint1: NSPoint(x: 506, y: 400), controlPoint2: NSPoint(x: 448, y: 753))
    violet.line(to: NSPoint(x: 826, y: 372))
    violet.close()
    gradient([color(0x3F3CE4), color(0x9B6AF1), color(0xF5A4C3)], in: violet, angle: 58)

    let warm = NSBezierPath()
    warm.move(to: NSPoint(x: 548, y: 372))
    warm.curve(
        to: NSPoint(x: 826, y: 676), controlPoint1: NSPoint(x: 700, y: 395), controlPoint2: NSPoint(x: 681, y: 620))
    warm.line(to: NSPoint(x: 826, y: 372))
    warm.close()
    gradient([color(0xE45A93), color(0xFFB89C), color(0xFFE2BC)], in: warm, angle: 48)

    let light = NSBezierPath()
    light.move(to: NSPoint(x: 198, y: 438))
    light.curve(
        to: NSPoint(x: 730, y: 760), controlPoint1: NSPoint(x: 410, y: 442), controlPoint2: NSPoint(x: 363, y: 697))
    light.line(to: NSPoint(x: 198, y: 760))
    light.close()
    gradient([color(0x287FEB), color(0x52CFEE), color(0xB8FFF0)], in: light, angle: 80)
    NSGraphicsContext.restoreGraphicsState()

    // Omit the fine pixel motif at the smallest sizes to keep the silhouette clean.
    if pixels >= 64 {
        let dotSize: CGFloat = 10
        for row in 0..<2 {
            for column in 0..<2 {
                color(0xFFFFFF, alpha: 0.88).setFill()
                rounded(
                    NSRect(x: 744 + CGFloat(column) * 16, y: 686 + CGFloat(row) * 16, width: dotSize, height: dotSize),
                    radius: 2
                ).fill()
            }
        }
    }

    let indicator = rounded(NSRect(x: 493, y: 341, width: 38, height: 5), radius: 2.5)
    color(0x536A86, alpha: 0.65).setFill()
    indicator.fill()
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(pixels: pixels)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
