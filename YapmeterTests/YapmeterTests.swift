import XCTest
@testable import Yapmeter

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

    /// Alternate loud and quiet stretches, as speech-with-gaps or intermittent
    /// typing would look, for `count` repeats of (loud, quiet).
    private func feedBursts(
        _ detector: inout VoiceActivityDetector,
        loudDBFS: Float,
        quietDBFS: Float,
        loudSeconds: TimeInterval,
        quietSeconds: TimeInterval,
        count: Int,
        from start: Date
    ) -> Date {
        var now = start
        for _ in 0..<count {
            now = feed(&detector, dBFS: loudDBFS, seconds: loudSeconds, from: now)
            now = feed(&detector, dBFS: quietDBFS, seconds: quietSeconds, from: now)
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
        // A keyboard click: loud, but gone well inside the 600ms evidence
        // window needed to confirm speech.
        now = feed(&detector, dBFS: -20, seconds: 0.06, from: now)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testCoughIsRejected() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        // A cough: much longer than a keyboard click, but still well short of
        // the 600ms of accumulated evidence speech needs.
        now = feed(&detector, dBFS: -25, seconds: 0.4, from: now)
        XCTAssertFalse(detector.isSpeaking)
        XCTAssertNil(detector.speechStartedAt)
        _ = feed(&detector, dBFS: -60, seconds: 1, from: now)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testIntermittentTypingIsRejected() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        // A 50% duty cycle of clicks: evidence rises and decays by the same
        // amount each burst, so it never climbs to the onset threshold.
        now = feedBursts(
            &detector, loudDBFS: -25, quietDBFS: -60,
            loudSeconds: 0.1, quietSeconds: 0.1, count: 40, from: now
        )
        XCTAssertFalse(detector.isSpeaking)
    }

    func testSpeechWithInterWordGapsIsDetected() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        // A word/gap pattern that's mostly loud (0.4s on, 0.1s off - an 80%
        // duty cycle) should still accumulate to the onset threshold, just a
        // bit slower than continuous speech would.
        now = feedBursts(
            &detector, loudDBFS: -25, quietDBFS: -60,
            loudSeconds: 0.4, quietSeconds: 0.1, count: 4, from: now
        )
        XCTAssertTrue(detector.isSpeaking)
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

    func testSpeechStartIsBackDatedToFirstLoudSample() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        let quietEnd = feed(&detector, dBFS: -60, seconds: 5, from: start)
        _ = feed(&detector, dBFS: -25, seconds: 1, from: quietEnd)
        XCTAssertTrue(detector.isSpeaking)
        // The reported start is when the voice actually began, not the later
        // moment enough evidence had piled up to believe it.
        XCTAssertNotNil(detector.speechStartedAt)
        XCTAssertEqual(
            detector.speechStartedAt!.timeIntervalSince(quietEnd), 0, accuracy: 0.05
        )
    }

    func testAbandonedCandidateIsForgotten() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        // A cough starts a candidate, but it never confirms...
        now = feed(&detector, dBFS: -25, seconds: 0.3, from: now)
        // ...and the evidence decays back to zero during a real quiet stretch.
        now = feed(&detector, dBFS: -60, seconds: 1, from: now)
        // When speech actually starts, its back-dated start must be its own
        // onset, not the abandoned cough from a second earlier.
        let speechStart = now
        _ = feed(&detector, dBFS: -25, seconds: 1, from: now)
        XCTAssertTrue(detector.isSpeaking)
        XCTAssertEqual(
            detector.speechStartedAt!.timeIntervalSince(speechStart), 0, accuracy: 0.05
        )
    }

    func testSpeechStartClearsOnRelease() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        now = feed(&detector, dBFS: -25, seconds: 1, from: now)
        XCTAssertNotNil(detector.speechStartedAt)
        _ = feed(&detector, dBFS: -60, seconds: 1.0, from: now)
        XCTAssertFalse(detector.isSpeaking)
        XCTAssertNil(detector.speechStartedAt)
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

final class LevelAnalysisTests: XCTestCase {
    /// Builds a buffer of `sliceCount` 10ms-equivalent slices, each either
    /// loud or quiet, at a fixed slice length.
    private func buffer(sliceLength: Int, loudSlices: [Bool], loudAmplitude: Float = 0.3, quietAmplitude: Float = 0.001) -> [Float] {
        var samples: [Float] = []
        for loud in loudSlices {
            let amplitude = loud ? loudAmplitude : quietAmplitude
            samples.append(contentsOf: Array(repeating: amplitude, count: sliceLength))
        }
        return samples
    }

