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

    /// How long you've been talking, in the pet's opinion. It starts out
    /// happy to be yapping, loses the sparkle at two minutes, and at four is
    /// full: puffed up, eyes flat. The railway glyphs have no equivalent; the
    /// clock says it.
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
            stage: stage(forSpeakingSeconds: speakingSeconds)
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
            draw(glyph, aspect: aspect, palette: palette, stage: .fresh, atX: horizontalPadding)
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
        stage: TurnStage
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
            draw(glyph, aspect: aspect, palette: palette, stage: stage, atX: horizontalPadding)
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

        /// Whether the floor is yours. The bubble pets turn their tail to
        /// your side (the right, as in any chat app) from the moment it is,
        /// so the flip itself is the "go" cue.
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

    private static func draw(_ glyph: GlyphStyle, aspect: Aspect, palette: LampPalette, stage: TurnStage, atX x: CGFloat) {
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
            listener: .secondaryLabelColor
        )
        let phase = phase(of: aspect)
        switch glyph {
        case .lamp: drawLamp(pen, phase)
        case .petClassic: drawPetClassic(pen, phase, stage: stage)
        case .petMouth: drawPetMouth(pen, phase, stage: stage)
        case .petHollowSolid: drawPetHollowSolid(pen, phase, stage: stage)
        case .petPair: drawPetPair(pen, phase, stage: stage)
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
            pen.stroke(disc, pen.state, width: 1.2)
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

    private static func drawPetClassic(_ pen: Pen, _ phase: Phase, stage: TurnStage) {
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

    private static func drawPetMouth(_ pen: Pen, _ phase: Phase, stage: TurnStage) {
        pen.fill(bubbleBody(yours: phase.isYours), pen.state)
        switch phase {
        case .dark:
            pen.cutStroke(line(6.4, 7.9, 10.4, 7.9), width: 1.3)
        case .them:
            // Zipped.
            pen.cutStroke(lines([
                (4.7, 7.9, 12.1, 7.9), (6.4, 6.7, 6.4, 9.1), (8.4, 6.7, 8.4, 9.1), (10.4, 6.7, 10.4, 9.1),
            ]), width: 1.25)
        case .pause:
            pen.cut(circle(8.4, 7.9, 1.5))
        case .clear:
            pen.cutStroke(curve(from: (4.8, 6.3), via: (8.4, 11.1), to: (12, 6.3)), width: 1.5)
        case .you:
            switch stage {
            case .fresh, .tiring: pen.cut(bowl(x: 4.6, y: 5.9, width: 7.6, depth: 4.4))
            case .full: pen.cut(bowl(x: 4.0, y: 5.2, width: 8.8, depth: 5.4))
            }
        }
    }

    private static func drawPetHollowSolid(_ pen: Pen, _ phase: Phase, stage: TurnStage) {
        let body = petBody(yours: phase.isYours)
        switch phase {
        case .dark:
            pen.stroke(body, pen.state, width: 1.3)
            pen.stroke(sleepEyes(), pen.state, width: 1.2)
        case .them:
            pen.stroke(body, pen.state, width: 1.5)
            pen.fill(eyes(6.2, 10.6), pen.state)
            pen.stroke(lines([
                (6.2, 10.6, 10.6, 10.6), (7.6, 9.7, 7.6, 11.5), (9.2, 9.7, 9.2, 11.5),
            ]), pen.state, width: 1.2)
        case .pause:
            pen.stroke(body, pen.state, width: 1.5)
            pen.fill(eyes(6.2, 10.6), pen.state)
            pen.fill(circle(8.4, 10.6, 1.1), pen.state)
        case .clear:
            pen.fill(body, pen.state)
            pen.cut(eyes(6.2, 10.6))
            pen.cutStroke(petSmile(), width: 1.4)
        case .you:
            pen.fill(body, pen.state)
            yappingFace(pen, body: body, stage: stage)
        }
    }

    private enum PairFace {
        case sleep, listen, pause, smile, talk, shout
    }

    private static func drawPetPair(_ pen: Pen, _ phase: Phase, stage: TurnStage) {
        let them: CGFloat = 6.2
        let you: CGFloat = 20.8
        switch phase {
        case .dark:
            pairBlob(pen, at: them, face: .sleep, color: pen.state)
            pairBlob(pen, at: you, face: .sleep, color: pen.state)
        case .them:
            pairBlob(pen, at: them, face: .talk, color: pen.state)
            pairBlob(pen, at: you, face: .listen, color: pen.listener)
        case .pause:
            pairBlob(pen, at: them, face: .pause, color: pen.state)
            pairBlob(pen, at: you, face: .listen, color: pen.listener)
        case .clear:
            pairBlob(pen, at: them, face: .listen, color: pen.listener)
            pairBlob(pen, at: you, face: .smile, color: pen.state)
        case .you:
            pairBlob(pen, at: them, face: .listen, color: pen.listener)
            pairBlob(pen, at: you, face: stage == .full ? .shout : .talk, color: pen.state)
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
        pen.fill(box(2, 1, 2.2, 15, radius: 0.7), pen.ink)
        pen.rotated(angle, around: pivot) {
            pen.fill(box(3.1, 1.7, 12.4, 3.2, radius: 1.1), pen.state)
            if phase != .dark {
                pen.cut(box(11.4, 1.7, 1.7, 3.2))
            }
        }
        pen.cut(circle(pivot.x, pivot.y, 1))
    }

    /// Position is the message, left to right; the live lamp is the big one.
    private static func drawWideHead(_ pen: Pen, _ phase: Phase) {
        let frame = pen.ink
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
        pen.fill(box(0.5, 11.6, 4, 4.4, radius: 1), pen.ink)
        pen.rotated(-angle, around: NSPoint(x: 2.5, y: 13.1)) {
            pen.fill(box(2.5, 11.6, 13, 3, radius: 1.3), pen.state)
            if phase != .dark {
                for x in [6.0, 9.6, 13.2] {
                    pen.cut(box(CGFloat(x), 11.6, 1.6, 3))
                }
            }
        }
    }

    // MARK: - Shared shapes

    /// Where the pets' bodies are centred; the long-turn puff scales about it.
    private static let petCentre = NSPoint(x: 8.4, y: 8)

    /// Round one's blob, with the tail moved from straight down to the lower
    /// left corner at 45°. Straight down it took a quarter of the box and left
    /// the body at 11 units; on the corner it costs almost no height and the
    /// body fills 13. The tail is on their side (left) until the floor is
    /// yours, then on yours (right), as chat bubbles are.
    private static func petBody(yours: Bool = false) -> NSBezierPath {
        let path = NSBezierPath()
        // The long way round from the tail's near edge to its far edge, then
        // out to the tip and back.
        path.appendArc(withCenter: petCentre, radius: 6.5, startAngle: 120, endAngle: 150, clockwise: true)
        path.line(to: NSPoint(x: 1.2, y: 15.2))
        path.close()
        return yours ? mirrored(path) : path
    }

    /// Round two's bubble: flat top, and the same corner tail, so it reads as
    /// "talk" before it reads as "creature".
    private static func bubbleBody(yours: Bool = false) -> NSBezierPath {
        let path = NSBezierPath()
        let radius: CGFloat = 1.8
        path.move(to: NSPoint(x: 5.4, y: 13.6))
        path.line(to: NSPoint(x: 0.6, y: 15.9))
        path.line(to: NSPoint(x: 1.2, y: 12.2))
        path.appendArc(from: NSPoint(x: 1.2, y: 1.5), to: NSPoint(x: 15.6, y: 1.5), radius: radius)
        path.appendArc(from: NSPoint(x: 15.6, y: 1.5), to: NSPoint(x: 15.6, y: 13.6), radius: radius)
        path.appendArc(from: NSPoint(x: 15.6, y: 13.6), to: NSPoint(x: 5.4, y: 13.6), radius: radius)
        path.close()
        return yours ? mirrored(path) : path
    }

    /// Flipped left-to-right about the pets' centre line, so the body stays
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
    /// aspect's colour (the label colour when dark, so an idle glyph matches
    /// the icons around it); `ink` is for posts and housings; `listener` is
    /// the one who isn't talking in the two-pet glyph.
    private struct Pen {
        let context: CGContext
        let state: NSColor
        let ink: NSColor
        let listener: NSColor

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
