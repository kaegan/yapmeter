import AppKit

/// Renders the menu bar status image: one glyph in the aspect's colour, plus
/// your turn's elapsed time when you're the one talking. This is the app's
/// entire display; the menu behind it holds settings only.
///
/// Every glyph is drawn in the sketches' own 16-unit, y-down coordinates and
/// scaled into a 20pt box inside the 22pt image, so the drawings translate
/// across unchanged and still sit at the size of the icons around them (a
/// 16pt box left the pets' bodies at 11pt, once the tail had its share).
/// Eyes, mouths and stripes are cut out of the glyph rather than painted in a
/// background colour, because the menu bar has no fixed background to match.
///
/// `MenuBarExtra` tends to force template (monochrome) rendering on
/// SwiftUI-provided label content, so we draw and cache real `NSImage`s with
/// `isTemplate = false` ourselves.
@MainActor
enum SignalHeadRenderer {
    private struct CacheKey: Hashable {
        let aspect: Aspect
        let glyph: GlyphStyle
        let palette: LampPalette
    }

    private static var cache: [CacheKey: NSImage] = [:]

    /// The menu bar is 24pt; this leaves a point above and below.
    static let imageHeight: CGFloat = 22
    private static let glyphHeight: CGFloat = 20
    /// The sketches are drawn in a 16-unit box.
    private static let sketchUnits: CGFloat = 16
    private static let glyphScale = glyphHeight / sketchUnits
    private static let horizontalPadding: CGFloat = 2
    private static let glyphTextGap: CGFloat = 5

    /// A turn this long gets the pets' "full" drawing: puffed up, or mouth
    /// wide open. The railway glyphs have no equivalent; the clock says it.
    static let longTurnSeconds = 240

    static func menuBarImage(
        for aspect: Aspect,
        speakingSeconds: Int?,
        glyph: GlyphStyle = .lamp,
        palette: LampPalette = .system
    ) -> NSImage {
        guard let speakingSeconds else {
            return glyphOnlyImage(for: aspect, glyph: glyph, palette: palette)
        }
        return glyphWithTimeImage(
            for: aspect,
            glyph: glyph,
            palette: palette,
            label: timeLabel(speakingSeconds),
            longTurn: speakingSeconds >= longTurnSeconds
        )
    }