    func testClickInQuietBufferReadsAsQuiet() {
        // Two loud slices out of ten - a keystroke - should not move the
        // sustained level far from the quiet floor, even though the
        // whole-buffer RMS is dominated by the loud samples.
        let samples = buffer(sliceLength: 480, loudSlices: [true, true] + Array(repeating: false, count: 8))
        samples.withUnsafeBufferPointer { pointer in
            let sustained = LevelAnalysis.sustainedDBFS(pointer, sliceLength: 480)
            let whole = LevelAnalysis.rmsDBFS(pointer)
            XCTAssertLessThan(sustained, whole - 10)
            let quietOnly = Array(repeating: Float(0.001), count: 480)
            quietOnly.withUnsafeBufferPointer { quietPointer in
                XCTAssertEqual(sustained, LevelAnalysis.rmsDBFS(quietPointer), accuracy: 1)
            }
        }
    }

    func testSteadyToneReadsAsItsRMS() {
        let samples = Array(repeating: Float(0.1), count: 4800)
        samples.withUnsafeBufferPointer { pointer in
            let sustained = LevelAnalysis.sustainedDBFS(pointer, sliceLength: 480)
            let whole = LevelAnalysis.rmsDBFS(pointer)
            XCTAssertEqual(sustained, whole, accuracy: 0.5)
        }
    }

    func testSpeechLikeBufferWithGapsStillReadsLoud() {
        // Six loud slices, four quiet - the majority is loud, so the median
        // (upper, index 5 of 10) should land on a loud slice.
        let loudPattern = [true, false, true, true, false, true, true, false, true, false]
        let samples = buffer(sliceLength: 480, loudSlices: loudPattern)
        samples.withUnsafeBufferPointer { pointer in
            let sustained = LevelAnalysis.sustainedDBFS(pointer, sliceLength: 480)
            let loudOnly = Array(repeating: Float(0.3), count: 480)
            loudOnly.withUnsafeBufferPointer { loudPointer in
                XCTAssertEqual(sustained, LevelAnalysis.rmsDBFS(loudPointer), accuracy: 0.5)
            }
        }
    }

    func testShortBufferFallsBackToWholeBufferRMS() {
        // 1024 samples at a 480-sample slice length is only two slices, under
        // `minimumSlices`, so this must fall back to plain RMS.
        let samples = Array(repeating: Float(0.2), count: 1024)
        samples.withUnsafeBufferPointer { pointer in
            let sustained = LevelAnalysis.sustainedDBFS(pointer, sliceLength: 480)
            let whole = LevelAnalysis.rmsDBFS(pointer)
            XCTAssertEqual(sustained, whole, accuracy: 0.01)
        }
    }

    func testSilenceIsFloored() {
        let samples = Array(repeating: Float(0), count: 4800)
        samples.withUnsafeBufferPointer { pointer in
            let sustained = LevelAnalysis.sustainedDBFS(pointer, sliceLength: 480)
            XCTAssertLessThan(sustained, -100)
        }
    }
}

