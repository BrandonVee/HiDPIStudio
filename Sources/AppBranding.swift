import AppKit

enum AppBranding {
    static let icon: NSImage? = Bundle.main.url(forResource: "BrandIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            NSColor.black.setStroke()
            let screen = NSBezierPath(
                roundedRect: NSRect(x: 1.75, y: 6.25, width: 18.5, height: 13.5), xRadius: 2, yRadius: 2)
            screen.lineWidth = 1.5
            screen.stroke()

            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 11, y: 6))
            stand.line(to: NSPoint(x: 11, y: 3))
            stand.move(to: NSPoint(x: 7, y: 2.75))
            stand.line(to: NSPoint(x: 15, y: 2.75))
            stand.lineWidth = 1.5
            stand.lineCapStyle = .round
            stand.stroke()

            NSColor.black.setFill()
            for row in 0..<2 {
                for column in 0..<2 {
                    NSBezierPath(
                        roundedRect: NSRect(
                            x: 13 + CGFloat(column) * 3, y: 12 + CGFloat(row) * 3, width: 2, height: 2),
                        xRadius: 0.4, yRadius: 0.4
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