    /// mm:ss, no hours: a turn long enough to need them has bigger problems.
    static func timeLabel(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// How wide each glyph's box is, in points. Heights are all `glyphHeight`.
    static func width(of glyph: GlyphStyle) -> CGFloat {
        let units: CGFloat
        switch glyph {
        case .lamp, .petClassic, .petMouth, .petHollowSolid: units = 16
        case .semaphoreArm: units = 17
        case .crossingBarrier: units = 18
        case .wideHead: units = 26
        case .petPair: units = 27
        }
        return ceil(units * glyphScale)
    }

    // MARK: - Images

    private static func glyphOnlyImage(for aspect: Aspect, glyph: GlyphStyle, palette: LampPalette) -> NSImage {
        let key = CacheKey(aspect: aspect, glyph: glyph, palette: palette)
        if let cached = cache[key] { return cached }
        let width = horizontalPadding * 2 + width(of: glyph)
        let image = NSImage(size: NSSize(width: width, height: imageHeight), flipped: true) { _ in
            draw(glyph, aspect: aspect, palette: palette, longTurn: false, atX: horizontalPadding)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = aspect.displayName
        cache[key] = image
        return image
    }

    /// Not cached: the label changes every second, and caching per-label would
    /// grow a dictionary entry per second of every meeting.
    private static func glyphWithTimeImage(
        for aspect: Aspect,
        glyph: GlyphStyle,
        palette: LampPalette,
        label: String,
        longTurn: Bool
    ) -> NSImage {
        // Label colour at the menu bar's own size, so the timer sits like the
        // clock's text does. The glyph beside it already says "you".
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let textSize = text.size()
        let glyphWidth = width(of: glyph)
        let width = horizontalPadding * 2 + glyphWidth + glyphTextGap + ceil(textSize.width)

        let image = NSImage(size: NSSize(width: width, height: imageHeight), flipped: true) { rect in
            draw(glyph, aspect: aspect, palette: palette, longTurn: longTurn, atX: horizontalPadding)
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

    /// The aspects collapse to five drawings: the two yellows look the same.
    private enum Phase {
        case dark, them, pause, clear, you
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

    private static func draw(_ glyph: GlyphStyle, aspect: Aspect, palette: LampPalette, longTurn: Bool, atX x: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // A transparency layer so the cut-outs erase the glyph only, not
        // whatever the menu bar has behind it.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: x, y: (imageHeight - glyphHeight) / 2)
        context.scaleBy(x: glyphScale, y: glyphScale)
        let pen = Pen(
            context: context,
            state: palette.color(for: aspect),
            ink: .labelColor,
            dim: .secondaryLabelColor
        )
        let phase = phase(of: aspect)
        switch glyph {
        case .lamp: drawLamp(pen, phase)
        case .petClassic: drawPetClassic(pen, phase, longTurn: longTurn)
        case .petMouth: drawPetMouth(pen, phase, longTurn: longTurn)
        case .petHollowSolid: drawPetHollowSolid(pen, phase, longTurn: longTurn)
        case .petPair: drawPetPair(pen, phase, longTurn: longTurn)
        case .semaphoreArm: drawSemaphoreArm(pen, phase)
        case .wideHead: drawWideHead(pen, phase)
        case .crossingBarrier: drawCrossingBarrier(pen, phase)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A lit lamp is a filled disc with a soft glow behind it. A dark signal
    /// draws as an outline only, so the status item still has something to
    /// look at and to click when no meeting is running.
    private static func drawLamp(_ pen: Pen, _ phase: Phase) {
        let disc = circle(8, 8, 5.5)
        guard phase != .dark else {
            pen.stroke(disc, pen.dim, width: 1.2)
            return
        }
        if let glow = NSGradient(
            starting: pen.state.withAlphaComponent(0.55),
            ending: pen.state.withAlphaComponent(0.0)
        ) {
            glow.draw(in: circle(8, 8, 8.5), relativeCenterPosition: .zero)
        }
        pen.fill(disc, pen.state)
    }

    private static func drawPetClassic(_ pen: Pen, _ phase: Phase, longTurn: Bool) {
        switch phase {
        case .dark:
            pen.fill(petBody(), pen.dim)
            pen.cutStroke(sleepEyes(), width: 1.2)
        case .them:
            pen.fill(petBody(), pen.state)
            pen.cut(eyes(5.8, 10.2))
            // A hand over the mouth.
            pen.cut(box(5.9, 8.8, 4.2, 1.7, radius: 0.85))
        case .pause:
            pen.fill(petBody(), pen.state)
            pen.cut(eyes(6.3, 10.7))
            pen.cutStroke(line(6.3, 9.6, 9.7, 9.6), width: 1.2)
        case .clear:
            pen.fill(petBody(), pen.state)
            pen.cut(eyes(5.8, 10.2))
            pen.cutStroke(petSmile(), width: 1.4)
        case .you where longTurn:
            pen.scaled(1.14, around: NSPoint(x: 8, y: 7.6)) {
                pen.fill(petBody(), pen.state)
                pen.cutStroke(sleepEyes(), width: 1.2)
                pen.cutStroke(line(6, 9.8, 10, 9.8), width: 1.4)
            }
        case .you:
            pen.fill(petBody(), pen.state)
            pen.cut(eyes(5.8, 10.2))
            pen.cut(oval(8, 9.8, 2.3, 2.0))
        }
    }

    private static func drawPetMouth(_ pen: Pen, _ phase: Phase, longTurn: Bool) {
        pen.fill(bubbleBody(), phase == .dark ? pen.dim : pen.state)
        switch phase {
        case .dark:
            pen.cutStroke(line(6, 7.2, 10, 7.2), width: 1.3)
        case .them:
            // Zipped.
            pen.cutStroke(lines([
                (4.3, 7.2, 11.7, 7.2), (6, 6, 6, 8.4), (8, 6, 8, 8.4), (10, 6, 10, 8.4),
            ]), width: 1.25)
        case .pause:
            pen.cut(circle(8, 7.2, 1.5))
        case .clear:
            pen.cutStroke(curve(from: (4.4, 5.6), via: (8, 10.4), to: (11.6, 5.6)), width: 1.5)
        case .you where longTurn:
            pen.cut(oval(8, 7, 4.6, 3.7))
        case .you:
            pen.cut(oval(8, 7, 3.4, 2.8))
        }
    }

    private static func drawPetHollowSolid(_ pen: Pen, _ phase: Phase, longTurn: Bool) {
        switch phase {
        case .dark:
            pen.stroke(petBody(), pen.dim, width: 1.3)
            pen.stroke(sleepEyes(), pen.dim, width: 1.2)
        case .them:
            pen.stroke(petBody(), pen.state, width: 1.5)
            pen.fill(eyes(5.8, 10.2), pen.state)
            pen.stroke(lines([
                (5.8, 9.6, 10.2, 9.6), (7.2, 8.7, 7.2, 10.5), (8.8, 8.7, 8.8, 10.5),
            ]), pen.state, width: 1.2)
        case .pause:
            pen.stroke(petBody(), pen.state, width: 1.5)
            pen.fill(eyes(5.8, 10.2), pen.state)
            pen.fill(circle(8, 9.6, 1.1), pen.state)
        case .clear:
            pen.fill(petBody(), pen.state)
            pen.cut(eyes(5.8, 10.2))
            pen.cutStroke(petSmile(), width: 1.4)
        case .you where longTurn:
            pen.scaled(1.14, around: NSPoint(x: 8, y: 7.6)) {
                pen.fill(petBody(), pen.state)
                pen.cutStroke(sleepEyes(), width: 1.2)
                pen.cutStroke(line(6, 9.8, 10, 9.8), width: 1.4)
            }
        case .you:
            pen.fill(petBody(), pen.state)
            pen.cut(eyes(5.8, 10.2))
            pen.cut(oval(8, 9.8, 2.3, 2.0))
        }
    }

    private enum PairFace {
        case sleep, listen, pause, smile, talk, shout
    }

    private static func drawPetPair(_ pen: Pen, _ phase: Phase, longTurn: Bool) {
        let them: CGFloat = 6.2
        let you: CGFloat = 20.8
        switch phase {
        case .dark:
            pairBlob(pen, at: them, face: .sleep, color: pen.dim)
            pairBlob(pen, at: you, face: .sleep, color: pen.dim)
        case .them:
            pairBlob(pen, at: them, face: .talk, color: pen.state)
            pairBlob(pen, at: you, face: .listen, color: pen.dim)
        case .pause:
            pairBlob(pen, at: them, face: .pause, color: pen.state)
            pairBlob(pen, at: you, face: .listen, color: pen.dim)
        case .clear:
            pairBlob(pen, at: them, face: .listen, color: pen.dim)
            pairBlob(pen, at: you, face: .smile, color: pen.state)
        case .you:
            pairBlob(pen, at: them, face: .listen, color: pen.dim)
            pairBlob(pen, at: you, face: longTurn ? .shout : .talk, color: pen.state)
        }
    }

    private static func pairBlob(_ pen: Pen, at cx: CGFloat, face: PairFace, color: NSColor) {
        // The tail points outward: theirs to the left, yours to the right.
        let side: CGFloat = cx < 13 ? -1 : 1
        pen.fill(circle(cx, 7.4, 5.6), color)
        pen.fill(polygon([
            (cx + side * 1.4, 12.4), (cx + side * 3.8, 15.4), (cx + side * 3.6, 12),
        ]), color)
        switch face {
        case .sleep:
            let arcs = NSBezierPath()
            arcs.append(curve(from: (cx - 3, 6.4), via: (cx - 2, 7.4), to: (cx - 1, 6.4)))
            arcs.append(curve(from: (cx + 1, 6.4), via: (cx + 2, 7.4), to: (cx + 3, 6.4)))
            pen.cutStroke(arcs, width: 1.1)
            return
        case .listen:
            pen.cutStroke(line(cx - 1.7, 9.5, cx + 1.7, 9.5), width: 1.2)
        case .pause:
            pen.cut(circle(cx, 9.5, 0.95))
        case .smile:
            pen.cutStroke(curve(from: (cx - 2, 9), via: (cx, 11.2), to: (cx + 2, 9)), width: 1.2)
        case .talk:
            pen.cut(oval(cx, 9.7, 1.9, 1.6))
        case .shout:
            pen.cut(oval(cx, 9.9, 2.5, 2.1))
        }
        pen.cut(eyes(cx - 2.1, cx + 2.1, y: 6.4, radius: 0.95))
    }

    /// Horizontal is danger, dropped is clear, as on the real thing. The arm
    /// keeps the white band a real arm has near its tip.
    private static func drawSemaphoreArm(_ pen: Pen, _ phase: Phase) {
        let angle: CGFloat
        switch phase {
        case .dark, .them: angle = 0
        case .pause: angle = 35
        case .clear, .you: angle = 70
        }
        let pivot = NSPoint(x: 3.1, y: 3.3)
        pen.fill(box(2, 1, 2.2, 15, radius: 0.7), phase == .dark ? pen.dim : pen.ink)
        pen.rotated(angle, around: pivot) {
            pen.fill(box(3.1, 1.7, 12.4, 3.2, radius: 1.1), phase == .dark ? pen.dim : pen.state)
            if phase != .dark {
                pen.cut(box(11.4, 1.7, 1.7, 3.2))
            }
        }
        pen.cut(circle(pivot.x, pivot.y, 1))
    }

    /// Position is the message, left to right; the live lamp is the big one.
    private static func drawWideHead(_ pen: Pen, _ phase: Phase) {
        let frame = phase == .dark ? pen.dim : pen.ink
        pen.stroke(box(0.8, 2.3, 24.4, 11.4, radius: 5.7), frame, width: 1.2)
        let live: Int?
        switch phase {
        case .dark: live = nil
        case .them: live = 0
        case .pause: live = 1
        case .clear, .you: live = 2
        }
        for (index, x) in [6.5, 13, 19.5].enumerated() {
            if index == live {
                pen.fill(circle(CGFloat(x), 8, 4.1), pen.state)
            } else {
                pen.fill(circle(CGFloat(x), 8, 1.4), frame.withAlphaComponent(0.55))
            }
        }
    }

    /// Down is stop, up is clear, and the stripes survive with the colour
    /// taken away.
    private static func drawCrossingBarrier(_ pen: Pen, _ phase: Phase) {
        let angle: CGFloat
        switch phase {
        case .dark, .them: angle = 0
        case .pause: angle = 40
        case .clear, .you: angle = 82
        }
        pen.fill(box(0.5, 11.6, 4, 4.4, radius: 1), phase == .dark ? pen.dim : pen.ink)
        pen.rotated(-angle, around: NSPoint(x: 2.5, y: 13.1)) {
            pen.fill(box(2.5, 11.6, 13, 3, radius: 1.3), phase == .dark ? pen.dim : pen.state)
            if phase != .dark {
                for x in [6.0, 9.6, 13.2] {
                    pen.cut(box(CGFloat(x), 11.6, 1.6, 3))
                }
            }
        }
    }

    // MARK: - Shared shapes

    /// Round one's blob: a speech bubble whose tail is its foot.
    private static func petBody() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1.5, y: 7))
        path.curve(to: NSPoint(x: 8, y: 1.5), controlPoint1: NSPoint(x: 1.5, y: 3.4), controlPoint2: NSPoint(x: 4.3, y: 1.5))
        path.curve(to: NSPoint(x: 14.5, y: 7), controlPoint1: NSPoint(x: 11.7, y: 1.5), controlPoint2: NSPoint(x: 14.5, y: 3.4))
        path.curve(to: NSPoint(x: 9.7, y: 12.4), controlPoint1: NSPoint(x: 14.5, y: 10.1), controlPoint2: NSPoint(x: 12.4, y: 12.1))
        path.line(to: NSPoint(x: 8.2, y: 15.2))
        path.line(to: NSPoint(x: 7.1, y: 12.4))
        path.curve(to: NSPoint(x: 1.5, y: 7), controlPoint1: NSPoint(x: 4.1, y: 12.1), controlPoint2: NSPoint(x: 1.5, y: 10.1))
        path.close()
        return path
    }

    /// Round two's bubble: flat top, hard tail, so it reads as "talk" before
    /// it reads as "creature".
    private static func bubbleBody() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 2.6, y: 1.5))
        path.line(to: NSPoint(x: 13.4, y: 1.5))
        path.curve(to: NSPoint(x: 15.2, y: 3.3), controlPoint1: NSPoint(x: 14.6, y: 1.5), controlPoint2: NSPoint(x: 15.2, y: 2.1))
        path.line(to: NSPoint(x: 15.2, y: 10.4))
        path.curve(to: NSPoint(x: 13.4, y: 12.2), controlPoint1: NSPoint(x: 15.2, y: 11.6), controlPoint2: NSPoint(x: 14.6, y: 12.2))
        path.line(to: NSPoint(x: 8.6, y: 12.2))
        path.line(to: NSPoint(x: 6.2, y: 15.3))
        path.line(to: NSPoint(x: 6.5, y: 12.2))
        path.line(to: NSPoint(x: 2.6, y: 12.2))
        path.curve(to: NSPoint(x: 0.8, y: 10.4), controlPoint1: NSPoint(x: 1.4, y: 12.2), controlPoint2: NSPoint(x: 0.8, y: 11.6))
        path.line(to: NSPoint(x: 0.8, y: 3.3))
        path.curve(to: NSPoint(x: 2.6, y: 1.5), controlPoint1: NSPoint(x: 0.8, y: 2.1), controlPoint2: NSPoint(x: 1.4, y: 1.5))
        path.close()
        return path
    }

    private static func eyes(_ left: CGFloat, _ right: CGFloat, y: CGFloat = 6.3, radius: CGFloat = 1.05) -> NSBezierPath {
        let path = circle(left, y, radius)
        path.append(circle(right, y, radius))
        return path
    }

    private static func sleepEyes() -> NSBezierPath {
        let path = curve(from: (4.6, 6.4), via: (5.9, 7.7), to: (7.2, 6.4))
        path.append(curve(from: (8.8, 6.4), via: (10.1, 7.7), to: (11.4, 6.4)))
        return path
    }

    private static func petSmile() -> NSBezierPath {
        curve(from: (5.5, 8.9), via: (8, 11.6), to: (10.5, 8.9))
    }

    // MARK: - Primitives, in the glyph's y-down coordinates

    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    private static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
        oval(cx, cy, r, r)
    }

    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
    }

    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> NSBezierPath {
        lines([(x1, y1, x2, y2)])
    }

    private static func lines(_ segments: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        for (x1, y1, x2, y2) in segments {
            path.move(to: NSPoint(x: x1, y: y1))
            path.line(to: NSPoint(x: x2, y: y2))
        }
        return path
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let p = NSPoint(x: point.0, y: point.1)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path
    }

    /// A quadratic curve, as the sketches use, lifted to the cubic AppKit draws.
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

    /// Fills, strokes and cut-outs against one context. `state` is the
    /// aspect's colour; `ink` is for posts and housings; `dim` is asleep,
    /// out of service, or the one who's listening.
    private struct Pen {
        let context: CGContext
        let state: NSColor
        let ink: NSColor
        let dim: NSColor

        func fill(_ path: NSBezierPath, _ color: NSColor) {
            color.setFill()
            path.fill()
        }

        func stroke(_ path: NSBezierPath, _ color: NSColor, width: CGFloat) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }

        /// Erase through whatever the glyph has drawn so far.
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

        /// Positive degrees turn clockwise on screen, as in the sketches.
        func rotated(_ degrees: CGFloat, around pivot: NSPoint, _ body: () -> Void) {
            context.saveGState()
            context.translateBy(x: pivot.x, y: pivot.y)
            context.rotate(by: degrees * .pi / 180)
            context.translateBy(x: -pivot.x, y: -pivot.y)
            body()
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