final class TurnClockTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    func testStartsFromBackDatedOnset() {
        var clock = TurnClock()
        // Speech is confirmed "now", but it actually began 0.5s earlier.
        let onset = start
        let confirmedAt = start.addingTimeInterval(0.5)
        let seconds = clock.update(speaking: true, speechStartedAt: onset, now: confirmedAt)
        XCTAssertEqual(seconds, 0)
        let later = clock.update(speaking: true, speechStartedAt: onset, now: confirmedAt.addingTimeInterval(0.5))
        XCTAssertEqual(later, 1)
    }

    func testFallsBackToNowWithoutABackDatedOnset() {
        var clock = TurnClock()
        let seconds = clock.update(speaking: true, speechStartedAt: nil, now: start)
        XCTAssertEqual(seconds, 0)
    }

    func testEndsAfterGap() {
        var clock = TurnClock()
        _ = clock.update(speaking: true, speechStartedAt: start, now: start)
        let stillRunning = clock.update(
            speaking: false, speechStartedAt: nil, now: start.addingTimeInterval(1.9)
        )
        XCTAssertEqual(stillRunning, 1)
        let ended = clock.update(
            speaking: false, speechStartedAt: nil, now: start.addingTimeInterval(2.1)
        )
        XCTAssertNil(ended)
    }

    func testResumingInsideTheGapContinuesTheTurn() {
        var clock = TurnClock()
        _ = clock.update(speaking: true, speechStartedAt: start, now: start)
        _ = clock.update(speaking: true, speechStartedAt: start, now: start.addingTimeInterval(0.5))
        // Goes quiet for long enough that the turn ends internally...
        _ = clock.update(speaking: false, speechStartedAt: nil, now: start.addingTimeInterval(3))
        // ...but the resumption's back-dated onset falls inside the 2s gap
        // measured from the last confirmed speech, so the original start
        // should be restored rather than starting a fresh turn at +3.4s.
        let resumeOnset = start.addingTimeInterval(2.2)
        let seconds = clock.update(speaking: true, speechStartedAt: resumeOnset, now: start.addingTimeInterval(3.4))
        XCTAssertEqual(seconds, 3)
    }

    func testResumingAfterTheGapStartsFresh() {
        var clock = TurnClock()
        _ = clock.update(speaking: true, speechStartedAt: start, now: start)
        _ = clock.update(speaking: false, speechStartedAt: nil, now: start.addingTimeInterval(3))
        let resumeOnset = start.addingTimeInterval(10)
        let seconds = clock.update(speaking: true, speechStartedAt: resumeOnset, now: start.addingTimeInterval(10.4))
        XCTAssertEqual(seconds, 0)
    }

    func testResetForgetsEverything() {
        var clock = TurnClock()
        _ = clock.update(speaking: true, speechStartedAt: start, now: start)
        clock.reset()
        let seconds = clock.update(speaking: false, speechStartedAt: nil, now: start.addingTimeInterval(0.1))
        XCTAssertNil(seconds)
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

    /// The dangerous failure. A tap that has stopped delivering reports the
    /// same low levels as a quiet room, the quiet room decays to `.clear`, and
    /// green means "go ahead and talk". Losing the far end must read as
    /// nothing rather than as permission.
    func testLosingTheFarEndReadsDarkNotClear() {
        var machine = SignalStateMachine()
        _ = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: true, now: start)
        let aspect = machine.aspect(
            meetingActive: true,
            hearingFarEnd: false,
            nearSpeaking: false,
            farSpeaking: false,
            now: start.addingTimeInterval(10)
        )
        XCTAssertEqual(aspect, .dark)
    }

    /// Your own turn is measured on the microphone, so it survives the far end
    /// going away.
    func testYourOwnTurnSurvivesLosingTheFarEnd() {
        var machine = SignalStateMachine()
        let aspect = machine.aspect(
            meetingActive: true, hearingFarEnd: false, nearSpeaking: true, farSpeaking: false, now: start
        )
        XCTAssertEqual(aspect, .speaking)
    }

    /// Recovering the tap must not leave a stale dwell behind that jumps
    /// straight to clear.
    func testRegainingTheFarEndRestartsTheDwell() {
        var machine = SignalStateMachine()
        machine.dwell = 1.2
        _ = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: true, now: start)
        _ = machine.aspect(
            meetingActive: true, hearingFarEnd: false, nearSpeaking: false, farSpeaking: false,
            now: start.addingTimeInterval(30)
        )
        let aspect = machine.aspect(
            meetingActive: true, nearSpeaking: false, farSpeaking: false,
            now: start.addingTimeInterval(30.02)
        )
        XCTAssertEqual(aspect, .caution)
    }
}

