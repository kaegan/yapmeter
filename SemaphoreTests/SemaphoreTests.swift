import XCTest
@testable import Semaphore

final class AspectTests: XCTestCase {
    func testAspectHasSixStates() {
        XCTAssertEqual(Aspect.allCases.count, 6)
    }

    func testAspectDisplayNamesAreNonEmpty() {
        for aspect in Aspect.allCases {
            XCTAssertFalse(aspect.displayName.isEmpty)
        }
    }
}

final class VoiceActivityDetectorTests: XCTestCase {
    /// The menu lists these top to bottom, so the order is part of the UI.
    func testSensitivityIsOrderedLowToHigh() {
        XCTAssertEqual(VoiceActivityDetector.Sensitivity.allCases, [.low, .normal, .high])
    }

    /// Feed a constant level for a duration at the app's real tick rate.
    private func feed(
        _ detector: inout VoiceActivityDetector,
        dBFS: Float,
        seconds: TimeInterval,
        from start: Date
    ) -> Date {
        let step = 1.0 / 50.0
        var now = start
        let end = start.addingTimeInterval(seconds)
        while now < end {
            now = now.addingTimeInterval(step)
            detector.update(dBFS: dBFS, now: now)
        }
        return now
    }

    func testSteadyRoomNoiseIsNotSpeech() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        // A fan at a constant -45 dBFS: loud in absolute terms, but the noise
        // floor rises to meet it, so it never clears the margin.
        let end = feed(&detector, dBFS: -45, seconds: 30, from: start)
        XCTAssertFalse(detector.isSpeaking)
        XCTAssertEqual(end.timeIntervalSince(start), 30, accuracy: 0.1)
    }

    func testSpeechOverRoomNoiseIsDetected() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        XCTAssertFalse(detector.isSpeaking)
        now = feed(&detector, dBFS: -25, seconds: 1, from: now)
        XCTAssertTrue(detector.isSpeaking)
    }

    func testImpulseShorterThanOnsetIsRejected() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        // A keyboard click: loud, but gone well inside the 150ms onset window.
        now = feed(&detector, dBFS: -20, seconds: 0.06, from: now)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testHangoverBridgesGapsBetweenWords() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        now = feed(&detector, dBFS: -25, seconds: 1, from: now)
        XCTAssertTrue(detector.isSpeaking)
        // A short inter-word gap should not end the turn...
        now = feed(&detector, dBFS: -60, seconds: 0.3, from: now)
        XCTAssertTrue(detector.isSpeaking)
        // ...but a real stop should.
        now = feed(&detector, dBFS: -60, seconds: 1.0, from: now)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testLowSensitivityNeedsAWiderMargin() {
        let start = Date(timeIntervalSince1970: 0)
        var high = VoiceActivityDetector(sensitivity: .high)
        var low = VoiceActivityDetector(sensitivity: .low)
        // 14 dB over a -60 floor: clears .high's 8 dB, misses .low's 18 dB.
        var now = feed(&high, dBFS: -60, seconds: 5, from: start)
        _ = feed(&high, dBFS: -46, seconds: 1, from: now)
        now = feed(&low, dBFS: -60, seconds: 5, from: start)
        _ = feed(&low, dBFS: -46, seconds: 1, from: now)
        XCTAssertTrue(high.isSpeaking)
        XCTAssertFalse(low.isSpeaking)
    }

    func testAbsoluteGateRejectsQuietHumInASilentRoom() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        // Floor bottoms out at -75; a -55 dBFS hum is 20 dB above it but still
        // below the absolute gate, so it must not read as speech.
        let now = feed(&detector, dBFS: -90, seconds: 10, from: start)
        _ = feed(&detector, dBFS: -55, seconds: 2, from: now)
        XCTAssertFalse(detector.isSpeaking)
    }
}

