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

    /// YB-50. A room that is quiet first and then gains a steady noise (a
    /// dryer starting in the next room, a fan kicking in) must not read as
    /// speech for the rest of the session. The floor only rises with an
    /// 8s time constant, so the step clears the onset margin long before the
    /// floor catches up; if the floor then freezes, nothing ever releases.
    func testSteadyNoiseStartingAfterAQuietRoomReleases() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -65, seconds: 5, from: start)
        XCTAssertFalse(detector.isSpeaking)
        now = feed(&detector, dBFS: -45, seconds: 15, from: now)
        XCTAssertFalse(detector.isSpeaking, "fifteen seconds of constant -45 dBFS is a fan, not a voice")
        now = feed(&detector, dBFS: -45, seconds: 15, from: now)
        XCTAssertFalse(detector.isSpeaking)
        XCTAssertGreaterThan(detector.noiseFloor, -50, "the floor should have risen to meet the new steady level")
    }

    /// The reason the floor used to freeze during speech: a long turn must
    /// not raise the floor to its own level and mute itself. Real speech
    /// dips to the room level between words, and that is what keeps the
    /// floor where it belongs now.
    func testLongTurnKeepsItsFloor() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        // Three minutes of talking at -25 with a 100 ms dip to the room
        // level once a second.
        for _ in 0..<180 {
            now = feed(&detector, dBFS: -25, seconds: 0.9, from: now)
            XCTAssertTrue(detector.isSpeaking)
            now = feed(&detector, dBFS: -60, seconds: 0.1, from: now)
            XCTAssertTrue(detector.isSpeaking)
        }
        XCTAssertEqual(detector.noiseFloor, -60, accuracy: 3)
    }

    /// Even with no dip at all the floor rises slowly enough that a stretch
    /// far longer than anyone talks without breathing stays confirmed.
    func testGaplessSpeechDoesNotMuteItself() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var now = feed(&detector, dBFS: -60, seconds: 5, from: start)
        now = feed(&detector, dBFS: -25, seconds: 8, from: now)
        XCTAssertTrue(detector.isSpeaking)
    }

    /// The whole microphone path, as the app runs it, over a trace recorded
    /// in the room YB-50 was reported in. Before the fix this read as
    /// speaking from the first second to the last.
    func testDryerRoomTraceOnlyConfirmsActualSpeech() {
        var detector = VoiceActivityDetector()
        let start = Date(timeIntervalSince1970: 0)
        var speakingBuffers = 0
        var speakingAt: [Int: Bool] = [:]
        for (index, level) in RoomTraces.dryerRoomWithSpeech.enumerated() {
            // `MicrophoneSource` drops the zero-filled startup buffers.
            guard level > LevelMeter.silence else { continue }
            let now = start.addingTimeInterval(Double(index + 1) / 10)
            if detector.update(dBFS: level, now: now) { speakingBuffers += 1 }
            speakingAt[index] = detector.isSpeaking
        }
        XCTAssertLessThan(speakingBuffers, RoomTraces.dryerRoomWithSpeech.count * 3 / 10)
        XCTAssertEqual(speakingAt[300], false, "nobody was talking at 30 s")
        XCTAssertEqual(speakingAt[460], true, "talking at 46 s")
        XCTAssertEqual(speakingAt[540], true, "talking at 54 s")
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

    /// The engine's zero-filled startup buffers: most slices are digital
    /// zero, so the median lands on one and reads far below anything a
    /// microphone produces. `MicrophoneSource` drops buffers at or below
    /// `LevelMeter.silence` on the strength of this.
    func testMostlyZeroBufferReadsBelowTheSilenceFloor() {
        let samples = buffer(
            sliceLength: 480,
            loudSlices: [true, false, false, true, false, false, true, false, false, false],
            loudAmplitude: 0.01, quietAmplitude: 0
        )
        samples.withUnsafeBufferPointer { pointer in
            XCTAssertLessThanOrEqual(LevelAnalysis.sustainedDBFS(pointer, sliceLength: 480), LevelMeter.silence)
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

    func testTimerAndPetAgreeThroughABreathAndAStop() {
        var clock = TurnClock()
        var machine = SignalStateMachine()
        // At the engine's 50 Hz: three seconds of speech, a one-second
        // breath, two more seconds, then a real stop. Blue pet with a timer
        // or another pet with none, on every tick; and the breath must not
        // blink either of them.
        func speaking(at tick: Int) -> Bool { tick < 150 || (200..<300).contains(tick) }
        var shown: [Int?] = []
        for tick in 0..<500 {
            let now = start.addingTimeInterval(Double(tick) / 50)
            let near = speaking(at: tick)
            let onset: Date? = near ? (tick < 150 ? start : start.addingTimeInterval(4)) : nil
            let aspect = machine.aspect(meetingActive: true, nearSpeaking: near, farSpeaking: false, now: now)
            let seconds = clock.update(speaking: near, speechStartedAt: onset, now: now)
            XCTAssertEqual(
                seconds != nil, aspect == .speaking,
                "tick \(tick): seconds \(String(describing: seconds)) under aspect \(aspect)"
            )
            shown.append(seconds)
        }
        // Through the breath the count kept going...
        XCTAssertTrue((150..<200).allSatisfy { shown[$0] != nil })
        // ...and the resumption reconnected to the original start.
        XCTAssertEqual(shown[299], 5)
        // After the stop both go together, within the gap, and stay gone.
        XCTAssertNotNil(shown[398])
        XCTAssertNil(shown[401])
        XCTAssertNil(shown[499])
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

    func testAResumedTurnStaysReconnectedWhileItContinues() {
        var clock = TurnClock()
        _ = clock.update(speaking: true, speechStartedAt: start, now: start)
        _ = clock.update(speaking: false, speechStartedAt: nil, now: start.addingTimeInterval(1))
        let resumeOnset = start.addingTimeInterval(1.5)
        _ = clock.update(speaking: true, speechStartedAt: resumeOnset, now: start.addingTimeInterval(2))
        // The detector keeps reporting the same onset for the rest of the
        // turn. That must not read as "a new turn began at 1.5s" a tick later.
        let seconds = clock.update(speaking: true, speechStartedAt: resumeOnset, now: start.addingTimeInterval(4))
        XCTAssertEqual(seconds, 4)
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
    func testYourPauseHoldsTheBlockForTheGap() {
        var machine = SignalStateMachine()
        machine.nearHold = 2.0
        _ = machine.aspect(meetingActive: true, nearSpeaking: true, farSpeaking: false, now: start)

        func aspectAfter(_ seconds: TimeInterval) -> Aspect {
            machine.aspect(
                meetingActive: true,
                nearSpeaking: false,
                farSpeaking: false,
                now: start.addingTimeInterval(seconds)
            )
        }

        // A breath mid-sentence is still your turn...
        XCTAssertEqual(aspectAfter(0.02), .speaking)
        XCTAssertEqual(aspectAfter(1.9), .speaking)
        // ...a real stop is not.
        XCTAssertEqual(aspectAfter(2.1), .clear)
    }

    func testTheFarEndCuttingInEndsYourHoldAtOnce() {
        var machine = SignalStateMachine()
        machine.nearHold = 2.0
        _ = machine.aspect(meetingActive: true, nearSpeaking: true, farSpeaking: false, now: start)
        _ = machine.aspect(meetingActive: true, nearSpeaking: false, farSpeaking: false, now: start.addingTimeInterval(0.5))
        let interrupted = machine.aspect(
            meetingActive: true, nearSpeaking: false, farSpeaking: true, now: start.addingTimeInterval(1.0)
        )
        XCTAssertEqual(interrupted, .occupied)
        // When they stop, your hold does not come back: that pause is theirs.
        let theirPause = machine.aspect(
            meetingActive: true, nearSpeaking: false, farSpeaking: false, now: start.addingTimeInterval(1.1)
        )
        XCTAssertEqual(theirPause, .caution)
    }

    func testTheHoldFollowsTheTurnClockGap() {
        XCTAssertEqual(SignalStateMachine().nearHold, TurnClock().endGap)
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

final class PetPaletteTests: XCTestCase {
    /// The dark aspect is the label colour: an asleep pet should match the
    /// menu bar's other icons, not be a fifth colour.
    func testDarkAspectIsTheLabelColour() {
        XCTAssertEqual(PetPalette.color(for: .dark), .labelColor)
    }

    /// The two yellows are one colour; every other live aspect has its own.
    func testLiveAspectsAreColouredDistinctly() {
        XCTAssertEqual(PetPalette.color(for: .caution), PetPalette.color(for: .preliminary))
        let distinct = [Aspect.occupied, .caution, .clear, .speaking].map { PetPalette.color(for: $0) }
        for (index, colour) in distinct.enumerated() {
            for other in distinct[(index + 1)...] {
                XCTAssertNotEqual(colour, other)
            }
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

final class UpdateReadinessTests: XCTestCase {
    func testMayNotInstallDuringAMeeting() {
        let now = Date()
        XCTAssertFalse(UpdateReadiness.mayInstall(meetingActive: true, lastMeetingEndedAt: nil, now: now))
        // A meeting that started right after a previous one ended still wins:
        // "active" always outranks a leftover end time.
        XCTAssertFalse(
            UpdateReadiness.mayInstall(meetingActive: true, lastMeetingEndedAt: now.addingTimeInterval(-120), now: now)
        )
    }

    func testMayNotInstallWithinTheSettleWindowAfterAMeetingEnds() {
        let ended = Date()
        let now = ended.addingTimeInterval(UpdateReadiness.settleInterval - 1)
        XCTAssertFalse(UpdateReadiness.mayInstall(meetingActive: false, lastMeetingEndedAt: ended, now: now))
    }

    func testMayInstallOnceTheSettleWindowPasses() {
        let ended = Date()
        let now = ended.addingTimeInterval(UpdateReadiness.settleInterval)
        XCTAssertTrue(UpdateReadiness.mayInstall(meetingActive: false, lastMeetingEndedAt: ended, now: now))
    }

    /// A cold launch that has never seen a meeting shouldn't be held back by
    /// a settle window that never started.
    func testMayInstallWhenNoMeetingHasEverRun() {
        XCTAssertTrue(UpdateReadiness.mayInstall(meetingActive: false, lastMeetingEndedAt: nil, now: Date()))
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

    /// Every aspect draws something into the image. This runs the drawing
    /// code for real rather than trusting the handler to do it later.
    func testEveryAspectDraws() {
        for aspect in Aspect.allCases {
            let image = SignalHeadRenderer.menuBarImage(for: aspect, speakingSeconds: nil)
            XCTAssertEqual(image.size.height, SignalHeadRenderer.imageHeight, "\(aspect)")
            XCTAssertEqual(image.size.width, SignalHeadRenderer.glyphWidth + 4, "\(aspect)")
            XCTAssertTrue(paintsAnything(image), "\(aspect) drew nothing")
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
        let silent = SignalHeadRenderer.menuBarImage(for: .speaking, speakingSeconds: nil)
        let talking = SignalHeadRenderer.menuBarImage(for: .speaking, speakingSeconds: 42)
        let tiring = SignalHeadRenderer.menuBarImage(
            for: .speaking, speakingSeconds: SignalHeadRenderer.tiringSeconds + 10
        )
        let longTurn = SignalHeadRenderer.menuBarImage(
            for: .speaking, speakingSeconds: SignalHeadRenderer.longTurnSeconds + 32
        )
        XCTAssertGreaterThan(talking.size.width, silent.size.width)
        XCTAssertTrue(paintsAnything(talking), "0:42 drew nothing")
        XCTAssertTrue(paintsAnything(tiring), "two minutes drew nothing")
        XCTAssertTrue(paintsAnything(longTurn), "a long turn drew nothing")
    }

    /// The pet keeps his tail on the left while the floor is theirs and
    /// swings it to the right once it's yours, like chat bubbles do. Only
    /// the tail reaches the bottom rows of the image, so where the paint
    /// sits in those rows says which side it's on.
    func testPetTurnsHisTailToWhoeverHasTheFloor() {
        for aspect in [Aspect.dark, .occupied, .caution, .preliminary] {
            let image = SignalHeadRenderer.menuBarImage(for: aspect, speakingSeconds: nil)
            XCTAssertLessThan(tailSide(of: image), 0.5, "\(aspect): tail should be on the left")
        }
        let clear = SignalHeadRenderer.menuBarImage(for: .clear, speakingSeconds: nil)
        XCTAssertGreaterThan(tailSide(of: clear), 0.5, "clear: tail should be on the right")
        let speaking = SignalHeadRenderer.menuBarImage(for: .speaking, speakingSeconds: 42)
        XCTAssertGreaterThan(tailSide(of: speaking), 0.5, "speaking: tail should be on the right")
    }

    /// Where the paint in the image's bottom rows sits, as a fraction of the
    /// pet's width: 0 is the far left, 1 the far right.
    private func tailSide(of image: NSImage) -> CGFloat {
        let (rep, width, _) = render(image)
        guard let data = rep.bitmapData else { return 0.5 }
        // Bottom rows of a bitmap are the highest y; the pet's box is the
        // first 20pt of a wider image, so only look under it.
        let glyphWidth = min(width, Int(SignalHeadRenderer.glyphWidth + 4) * 2)
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

    /// A pending update only ever shows while `.dark`: it's the one aspect
    /// where the badge should change the picture. Caching on aspect alone
    /// (rather than aspect *and* badge) would have handed back whichever of
    /// the two was drawn first for every call after it, for both assertions
    /// below.
    func testUpdateBadgeOnlyChangesTheDarkImage() {
        let darkPlain = SignalHeadRenderer.menuBarImage(for: .dark, speakingSeconds: nil)
        let darkBadged = SignalHeadRenderer.menuBarImage(for: .dark, speakingSeconds: nil, updateAvailable: true)
        XCTAssertNotEqual(
            renderedBytes(darkPlain), renderedBytes(darkBadged),
            "a pending update should be visible while dark"
        )

        let occupiedPlain = SignalHeadRenderer.menuBarImage(for: .occupied, speakingSeconds: nil)
        let occupiedBadged = SignalHeadRenderer.menuBarImage(
            for: .occupied, speakingSeconds: nil, updateAvailable: true
        )
        XCTAssertEqual(
            renderedBytes(occupiedPlain), renderedBytes(occupiedBadged),
            "a pending update must not touch a live aspect's image"
        )
    }

    private func renderedBytes(_ image: NSImage) -> [UInt8] {
        let (rep, width, height) = render(image)
        guard let data = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: width * height * 4))
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

final class SpeechConfirmationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Hold one gate decision steady across a stretch of time, at the app's
    /// real tick rate, and return the last decision.
    @discardableResult
    private func run(
        _ confirmation: inout SpeechConfirmation,
        gateSpeaking: Bool,
        gateStartedAt: Date?,
        wordsHeardThrough: Date? = nil,
        from: TimeInterval,
        to: TimeInterval
    ) -> SpeechConfirmation.Decision {
        var decision = SpeechConfirmation.Decision(
            isSpeaking: confirmation.isSpeaking, speechStartedAt: confirmation.speechStartedAt
        )
        let step = 1.0 / 50.0
        var t = from
        while t < to {
            t += step
            decision = confirmation.update(
                gateSpeaking: gateSpeaking,
                gateStartedAt: gateStartedAt,
                wordsHeardThrough: wordsHeardThrough,
                now: at(t)
            )
        }
        return decision
    }

    func testWordsInsideTheWindowConfirmTheGatesOnset() {
        var confirmation = SpeechConfirmation()
        // The gate fires at 1.0 s, back-dated to 0.4 s. Nothing shows yet.
        run(&confirmation, gateSpeaking: true, gateStartedAt: at(0.4), from: 1.0, to: 1.5)
        XCTAssertFalse(confirmation.isSpeaking, "no words have arrived yet")

        let decision = run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(0.4),
            wordsHeardThrough: at(1.4), from: 1.5, to: 1.6
        )
        XCTAssertTrue(decision.isSpeaking)
        XCTAssertEqual(decision.speechStartedAt, at(0.4), "the turn back-dates to the gate's onset")
    }

    func testCandidateWithoutWordsIsDiscardedAndStaysDiscarded() {
        var confirmation = SpeechConfirmation()
        run(&confirmation, gateSpeaking: true, gateStartedAt: at(0.4), from: 1.0, to: 4.5)
        XCTAssertFalse(confirmation.isSpeaking, "three seconds of typing is not a turn")

        // Words older than the discard - the tail of a previous turn - must
        // not bring a candidate we've already given up on back to life.
        let decision = run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(0.4),
            wordsHeardThrough: at(0.9), from: 4.5, to: 8.0
        )
        XCTAssertFalse(decision.isSpeaking)
        XCTAssertNil(decision.speechStartedAt)
    }

    func testGateReleaseResetsAndTheNextTurnNeedsFreshWords() {
        var confirmation = SpeechConfirmation()
        run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(0.4),
            wordsHeardThrough: at(1.4), from: 1.0, to: 2.0
        )
        XCTAssertTrue(confirmation.isSpeaking)

        run(&confirmation, gateSpeaking: false, gateStartedAt: nil, wordsHeardThrough: at(1.4), from: 2.0, to: 2.5)
        XCTAssertFalse(confirmation.isSpeaking)
        XCTAssertNil(confirmation.speechStartedAt)

        // A new candidate much later, with the same words still on record:
        // they're older than its onset, so it waits like any other.
        let decision = run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(10.0),
            wordsHeardThrough: at(1.4), from: 10.5, to: 11.0
        )
        XCTAssertFalse(decision.isSpeaking)
    }

    func testWordsOlderThanTheOnsetDoNotConfirm() {
        var confirmation = SpeechConfirmation()
        let decision = run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(5.0),
            wordsHeardThrough: at(4.9), from: 5.5, to: 7.0
        )
        XCTAssertFalse(decision.isSpeaking, "those words covered audio from before this candidate")
    }

    /// The recogniser is silent between results and for whole seconds during
    /// a pause. Only the gate ends a turn.
    func testConfirmedTurnSurvivesTheRecogniserGoingQuiet() {
        var confirmation = SpeechConfirmation()
        run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(0.4),
            wordsHeardThrough: at(1.4), from: 1.0, to: 1.5
        )
        XCTAssertTrue(confirmation.isSpeaking)

        let decision = run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(0.4),
            wordsHeardThrough: at(1.4), from: 1.5, to: 11.5
        )
        XCTAssertTrue(decision.isSpeaking, "the window only ever applies to a candidate")
        XCTAssertEqual(decision.speechStartedAt, at(0.4))
    }

    /// You type, then talk, without a gap long enough for the gate to let go.
    /// The words are real, so the turn is real - but it starts where the
    /// words did, not where the typing did.
    func testLateWordsConfirmFromWhenTheyWereHeard() {
        var confirmation = SpeechConfirmation()
        run(&confirmation, gateSpeaking: true, gateStartedAt: at(0.8), from: 1.0, to: 6.4)
        XCTAssertFalse(confirmation.isSpeaking)

        let decision = run(
            &confirmation, gateSpeaking: true, gateStartedAt: at(0.8),
            wordsHeardThrough: at(6.4), from: 6.4, to: 6.5
        )
        XCTAssertTrue(decision.isSpeaking)
        XCTAssertEqual(decision.speechStartedAt, at(6.4), "not the gate's onset, which was the typing")
    }
}

/// Replays the 2026-09-05 measurement through the real detector and the real
/// confirmation, the way the app runs them: one level per 100 ms microphone
/// buffer, word events at the moment they arrived.
final class WordTraceReplayTests: XCTestCase {
    private struct Replay {
        /// When the energy gate first called it speech, in seconds from the
        /// start of the clip.
        var gateFiredAt: TimeInterval?
        /// When the lamp would have turned blue, or nil if it never did.
        var confirmedAt: TimeInterval?
        /// The onset the turn was back-dated to.
        var confirmedOnset: TimeInterval?
        /// The gate's own onset at the moment of confirmation.
        var gateOnsetAtConfirm: TimeInterval?
    }

    private func replay(_ trace: RoomTraces.WordTrace) -> Replay {
        var detector = VoiceActivityDetector()
        var confirmation = SpeechConfirmation()
        let start = Date(timeIntervalSince1970: 0)
        var wordsHeardThrough: Date?
        var nextWord = 0
        var result = Replay()

        for (index, level) in trace.levels.enumerated() {
            let elapsed = Double(index + 1) / 10
            let now = start.addingTimeInterval(elapsed)
            while nextWord < trace.words.count, trace.words[nextWord].arrivedAt <= elapsed {
                wordsHeardThrough = start.addingTimeInterval(trace.words[nextWord].heardThrough)
                nextWord += 1
            }

            let gate = detector.update(dBFS: level, now: now)
            let decision = confirmation.update(
                gateSpeaking: gate,
                gateStartedAt: detector.speechStartedAt,
                wordsHeardThrough: wordsHeardThrough,
                now: now
            )
            if gate, result.gateFiredAt == nil { result.gateFiredAt = elapsed }
            if decision.isSpeaking, result.confirmedAt == nil {
                result.confirmedAt = elapsed
                result.confirmedOnset = decision.speechStartedAt?.timeIntervalSince(start)
                result.gateOnsetAtConfirm = detector.speechStartedAt?.timeIntervalSince(start)
            }
        }
        return result
    }

    func testTypingNeverTurnsTheLampBlue() {
        let result = replay(RoomTraces.typing)
        XCTAssertNotNil(result.gateFiredAt, "the gate still calls typing speech - that's the bug")
        XCTAssertNil(result.confirmedAt, "no words, so no turn")
    }

    func testMusicNeverTurnsTheLampBlue() {
        let result = replay(RoomTraces.music)
        XCTAssertNotNil(result.gateFiredAt, "the gate still calls music speech")
        XCTAssertNil(result.confirmedAt, "no words, so no turn")
    }

    func testSpokenParagraphTurnsTheLampBlueAtTheGatesOnset() throws {
        let result = replay(RoomTraces.paragraph)
        let confirmedAt = try XCTUnwrap(result.confirmedAt, "the paragraph never turned the lamp blue")
        XCTAssertLessThan(confirmedAt, 2.0, "blue within two seconds of the clip starting")
        XCTAssertEqual(result.confirmedOnset, result.gateOnsetAtConfirm, "no seconds are lost to the wait")
    }
}

final class TapSilenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Feed the detector at the app's real detect rate.
    @discardableResult
    private func feed(
        _ silence: inout TapSilence,
        seconds: TimeInterval,
        isDelivering: Bool = true,
        heardNonZero: Bool = false,
        nearEndAlive: Bool = true,
        from origin: Date
    ) -> Date {
        let step: TimeInterval = 2
        var now = origin
        let end = origin.addingTimeInterval(seconds)
        while now < end {
            now = now.addingTimeInterval(step)
            silence.update(
                isDelivering: isDelivering,
                heardNonZero: heardNonZero,
                nearEndAlive: nearEndAlive,
                now: now
            )
        }
        return now
    }

    /// The whole point: frames arriving, none of them non-zero, near end
    /// alive. That is a refused System Audio Recording and nothing else.
    func testBlocksAfterAMinuteOfDeliveredZeros() {
        var silence = TapSilence()
        feed(&silence, seconds: 90, from: start)
        XCTAssertEqual(silence.verdict, .blocked)
    }

    /// A quiet stretch inside a call must not be mistaken for it.
    func testDoesNotBlockBeforeTheWindowIsUp() {
        var silence = TapSilence()
        feed(&silence, seconds: 30, from: start)
        XCTAssertEqual(silence.verdict, .healthy)
    }

    /// One sample settles it for the rest of the call: a tap that has been
    /// heard once was never blocked, however quiet it goes afterwards.
    func testOneNonZeroSampleLatchesHealthy() {
        var silence = TapSilence()
        var now = feed(&silence, seconds: 30, from: start)
        now = feed(&silence, seconds: 2, heardNonZero: true, from: now)
        feed(&silence, seconds: 300, from: now)
        XCTAssertEqual(silence.verdict, .healthy)
        XCTAssertTrue(silence.hasHeardAudio)
    }

    /// A tap delivering nothing at all is a different failure, and the
    /// microphone being dead means the room can't be vouched for.
    func testNeitherIdleTapNorDeadNearEndBlocks() {
        var idle = TapSilence()
        feed(&idle, seconds: 300, isDelivering: false, from: start)
        XCTAssertEqual(idle.verdict, .healthy)

        var deaf = TapSilence()
        feed(&deaf, seconds: 300, nearEndAlive: false, from: start)
        XCTAssertEqual(deaf.verdict, .healthy)
    }

    /// The microphone takes a few seconds to deliver its first buffer. That
    /// wait is neither counted against the tap nor credited to it.
    func testTimeBeforeTheNearEndWakesUpIsNotCounted() {
        var silence = TapSilence()
        var now = feed(&silence, seconds: 58, nearEndAlive: false, from: start)
        now = feed(&silence, seconds: 30, from: now)
        XCTAssertEqual(silence.verdict, .healthy)
        feed(&silence, seconds: 40, from: now)
        XCTAssertEqual(silence.verdict, .blocked)
    }

    /// A sleeping Mac leaves a long gap between ticks, which says nothing
    /// about the tap and mustn't be spent as if it were silence.
    func testALongGapBetweenTicksIsClamped() {
        var silence = TapSilence()
        silence.update(isDelivering: true, heardNonZero: false, nearEndAlive: true, now: start)
        silence.update(
            isDelivering: true,
            heardNonZero: false,
            nearEndAlive: true,
            now: start.addingTimeInterval(3600)
        )
        XCTAssertEqual(silence.verdict, .healthy)
    }

    /// Teardown and the one retry both go through `reset`, so no verdict
    /// carries across a rebuilt tap.
    func testResetForgetsTheCall() {
        var silence = TapSilence()
        feed(&silence, seconds: 90, from: start)
        XCTAssertEqual(silence.verdict, .blocked)
        silence.reset()
        XCTAssertEqual(silence.verdict, .healthy)
        feed(&silence, seconds: 30, from: start.addingTimeInterval(200))
        XCTAssertEqual(silence.verdict, .healthy)
    }
}