@MainActor
final class MeetingDetectionTests: XCTestCase {
    private func process(
        _ bundleID: String = "us.zoom.xos",
        output: Bool,
        input: Bool
    ) -> MeetingProcessMonitor.MatchedProcess {
        MeetingProcessMonitor.MatchedProcess(
            id: 1, pid: 100, bundleID: bundleID, isRunningOutput: output, isRunningInput: input
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

    /// The output-only fallback used to apply to everything, so a Chrome tab
    /// playing a video counted as a meeting and held a process tap and the
    /// microphone open all day.
    func testBrowserPlayingAudioIsNotAMeeting() {
        XCTAssertFalse(AudioMonitor.isLiveMeeting([
            process("com.google.Chrome.helper", output: true, input: false)
        ]))
    }

    func testBrowserWithTheMicrophoneOpenIsAMeeting() {
        XCTAssertTrue(AudioMonitor.isLiveMeeting([
            process("com.google.Chrome.helper", output: true, input: true)
        ]))
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
                    // The idle Lamp is a system symbol at its own size; every
                    // other combination is drawn into the standard slot.
                    if !(glyph == .lamp && aspect == .dark) {
                        XCTAssertEqual(image.size.height, SignalHeadRenderer.imageHeight, label)
                        XCTAssertEqual(image.size.width, SignalHeadRenderer.width(of: glyph) + 4, label)
                    }
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

final class LevelMeterTests: XCTestCase {
    func testStartsSilent() {
        XCTAssertEqual(LevelMeter().consumePeak(), LevelMeter.silence)
    }

    func testKnowsWhetherAudioHasArrived() {
        let meter = LevelMeter()
        XCTAssertFalse(meter.hasReceivedAudio)
        meter.update(dBFS: -40)
        XCTAssertTrue(meter.hasReceivedAudio)
        meter.reset()
        XCTAssertFalse(meter.hasReceivedAudio)
        XCTAssertEqual(meter.consumePeak(), LevelMeter.silence)
    }

    /// The liveness check is what tells "quiet room" apart from "dead
    /// capture" - the two are identical to the detector, and they mean
    /// opposite things.
    func testLivenessTracksUpdatesAndIsClearedByReset() {
        let meter = LevelMeter()
        XCTAssertFalse(meter.hasUpdated(within: 1))
        meter.update(dBFS: -40)
        XCTAssertTrue(meter.hasUpdated(within: 1))
        meter.reset()
        XCTAssertFalse(meter.hasUpdated(within: 1))
    }

    func testReturnsPeakSinceLastRead() {
        let meter = LevelMeter()
        meter.update(dBFS: -40)
        meter.update(dBFS: -20)
        meter.update(dBFS: -35)
        XCTAssertEqual(meter.consumePeak(), -20)
    }

    /// The microphone delivers 100ms buffers against a 20ms tick. The ticks
    /// in between must see the last level, not silence, or the detector's
    /// noise floor collapses and its onset timer never completes.
    func testHoldsLastLevelBetweenBuffers() {
        let meter = LevelMeter()
        meter.update(dBFS: -40)
        meter.update(dBFS: -20)
        XCTAssertEqual(meter.consumePeak(), -20)
        XCTAssertEqual(meter.consumePeak(), -20)
        meter.update(dBFS: -45)
        XCTAssertEqual(meter.consumePeak(), -45)
        XCTAssertEqual(meter.consumePeak(), -45)
    }
}


// MARK: - Regressions

final class VoiceActivityDetectorRegressionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    private func feed(
        _ detector: inout VoiceActivityDetector,
        dBFS: Float,
        seconds: TimeInterval,
        from now: Date
    ) -> Date {
        let step = 1.0 / 50.0
        var now = now
        let end = now.addingTimeInterval(seconds)
        while now < end {
            now = now.addingTimeInterval(step)
            detector.update(dBFS: dBFS, now: now)
        }
        return now
    }

    /// A speech envelope: syllables with dips between them and the odd breath.
    /// Real speech is never a constant level, and that is exactly what lets
    /// the noise floor stay below it.
    ///
    /// The breath is 0.2s, inside the detector's 0.7s hangover. A longer hole
    /// legitimately ends the turn - that is what the hangover is for - so
    /// stretching it here would be testing the hangover, not the noise floor.
    private func speak(
        _ detector: inout VoiceActivityDetector,
        peak: Float,
        seconds: TimeInterval,
        from now: Date
    ) -> Date {
        let step = 1.0 / 50.0
        var now = now
        let end = now.addingTimeInterval(seconds)
        var frame = 0
        while now < end {
            now = now.addingTimeInterval(step)
            frame += 1
            let syllable = frame % 10
            let dip: Float = syllable < 3 ? -18 : (syllable < 5 ? -7 : 0)
            let breath: Float = (frame % 400) < 10 ? -30 : 0
            detector.update(dBFS: peak + dip + breath, now: now)
        }
        return now
    }

    /// The floor used to be frozen outright while speaking. Because the
    /// release margin is lower than the onset margin, any steady signal loud
    /// enough to trigger an onset then stayed above the release threshold
    /// against a floor that could never move again - a far-end fan or an open
    /// mic hiss latched the block occupied for the rest of the meeting.
    func testSteadyToneIsEventuallyAbsorbedRatherThanLatchingForever() {
        var detector = VoiceActivityDetector()
        var now = feed(&detector, dBFS: -70, seconds: 3, from: start)
        now = feed(&detector, dBFS: -35, seconds: 5, from: now)
        XCTAssertTrue(detector.isSpeaking, "an onset should still fire")
        _ = feed(&detector, dBFS: -35, seconds: 175, from: now)
        XCTAssertFalse(detector.isSpeaking, "steady noise must be absorbed, not latched")
    }

    /// The counterweight to the test above: the floor must not climb into a
    /// long turn and mute the speaker mid-sentence.
    ///
    /// The margin here is wide - this passes at rise constants from 2s to 60s
    /// - because it is the 0.2s *fall* that does the work, dragging the floor
    /// back down on every syllable dip. That is the mechanism the slowed rise
    /// relies on, so this test guards it rather than the rise constant itself.
    func testLongMonologueIsNeverLost() {
        var detector = VoiceActivityDetector()
        var now = feed(&detector, dBFS: -70, seconds: 3, from: start)
        var lost = 0
        for _ in 0..<90 {
            now = speak(&detector, peak: -30, seconds: 1, from: now)
            if !detector.isSpeaking { lost += 1 }
        }
        XCTAssertEqual(lost, 0, "lost the speaker during a 90-second turn")
    }
}