final class SignalStateMachineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    func testNoMeetingIsAlwaysDark() {
        var machine = SignalStateMachine()
        let aspect = machine.aspect(meetingActive: false, nearSpeaking: true, farSpeaking: true, now: start)
        XCTAssertEqual(aspect, .dark)
    }

    func testFarEndSpeakingOccupiesTheBlock() {
        var machine = SignalStateMachine()
        let aspect = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: true, now: start)
        XCTAssertEqual(aspect, .occupied)
    }

    func testYourOwnSpeechOutranksTheBlockState() {
        var machine = SignalStateMachine()
        let aspect = machine.aspect(meetingActive: true, nearSpeaking: true, farSpeaking: true, now: start)
        XCTAssertEqual(aspect, .speaking)
    }

    func testBlockClearsThroughCautionAndPreliminary() {
        var machine = SignalStateMachine()
        machine.dwell = 1.2
        _ = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: true, now: start)

        func aspectAfter(_ seconds: TimeInterval) -> Aspect {
            machine.aspect(
                meetingActive: true,
                nearSpeaking: false,
                farSpeaking: false,
                now: start.addingTimeInterval(seconds)
            )
        }

        XCTAssertEqual(aspectAfter(0.1), .caution)
        XCTAssertEqual(aspectAfter(0.7), .preliminary)
        XCTAssertEqual(aspectAfter(1.5), .clear)
    }

    func testFarEndResumingResetsTheDwell() {
        var machine = SignalStateMachine()
        machine.dwell = 1.2
        _ = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: true, now: start)
        _ = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: false, now: start.addingTimeInterval(1.0))
        _ = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: true, now: start.addingTimeInterval(1.1))
        let aspect = machine.aspect(
            meetingActive: true, nearSpeaking: false, farSpeaking: false, now: start.addingTimeInterval(1.2)
        )
        XCTAssertEqual(aspect, .caution)
    }
}

@MainActor
final class MeetingDetectionTests: XCTestCase {
    private func process(output: Bool, input: Bool) -> MeetingProcessMonitor.MatchedProcess {
        MeetingProcessMonitor.MatchedProcess(
            id: 1, pid: 100, bundleID: "us.zoom.xos", isRunningOutput: output, isRunningInput: input
        )
    }

    func testNoProcessesIsNoMeeting() {
        XCTAssertFalse(AudioMonitor.isLiveMeeting([]))
    }

    func testMicrophoneOpenMeansLiveMeeting() {
        XCTAssertTrue(AudioMonitor.isLiveMeeting([process(output: false, input: true)]))
    }

    func testOutputOnlyStillCountsAsFallback() {
        // A Zoom lobby: audio playing, mic not yet open.
        XCTAssertTrue(AudioMonitor.isLiveMeeting([process(output: true, input: false)]))
    }

    func testIdleProcessIsNotAMeeting() {
        XCTAssertFalse(AudioMonitor.isLiveMeeting([process(output: false, input: false)]))
    }
}

final class MenuBarStyleTests: XCTestCase {
    /// The menu lists these top to bottom: the original lamp first, then the
    /// pets, then the railway, matching the brand boards they came from.
    func testGlyphsAreListedLampPetsThenRailway() {
        XCTAssertEqual(GlyphStyle.allCases, [
            .lamp, .petClassic, .petMouth, .petHollowSolid, .petPair,
            .semaphoreArm, .wideHead, .crossingBarrier,
        ])
    }

    func testEveryGlyphAndPaletteHasAName() {
        for glyph in GlyphStyle.allCases {
            XCTAssertFalse(glyph.displayName.isEmpty, "\(glyph)")
        }
        for palette in LampPalette.allCases {
            XCTAssertFalse(palette.displayName.isEmpty, "\(palette)")
        }
    }

    /// Every palette keeps the dark aspect as the label colour: an idle glyph
    /// should match the menu bar's other icons, not be a fifth colour.
    func testDarkAspectIsNeverAPaletteColour() {
        for palette in LampPalette.allCases {
            XCTAssertEqual(palette.color(for: .dark), .labelColor, "\(palette)")
        }
    }
}

