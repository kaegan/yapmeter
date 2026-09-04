import AppKit

/// Renders the menu bar status image: a single lamp in the aspect's colour,
/// plus your turn's elapsed time when you're the one talking. This is the
/// app's entire display; the menu behind it holds settings only.
///
/// One lamp, not the four-lamp head. At 18pt the full head is four 12pt lamps
/// with three of them dark, which reads as a smudge rather than a signal.
///
/// `MenuBarExtra` tends to force template (monochrome) rendering on
/// SwiftUI-provided label content, so we draw and cache real `NSImage`s with
/// `isTemplate = false` ourselves.
@MainActor
enum SignalHeadRenderer {
    private static var lampCache: [Aspect: NSImage] = [:]

    private static let height: CGFloat = 18
    private static let lampDiameter: CGFloat = 11
    private static let horizontalPadding: CGFloat = 2
    private static let lampTextGap: CGFloat = 5

    static func menuBarImage(for aspect: Aspect, speakingSeconds: Int?) -> NSImage {
        guard let speakingSeconds else {
            return lampOnlyImage(for: aspect)
        }
        return lampWithTimeImage(for: aspect, label: timeLabel(speakingSeconds))
    }

    /// mm:ss, no hours: a turn long enough to need them has bigger problems.
    static func timeLabel(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    static func color(for aspect: Aspect) -> NSColor {
        switch aspect {
        case .dark: return .tertiaryLabelColor
        // Blue, not another lamp colour: "you" needs to be unmistakable
        // against the red/yellow/green of the block itself.
        case .speaking: return .systemBlue
        case .occupied: return .systemRed
        case .caution, .preliminary: return .systemYellow
        case .clear: return .systemGreen
        }
    }

    // MARK: - Drawing

    private static func lampOnlyImage(for aspect: Aspect) -> NSImage {
        if let cached = lampCache[aspect] { return cached }
        let image = aspect == .dark ? darkSignalImage() : litLampImage(for: aspect)
        image.accessibilityDescription = aspect.displayName
        lampCache[aspect] = image
        return image
    }

    private static func litLampImage(for aspect: Aspect) -> NSImage {
        let width = lampDiameter + horizontalPadding * 2
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            draw(lamp: lampRect(atX: horizontalPadding), aspect: aspect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// No meeting: the app's namesake, a semaphore post with its arm out
    /// horizontal, drawn as a template image so the menu bar tints it like
    /// its own icons (and highlights it when the menu is open) rather than
    /// leaving a lone grey ring that reads as "broken".
    private static func darkSignalImage() -> NSImage {
        let width: CGFloat = 17
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.black.setFill()
            // Post, from the base to just shy of the top.
            NSBezierPath(
                roundedRect: NSRect(x: 3, y: 1.5, width: 2.2, height: 15),
                xRadius: 1.1, yRadius: 1.1
            ).fill()
            // Arm, pivoting at the post's head and reaching out to the right.
            NSBezierPath(
                roundedRect: NSRect(x: 3, y: 11.5, width: 12, height: 3),
                xRadius: 1.5, yRadius: 1.5
            ).fill()
            // Base, so it stands on something.
            NSBezierPath(
                roundedRect: NSRect(x: 0.5, y: 1, width: 7.2, height: 2),
                xRadius: 1, yRadius: 1
            ).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Not cached: the label changes every second, and caching per-label would
    /// grow a dictionary entry per second of every meeting.
    private static func lampWithTimeImage(for aspect: Aspect, label: String) -> NSImage {
        // Label colour at the menu bar's own size, so the timer sits like the
        // clock's text does. The blue lamp beside it already says "you".
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let textSize = text.size()
        let width = horizontalPadding * 2 + lampDiameter + lampTextGap + ceil(textSize.width)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            draw(lamp: lampRect(atX: horizontalPadding), aspect: aspect)
            let textOrigin = NSPoint(
                x: horizontalPadding + lampDiameter + lampTextGap,
                y: (rect.height - textSize.height) / 2
            )
            text.draw(at: textOrigin)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "\(aspect.displayName), \(label)"
        return image
    }

    private static func lampRect(atX x: CGFloat) -> NSRect {
        NSRect(x: x, y: (height - lampDiameter) / 2, width: lampDiameter, height: lampDiameter)
    }

    /// A lit lamp is a filled disc with a soft glow behind it. The dark
    /// aspect never comes through here; see `darkSignalImage()`.
    private static func draw(lamp rect: NSRect, aspect: Aspect) {
        let path = NSBezierPath(ovalIn: rect)
        let lampColor = color(for: aspect)
        let glowRect = rect.insetBy(dx: -3, dy: -3)
        if let glow = NSGradient(
            starting: lampColor.withAlphaComponent(0.55),
            ending: lampColor.withAlphaComponent(0.0)
        ) {
            glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
        }
        lampColor.setFill()
        path.fill()
    }
}
