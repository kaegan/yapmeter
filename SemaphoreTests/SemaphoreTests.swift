import CoreAudio
import XCTest
@testable import Semaphore

final class SemaphoreTests: XCTestCase {
    func testAspectHasFiveStates() {
        XCTAssertEqual(Aspect.allCases.count, 5)
    }

    func testAspectDisplayNamesAreNonEmpty() {
        for aspect in Aspect.allCases {
            XCTAssertFalse(aspect.displayName.isEmpty)
        }
    }
}

final class MeetingDetectionTests: XCTestCase {
    private func process(
        _ id: AudioObjectID,
        _ bundleID: String,
        input: Bool = false,
        output: Bool = false
    ) -> MeetingProcessMonitor.MatchedProcess {
        MeetingProcessMonitor.MatchedProcess(
            id: id, pid: pid_t(id), bundleID: bundleID,
            isRunningInput: input, isRunningOutput: output
        )
    }

    func testNoMeetingWhenNothingIsUsingTheMic() {
        let matches = [process(1, "com.google.Chrome"), process(2, "us.zoom.xos")]
        XCTAssertNil(MeetingProcessMonitor.detectMeeting(among: matches))
    }

    func testOutputAloneIsNotAMeeting() {
        // Chrome playing a YouTube video: audio out, no mic.
        let matches = [process(1, "com.google.Chrome.helper", output: true)]
        XCTAssertNil(MeetingProcessMonitor.detectMeeting(among: matches))
    }

    func testMicInUseByMeetingAppIsAMeeting() {
        let matches = [process(1, "us.zoom.xos", input: true, output: true)]
        let meeting = MeetingProcessMonitor.detectMeeting(among: matches)
        XCTAssertEqual(meeting?.appNames, ["Zoom"])
        XCTAssertEqual(meeting?.processIDs, [1])
    }

    func testMeetingCoversEveryProcessOfTheAppThatHasTheMic() {
        // Chrome's mic lives in one helper and its output in another; the
        // tap has to cover both, but Slack (idle) stays out of it.
        let matches = [
            process(1, "com.google.Chrome"),
            process(2, "com.google.Chrome.helper", input: true),
            process(3, "com.google.Chrome.helper.renderer", output: true),
            process(4, "com.tinyspeck.slackmacgap", output: true),
        ]
        let meeting = MeetingProcessMonitor.detectMeeting(among: matches)
        XCTAssertEqual(meeting?.appNames, ["Chrome"])
        XCTAssertEqual(meeting?.processIDs.sorted(), [1, 2, 3])
        XCTAssertEqual(meeting?.bundleIDs, ["com.google.Chrome.helper"])
    }

    func testTwoAppsInMeetingsAreBothReported() {
        let matches = [
            process(1, "us.zoom.xos", input: true),
            process(2, "com.tinyspeck.slackmacgap", input: true),
        ]
        let meeting = MeetingProcessMonitor.detectMeeting(among: matches)
        XCTAssertEqual(meeting?.appNames, ["Slack", "Zoom"])
        XCTAssertEqual(meeting?.processIDs.sorted(), [1, 2])
    }

    func testUnknownAppUsingTheMicIsIgnored() {
        // matchingProcesses() filters these out, but the rule shouldn't
        // depend on that.
        let matches = [process(1, "com.apple.VoiceMemos", input: true)]
        XCTAssertNil(MeetingProcessMonitor.detectMeeting(among: matches))
    }
}
