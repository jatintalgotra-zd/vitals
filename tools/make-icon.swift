import AppKit

// Draws the app icon at any size. A pulse trace on a dark panel: the shape stays
// readable at 16px, which is where most app icons fall apart.
func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size
        guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

        // macOS icons sit inside a rounded square with padding around it.
        let inset = s * 0.098
        let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = rect.width * 0.225
        let panel = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        ctx.saveGState()
        panel.addClip()
        let bg = NSGradient(colors: [
            NSColor(srgbRed: 0.14, green: 0.17, blue: 0.21, alpha: 1),
            NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1),
        ])!
        bg.draw(in: rect, angle: -90)

        // Faint baseline, so the trace reads as a reading rather than a logo.
        let mid = rect.midY
        let base = NSBezierPath()
        base.move(to: NSPoint(x: rect.minX, y: mid))
        base.line(to: NSPoint(x: rect.maxX, y: mid))
        base.lineWidth = s * 0.008
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setStroke()
        base.stroke()

        // The pulse itself, in normalised coordinates.
        let pts: [(CGFloat, CGFloat)] = [
            (0.00, 0.50), (0.26, 0.50), (0.35, 0.33), (0.44, 0.70),
            (0.54, 0.14), (0.63, 0.50), (0.72, 0.50), (0.79, 0.41),
            (0.86, 0.50), (1.00, 0.50),
        ]
        let trace = NSBezierPath()
        for (i, p) in pts.enumerated() {
            let pt = NSPoint(x: rect.minX + rect.width * p.0, y: rect.minY + rect.height * p.1)
            i == 0 ? trace.move(to: pt) : trace.line(to: pt)
        }
        trace.lineWidth = s * 0.062
        trace.lineCapStyle = .round
        trace.lineJoinStyle = .round

        ctx.setShadow(offset: .zero, blur: s * 0.05,
                      color: NSColor(srgbRed: 0.24, green: 0.86, blue: 0.52, alpha: 0.9).cgColor)
        NSColor(srgbRed: 0.24, green: 0.86, blue: 0.52, alpha: 1).setStroke()
        trace.stroke()
        ctx.restoreGState()

        // Hairline edge keeps the panel from bleeding into a dark background.
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setStroke()
        panel.lineWidth = s * 0.004
        panel.stroke()
        return true
    }
    return img
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
                   (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),
                   (512,"512x512"),(1024,"512x512@2x")] {
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote iconset to \(out)")
