import AppKit

/// Renders each `Aspect` as a small horizontal signal head — four lamps,
/// the active one(s) lit with a soft glow — for use as the menu bar status
/// item image.
///
/// `MenuBarExtra` in `.window` style tends to force template (monochrome)
/// rendering on SwiftUI-provided label content, so we draw and cache real
/// `NSImage`s with `isTemplate = false` ourselves. If that still gets
/// flattened to template by SwiftUI, the fallback is a raw `NSStatusItem`
/// via `NSApplicationDelegateAdaptor` (see SemaphoreApp.swift comment).
@MainActor
enum SignalHeadRenderer {
    private static var cache: [Aspect: NSImage] = [:]

    static func image(for aspect: Aspect) -> NSImage {
        if let cached = cache[aspect] {
            return cached
        }
        let image = render(aspect)
        cache[aspect] = image
        return image
    }

    private static func render(_ aspect: Aspect) -> NSImage {
        let size = NSSize(width: 44, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let lampCount = 4
            let lampDiameter: CGFloat = 12
            let spacing = (rect.width - (CGFloat(lampCount) * lampDiameter)) / CGFloat(lampCount + 1)
            let y = (rect.height - lampDiameter) / 2

            for index in 0..<lampCount {
                let x = spacing + CGFloat(index) * (lampDiameter + spacing)
                let lampRect = NSRect(x: x, y: y, width: lampDiameter, height: lampDiameter)
                let isLit = litLampIndices(for: aspect).contains(index)
                draw(lampRect: lampRect, color: litColor(for: aspect), isLit: isLit)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Which of the 4 lamp positions are lit for a given aspect.
    /// occupied = lamp 0 (red), caution = lamp 1 (single yellow),
    /// preliminary = lamps 1+2 (double yellow), clear = lamp 3 (green).
    private static func litLampIndices(for aspect: Aspect) -> Set<Int> {
        switch aspect {
        case .dark: return []
        case .occupied: return [0]
        case .caution: return [1]
        case .preliminary: return [1, 2]
        case .clear: return [3]
        }
    }

    private static func litColor(for aspect: Aspect) -> NSColor {
        switch aspect {
        case .dark: return .clear
        case .occupied: return .systemRed
        case .caution, .preliminary: return .systemYellow
        case .clear: return .systemGreen
        }
    }

    private static func draw(lampRect: NSRect, color: NSColor, isLit: Bool) {
        if isLit {
            // Soft glow behind the lamp.
            let glowRect = lampRect.insetBy(dx: -3, dy: -3)
            if let glow = NSGradient(starting: color.withAlphaComponent(0.55), ending: color.withAlphaComponent(0.0)) {
                glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
            }
            color.setFill()
        } else {
            NSColor.white.withAlphaComponent(0.18).setFill()
        }
        NSBezierPath(ovalIn: lampRect).fill()
    }
}
