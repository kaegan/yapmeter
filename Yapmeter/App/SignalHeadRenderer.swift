import AppKit

/// Renders the menu bar status image: Yap, the pet, in the aspect's colour,
/// plus your turn's elapsed time when you're the one talking. This is the
/// app's entire display; the menu behind it holds settings only.
///
/// The pet is drawn in the sketch's own 16-unit, y-down coordinates and
/// scaled into a 20pt box inside the 22pt image, so the drawing translates
/// across unchanged and still sits at the size of the icons around it (a
/// 16pt box left the body at 11pt, once the tail had its share). Eyes and
/// mouths are cut out of the body rather than painted in a background
/// colour, because the menu bar has no fixed background to match.
///
/// `MenuBarExtra` tends to force template (monochrome) rendering on
/// SwiftUI-provided label content, so we draw and cache real `NSImage`s with
/// `isTemplate = false` ourselves.
@MainActor
enum SignalHeadRenderer {
    private static var cache: [Aspect: NSImage] = [:]

    /// The menu bar is 24pt; this leaves a point above and below.
    static let imageHeight: CGFloat = 22
    private static let glyphHeight: CGFloat = 20
    /// The sketch is drawn in a 16-unit box.
    private static let sketchUnits: CGFloat = 16
    private static let glyphScale = glyphHeight / sketchUnits
    /// The pet's box is as wide as it is tall.
    static let glyphWidth: CGFloat = ceil(sketchUnits * glyphScale)
    private static let horizontalPadding: CGFloat = 2
    private static let glyphTextGap: CGFloat = 5

    /// How long you've been talking, in the pet's opinion. He starts out
    /// happy to be yapping, loses the sparkle at two minutes, and at four is
    /// full: puffed up, eyes flat.
    enum TurnStage: Sendable {
        case fresh, tiring, full
    }

    static let tiringSeconds = 120
    static let longTurnSeconds = 240

    static func stage(forSpeakingSeconds seconds: Int?) -> TurnStage {
        guard let seconds else { return .fresh }
        if seconds >= longTurnSeconds { return .full }
        if seconds >= tiringSeconds { return .tiring }
        return .fresh
    }

    static func menuBarImage(for aspect: Aspect, speakingSeconds: Int?) -> NSImage {
        guard let speakingSeconds else {
            return petOnlyImage(for: aspect)
        }
        return petWithTimeImage(
            for: aspect,
            label: timeLabel(speakingSeconds),
            stage: stage(forSpeakingSeconds: speakingSeconds)
        )
    }

