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