@MainActor
final class AspectPreviewTests: XCTestCase {
    func testFramesCoverEveryAspectAndALongTurn() {
        let aspects = Set(AspectPreview.frames.map(\.aspect))
        XCTAssertEqual(aspects, Set(Aspect.allCases))
        let longest = AspectPreview.frames.compactMap(\.speakingSeconds).max() ?? 0
        XCTAssertGreaterThanOrEqual(longest, SignalHeadRenderer.longTurnSeconds)
        // The clock is only ever shown while speaking.
        for frame in AspectPreview.frames where frame.speakingSeconds != nil {
            XCTAssertEqual(frame.aspect, .speaking)
        }
    }

    func testAdvanceWalksTheFramesAndWrapsAround() {
        let preview = AspectPreview()
        XCTAssertFalse(preview.isRunning)
        preview.start()
        XCTAssertTrue(preview.isRunning)
        XCTAssertEqual(preview.aspect, AspectPreview.frames[0].aspect)

        var seen: [Aspect] = []
        for _ in AspectPreview.frames {
            seen.append(preview.aspect)
            preview.advance()
        }
        XCTAssertEqual(seen, AspectPreview.frames.map(\.aspect))
        XCTAssertEqual(preview.aspect, AspectPreview.frames[0].aspect, "wraps to the start")
        preview.stop()
    }

    func testStopGoesDarkAndAdvanceIsThenANoOp() {
        let preview = AspectPreview()
        preview.start()
        for _ in 0..<6 { preview.advance() }
        XCTAssertNotEqual(preview.aspect, .dark)
        preview.stop()
        XCTAssertFalse(preview.isRunning)
        XCTAssertEqual(preview.aspect, .dark)
        XCTAssertNil(preview.speakingSeconds)
        preview.advance()
        XCTAssertEqual(preview.aspect, .dark)
    }

    func testIsOnMirrorsRunning() {
        let preview = AspectPreview()
        preview.isOn = true
        XCTAssertTrue(preview.isRunning)
        preview.isOn = false
        XCTAssertFalse(preview.isRunning)
    }
}

@MainActor
final class SignalHeadRendererTests: XCTestCase {
    func testTimeLabelFormatsAsMinutesAndSeconds() {
        XCTAssertEqual(SignalHeadRenderer.timeLabel(0), "0:00")
        XCTAssertEqual(SignalHeadRenderer.timeLabel(9), "0:09")
        XCTAssertEqual(SignalHeadRenderer.timeLabel(65), "1:05")
        XCTAssertEqual(SignalHeadRenderer.timeLabel(600), "10:00")
    }

    /// Every glyph, in every palette and aspect, draws something into the
    /// image. This runs the drawing code for real rather than trusting the
    /// handler to do it later.
    func testEveryGlyphDrawsInEveryAspectAndPalette() {
        for glyph in GlyphStyle.allCases {
            for palette in LampPalette.allCases {
                for aspect in Aspect.allCases {
                    let image = SignalHeadRenderer.menuBarImage(
                        for: aspect, speakingSeconds: nil, glyph: glyph, palette: palette
                    )
                    let label = "\(glyph) \(palette) \(aspect)"
                    XCTAssertEqual(image.size.height, SignalHeadRenderer.imageHeight, label)
                    XCTAssertEqual(image.size.width, SignalHeadRenderer.width(of: glyph) + 4, label)
                    XCTAssertTrue(paintsAnything(image), "\(label) drew nothing")
                }
            }
        }
    }

    func testTurnStagesTurnOverAtTwoAndFourMinutes() {
        XCTAssertEqual(SignalHeadRenderer.stage(forSpeakingSeconds: nil), .fresh)
        XCTAssertEqual(SignalHeadRenderer.stage(forSpeakingSeconds: 0), .fresh)
        XCTAssertEqual(SignalHeadRenderer.stage(forSpeakingSeconds: 119), .fresh)
        XCTAssertEqual(SignalHeadRenderer.stage(forSpeakingSeconds: 120), .tiring)
        XCTAssertEqual(SignalHeadRenderer.stage(forSpeakingSeconds: 239), .tiring)
        XCTAssertEqual(SignalHeadRenderer.stage(forSpeakingSeconds: 240), .full)
    }

