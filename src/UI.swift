import AppKit
import SwiftUI

// MARK: - Which metrics appear in the menu bar

enum Metric: String, CaseIterable {
    case cpu, ram, ssd, temp, watts, gpu, batt, fan

    var title: String {
        switch self {
        case .cpu:   return "CPU graph"
        case .ram:   return "Memory"
        case .ssd:   return "Disk"
        case .temp:  return "CPU temperature"
        case .watts: return "Power draw"
        case .gpu:   return "GPU"
        case .batt:  return "Battery"
        case .fan:   return "Fan"
        }
    }

    /// Three-letter stacked caption, matching the menu bar convention.
    var caption: String {
        switch self {
        case .cpu, .temp: return "CPU"
        case .ram:   return "RAM"
        case .ssd:   return "SSD"
        case .watts: return "PWR"
        case .gpu:   return "GPU"
        case .batt:  return "BAT"
        case .fan:   return "FAN"
        }
    }

    /// Roughly what one sample costs. Shown in the menu so the cost of enabling is visible.
    var costNote: String {
        switch self {
        case .cpu, .ram:  return "free"
        case .temp, .watts, .fan: return "~350µs / 3s"
        case .ssd, .gpu, .batt:   return "30s tier"
        }
    }

    static var enabled: [Metric] {
        get {
            guard let raw = UserDefaults.standard.array(forKey: "metrics") as? [String] else {
                return [.cpu, .ram, .ssd, .temp]     // matches the default layout
            }
            return raw.compactMap(Metric.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "metrics")
        }
    }
}

// MARK: - Menu bar rendering
//
// Drawn into a template NSImage rather than a custom NSView: the button handles
// hit-testing for us, and template images adapt to light/dark menu bars for free.

enum Bar {
    static let height: CGFloat = 22
    static let gaugeH: CGFloat = 13
    static let capFont = NSFont.systemFont(ofSize: 5.5, weight: .semibold)
    // Monospaced digits stop the bar from jittering as values change width.
    static let valFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private static let capWidth: CGFloat = 7
    private static let capLineH: CGFloat = 5.2
    private static let capAlpha: CGFloat = 0.72

    // Everything below is rebuilt at most once per distinct string. Re-creating and
    // re-measuring attributed strings every tick was the single largest cost in the app.
    private static var valueCache: [String: (text: NSAttributedString, width: CGFloat, height: CGFloat)] = [:]