    /// mm:ss, no hours: a turn long enough to need them has bigger problems.
    static func timeLabel(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    // MARK: - Images

    private static func petOnlyImage(for aspect: Aspect) -> NSImage {
        if let cached = cache[aspect] { return cached }
        let width = horizontalPadding * 2 + glyphWidth
        let image = NSImage(size: NSSize(width: width, height: imageHeight), flipped: true) { _ in
            draw(aspect: aspect, stage: .fresh, atX: horizontalPadding)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = aspect.displayName
        cache[aspect] = image
        return image
    }

    /// Not cached: the label changes every second, and caching per-label would
    /// grow a dictionary entry per second of every meeting.
    private static func petWithTimeImage(for aspect: Aspect, label: String, stage: TurnStage) -> NSImage {
        // Label colour at the menu bar's own size, so the timer sits like the
        // clock's text does. The pet beside it already says "you".
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let textSize = text.size()
        let width = horizontalPadding * 2 + glyphWidth + glyphTextGap + ceil(textSize.width)

        let image = NSImage(size: NSSize(width: width, height: imageHeight), flipped: true) { rect in
            draw(aspect: aspect, stage: stage, atX: horizontalPadding)
            let textOrigin = NSPoint(
                x: horizontalPadding + glyphWidth + glyphTextGap,
                y: (rect.height - textSize.height) / 2
            )
            text.draw(at: textOrigin)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "\(aspect.displayName), \(label)"
        return image
    }

    // MARK: - Drawing

    /// The aspects collapse to five faces: the two yellows look the same.
    private enum Phase {
        case dark, them, pause, clear, you

        /// Whether the floor is yours. The pet turns his tail to your side
        /// (the right, as in any chat app) from the moment it is, so the flip
        /// itself is the "go" cue.
        var isYours: Bool {
            switch self {
            case .dark, .them, .pause: return false
            case .clear, .you: return true
            }
        }
    }

    private static func phase(of aspect: Aspect) -> Phase {
        switch aspect {
        case .dark: return .dark
        case .occupied: return .them
        case .caution, .preliminary: return .pause
        case .clear: return .clear
        case .speaking: return .you
        }
    }

    private static func draw(aspect: Aspect, stage: TurnStage, atX x: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // A transparency layer so the cut-outs erase the pet only, not
        // whatever the menu bar has behind it.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: x, y: (imageHeight - glyphHeight) / 2)
        context.scaleBy(x: glyphScale, y: glyphScale)
        let pen = Pen(context: context, state: PetPalette.color(for: aspect))
        drawPet(pen, phase(of: aspect), stage: stage)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func drawPet(_ pen: Pen, _ phase: Phase, stage: TurnStage) {
        let body = petBody(yours: phase.isYours)
        pen.fill(body, pen.state)
        switch phase {
        case .dark:
            pen.cutStroke(sleepEyes(), width: 1.2)
        case .them:
            pen.cut(eyes(6.2, 10.6))
            // A hand over the mouth.
            pen.cut(box(6.3, 9.8, 4.2, 1.7, radius: 0.85))
        case .pause:
            // Glancing their way.
            pen.cut(eyes(5.7, 10.1))
            pen.cutStroke(line(6.7, 10.6, 10.1, 10.6), width: 1.2)
        case .clear:
            pen.cut(eyes(6.2, 10.6))
            pen.cutStroke(petSmile(), width: 1.4)
        case .you:
            yappingFace(pen, body: body, stage: stage)
        }
    }

    /// The talking face, by how long you've been at it. Happy arcs and a wide
    /// open mouth to start; plain eyes at two minutes; at four, puffed up
    /// with everything gone flat.
    private static func yappingFace(_ pen: Pen, body: NSBezierPath, stage: TurnStage) {
        switch stage {
        case .fresh:
            pen.cutStroke(happyEyes(), width: 1.2)
            pen.cut(yapMouth())
        case .tiring:
            pen.cut(eyes(6.2, 10.6))
            pen.cut(yapMouth())
        case .full:
            pen.cut(body)
            pen.scaled(1.14, around: petCentre) {
                pen.fill(body, pen.state)
                pen.cutStroke(sleepEyes(), width: 1.2)
                pen.cutStroke(line(6.4, 10.8, 10.4, 10.8), width: 1.4)
            }
        }
    }

    // MARK: - Shapes

    /// Where the pet's body is centred; the long-turn puff scales about it.
    private static let petCentre = NSPoint(x: 8.4, y: 8)

    /// The blob, with the tail on the lower corner at 45°. Straight down it
    /// took a quarter of the box and left the body at 11 units; on the
    /// corner it costs almost no height and the body fills 13. The tail is
    /// on their side (left) until the floor is yours, then on yours (right),
    /// as chat bubbles are.
    private static func petBody(yours: Bool = false) -> NSBezierPath {
        let path = NSBezierPath()
        // The long way round from the tail's near edge to its far edge, then
        // out to the tip and back.
        path.appendArc(withCenter: petCentre, radius: 6.5, startAngle: 120, endAngle: 150, clockwise: true)
        path.line(to: NSPoint(x: 1.2, y: 15.2))
        path.close()
        return yours ? mirrored(path) : path
    }

    /// Flipped left-to-right about the pet's centre line, so the body stays
    /// exactly where it was and only the tail changes side.
    private static func mirrored(_ path: NSBezierPath) -> NSBezierPath {
        path.transform(using: AffineTransform(m11: -1, m12: 0, m21: 0, m22: 1, tX: petCentre.x * 2, tY: 0))
        return path
    }

    private static func eyes(_ left: CGFloat, _ right: CGFloat, y: CGFloat = 7.2, radius: CGFloat = 1.05) -> NSBezierPath {
        let path = circle(left, y, radius)
        path.append(circle(right, y, radius))
        return path
    }

    private static func sleepEyes() -> NSBezierPath {
        let path = curve(from: (5, 7.3), via: (6.3, 8.6), to: (7.6, 7.3))
        path.append(curve(from: (9.2, 7.3), via: (10.5, 8.6), to: (11.8, 7.3)))
        return path
    }

    private static func happyEyes() -> NSBezierPath {
        let path = curve(from: (5, 7.7), via: (6.3, 6.2), to: (7.6, 7.7))
        path.append(curve(from: (9.2, 7.7), via: (10.5, 6.2), to: (11.8, 7.7)))
        return path
    }

    private static func petSmile() -> NSBezierPath {
        curve(from: (5.9, 9.9), via: (8.4, 12.6), to: (10.9, 9.9))
    }

    /// The open, talking mouth: flat on top, round underneath, twice as wide
    /// as it is deep, so it reads as yapping rather than surprised.
    private static func yapMouth() -> NSBezierPath {
        bowl(x: 5.6, y: 9.6, width: 5.6, depth: 4)
    }

    /// A half-ellipse hanging from a flat top edge. `depth` is the control
    /// depth; the bowl's bottom lands three quarters of the way down it.
    private static func bowl(x: CGFloat, y: CGFloat, width: CGFloat, depth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + width, y: y))
        path.curve(
            to: NSPoint(x: x, y: y),
            controlPoint1: NSPoint(x: x + width, y: y + depth),
            controlPoint2: NSPoint(x: x, y: y + depth)
        )
        path.close()
        return path
    }

    // MARK: - Primitives, in the sketch's y-down coordinates

    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }

    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
    }

    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: y1))
        path.line(to: NSPoint(x: x2, y: y2))
        return path
    }

    /// A quadratic curve, as the sketch uses, lifted to the cubic AppKit draws.
    private static func curve(
        from start: (CGFloat, CGFloat),
        via control: (CGFloat, CGFloat),
        to end: (CGFloat, CGFloat)
    ) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: start.0, y: start.1))
        path.curve(
            to: NSPoint(x: end.0, y: end.1),
            controlPoint1: NSPoint(x: start.0 + 2 / 3 * (control.0 - start.0), y: start.1 + 2 / 3 * (control.1 - start.1)),
            controlPoint2: NSPoint(x: end.0 + 2 / 3 * (control.0 - end.0), y: end.1 + 2 / 3 * (control.1 - end.1))
        )
        return path
    }

    /// Fills and cut-outs against one context. `state` is the aspect's
    /// colour (the label colour when dark, so an asleep pet matches the
    /// icons around it).
    private struct Pen {
        let context: CGContext
        let state: NSColor

        func fill(_ path: NSBezierPath, _ color: NSColor) {
            color.setFill()
            path.fill()
        }

        private func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }

        /// Erase through whatever the pet has drawn so far.
        func cut(_ path: NSBezierPath) {
            context.saveGState()
            context.setBlendMode(.destinationOut)
            fill(path, .black)
            context.restoreGState()
        }

        func cutStroke(_ path: NSBezierPath, width: CGFloat) {
            context.saveGState()
            context.setBlendMode(.destinationOut)
            stroke(path, .black, width: width)
            context.restoreGState()
        }

        func scaled(_ factor: CGFloat, around pivot: NSPoint, _ body: () -> Void) {
            context.saveGState()
            context.translateBy(x: pivot.x, y: pivot.y)
            context.scaleBy(x: factor, y: factor)
            context.translateBy(x: -pivot.x, y: -pivot.y)
            body()
            context.restoreGState()
        }
    }
}