    func testTimerWidensTheImageAndStillDraws() {
        for glyph in GlyphStyle.allCases {
            let silent = SignalHeadRenderer.menuBarImage(for: .speaking, speakingSeconds: nil, glyph: glyph)
            let talking = SignalHeadRenderer.menuBarImage(for: .speaking, speakingSeconds: 42, glyph: glyph)
            let tiring = SignalHeadRenderer.menuBarImage(
                for: .speaking, speakingSeconds: SignalHeadRenderer.tiringSeconds + 10, glyph: glyph
            )
            let longTurn = SignalHeadRenderer.menuBarImage(
                for: .speaking, speakingSeconds: SignalHeadRenderer.longTurnSeconds + 32, glyph: glyph
            )
            XCTAssertGreaterThan(talking.size.width, silent.size.width, "\(glyph)")
            XCTAssertTrue(paintsAnything(talking), "\(glyph) at 0:42 drew nothing")
            XCTAssertTrue(paintsAnything(tiring), "\(glyph) at two minutes drew nothing")
            XCTAssertTrue(paintsAnything(longTurn), "\(glyph) on a long turn drew nothing")
        }
    }

    /// The bubble pets keep the tail on the left while the floor is theirs
    /// and swing it to the right once it's yours, like chat bubbles do. Only
    /// the tail reaches the bottom rows of the image, so where the paint
    /// sits in those rows says which side it's on.
    func testBubblePetsTurnTheirTailToWhoeverHasTheFloor() {
        for glyph in [GlyphStyle.petClassic, .petMouth, .petHollowSolid] {
            for aspect in [Aspect.dark, .occupied, .caution, .preliminary] {
                let image = SignalHeadRenderer.menuBarImage(for: aspect, speakingSeconds: nil, glyph: glyph)
                XCTAssertLessThan(tailSide(of: image), 0.5, "\(glyph) \(aspect): tail should be on the left")
            }
            let clear = SignalHeadRenderer.menuBarImage(for: .clear, speakingSeconds: nil, glyph: glyph)
            XCTAssertGreaterThan(tailSide(of: clear), 0.5, "\(glyph) clear: tail should be on the right")
            let speaking = SignalHeadRenderer.menuBarImage(for: .speaking, speakingSeconds: 42, glyph: glyph)
            XCTAssertGreaterThan(tailSide(of: speaking), 0.5, "\(glyph) speaking: tail should be on the right")
        }
    }

    /// Where the paint in the image's bottom two rows sits, as a fraction of
    /// the glyph's width: 0 is the far left, 1 the far right.
    private func tailSide(of image: NSImage) -> CGFloat {
        let (rep, width, _) = render(image)
        guard let data = rep.bitmapData else { return 0.5 }
        // Bottom rows of a bitmap are the highest y; the glyph box is the
        // first 20pt of a wider image, so only look under it.
        let glyphWidth = min(width, Int(SignalHeadRenderer.width(of: .petClassic) + 4) * 2)
        var weighted: CGFloat = 0, total: CGFloat = 0
        for y in 2..<6 {
            let row = data + (Int(rep.pixelsHigh) - 1 - y) * rep.bytesPerRow
            for x in 0..<glyphWidth {
                let alpha = CGFloat(row[x * 4 + 3])
                weighted += alpha * CGFloat(x)
                total += alpha
            }
        }
        return total > 0 ? weighted / total / CGFloat(glyphWidth) : 0.5
    }

    /// Render at 2x, as the menu bar does, and look for any non-transparent
    /// pixel.
    private func paintsAnything(_ image: NSImage) -> Bool {
        let (rep, width, height) = render(image)
        guard let data = rep.bitmapData else { return false }
        for y in 0..<height {
            let row = data + y * rep.bytesPerRow
            for x in 0..<width where row[x * 4 + 3] > 0 {
                return true
            }
        }
        return false
    }

    private func render(_ image: NSImage) -> (NSBitmapImageRep, Int, Int) {
        let scale = 2
        let width = Int(ceil(image.size.width)) * scale
        let height = Int(ceil(image.size.height)) * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return (rep, width, height)
    }
}