    /// Caption glyphs are fixed per metric, so lay them out exactly once.
    private static let captions: [Metric: [(glyph: NSAttributedString, dx: CGFloat)]] = {
        var out: [Metric: [(NSAttributedString, CGFloat)]] = [:]
        // Must stay the unmodified dynamic colour so it re-resolves for light/dark each draw.
        // Dimming is applied via context alpha at draw time instead.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: capFont, .foregroundColor: NSColor.labelColor,
        ]
        for m in Metric.allCases {
            out[m] = Array(m.caption).map { ch in
                let a = NSAttributedString(string: String(ch), attributes: attrs)
                return (a, (capWidth - a.size().width) / 2)
            }
        }
        return out
    }()

    private static func valueText(_ s: String) -> (text: NSAttributedString, width: CGFloat, height: CGFloat) {
        if let hit = valueCache[s] { return hit }
        let a = NSAttributedString(string: s, attributes: [.font: valFont, .foregroundColor: NSColor.labelColor])
        let size = a.size()
        let entry = (a, ceil(size.width), size.height)
        if valueCache.count > 128 { valueCache.removeAll(keepingCapacity: true) }
        valueCache[s] = entry
        return entry
    }

    /// Value string per metric, or nil when the metric renders a gauge instead.
    private static func value(_ m: Metric, _ s: Snapshot) -> String? {
        switch m {
        case .cpu:   return nil
        case .ram:   return "\(Int(s.ramPct.rounded()))%"
        case .ssd:   return "\(Int(s.diskPct.rounded()))%"
        case .temp:  return s.temp > 0 ? "\(Int(s.temp.rounded()))°" : "—"
        case .watts: return String(format: "%.1fW", s.watts)
        case .gpu:   return "\(Int(s.gpu.rounded()))%"
        case .batt:  return "\(Int(s.battPct.rounded()))%"
        case .fan:   return s.fan > 0 ? "\(Int(s.fan))" : "off"
        }
    }

    /// Fill fraction for metrics that show a vertical gauge.
    private static func fill(_ m: Metric, _ s: Snapshot) -> Double? {
        switch m {
        case .ram:  return s.ramPct / 100
        case .ssd:  return s.diskPct / 100
        case .batt: return s.battPct / 100
        default:    return nil
        }
    }

    private static func width(_ m: Metric, _ s: Snapshot) -> CGFloat {
        var w = capWidth
        if m == .cpu { return w + 2 + 34 }
        if fill(m, s) != nil { w += 2 + 5 }
        if let v = value(m, s) { w += 3 + valueText(v).width }
        return w
    }

    static let gap: CGFloat = 8

    static func totalWidth(_ s: Snapshot, metrics: [Metric]) -> CGFloat {
        let w = metrics.reduce(0) { $0 + width($1, s) }
        return w + gap * CGFloat(max(metrics.count - 1, 0)) + 4
    }

    static func drawAll(_ s: Snapshot, history: [Double], metrics: [Metric]) {
        var x: CGFloat = 2
        for m in metrics {
            draw(m, s, history: history, at: x)
            x += width(m, s) + gap
        }
    }

    private static func draw(_ m: Metric, _ s: Snapshot, history: [Double], at x: CGFloat) {
        let midY = height / 2
        var cx = x

        // Stacked three-letter caption, one glyph per row.
        if let glyphs = captions[m] {
            let block = capLineH * CGFloat(glyphs.count)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(capAlpha)
            for (i, g) in glyphs.enumerated() {
                g.glyph.draw(at: NSPoint(x: cx + g.dx, y: midY + block / 2 - capLineH * CGFloat(i + 1)))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        cx += capWidth

        if m == .cpu {
            drawSparkline(history, rect: NSRect(x: cx + 2, y: midY - gaugeH / 2, width: 34, height: gaugeH))
            return
        }
        if let f = fill(m, s) {
            drawGauge(f, rect: NSRect(x: cx + 2, y: midY - gaugeH / 2, width: 5, height: gaugeH))
            cx += 7
        }
        if let v = value(m, s) {
            let e = valueText(v)
            e.text.draw(at: NSPoint(x: cx + 3, y: midY - e.height / 2))
        }
    }

    private static func drawGauge(_ fraction: Double, rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let h = rect.height * CGFloat(min(max(fraction, 0), 1))
        guard h > 0 else { return }
        let inner = NSRect(x: rect.minX + 1, y: rect.minY + 1,
                           width: rect.width - 2, height: max(h - 2, 0.5))
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: inner, xRadius: 0.8, yRadius: 0.8).fill()
    }

    private static func drawSparkline(_ history: [Double], rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        border.lineWidth = 1
        border.stroke()

        guard history.count > 1 else { return }
        let inset = rect.insetBy(dx: 1.5, dy: 1.5)
        let step = inset.width / CGFloat(history.count - 1)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset.minX, y: inset.minY))
        for (i, v) in history.enumerated() {
            let y = inset.minY + inset.height * CGFloat(min(max(v, 0), 100) / 100)
            path.line(to: NSPoint(x: inset.minX + step * CGFloat(i), y: y))
        }
        path.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        path.close()
        NSColor.labelColor.withAlphaComponent(0.80).setFill()
        path.fill()
    }
}


/// Draws the bar directly. Marking this view dirty is far cheaper than assigning a new
/// image to the status item, which forces AppKit to re-run status bar layout each tick.
final class BarView: NSView {
    var snap = Snapshot()
    var history: [Double] = []
    var metrics: [Metric] = []

    override func draw(_ dirtyRect: NSRect) {
        Bar.drawAll(snap, history: history, metrics: metrics)
    }

    /// Let clicks fall through to the status item button, which already handles them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
