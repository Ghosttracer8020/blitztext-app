import ApplicationServices
import XCTest

final class ReplyWindowPresenceTests: XCTestCase {
    func testInvalidElementMeansGone() {
        XCTAssertTrue(ReplyWindowPresence.isGone(appRunning: true, roleResult: .invalidUIElement, inWindowList: nil))
    }

    func testMissingFromWindowListMeansGone() {
        XCTAssertTrue(ReplyWindowPresence.isGone(appRunning: true, roleResult: .success, inWindowList: false))
    }

    func testTerminatedAppMeansGone() {
        XCTAssertTrue(ReplyWindowPresence.isGone(appRunning: false, roleResult: .success, inWindowList: true))
    }

    func testPresentWindowIsNotGone() {
        XCTAssertFalse(ReplyWindowPresence.isGone(appRunning: true, roleResult: .success, inWindowList: true))
    }

    func testTimeoutAndUnknownListStayNotGone() {
        XCTAssertFalse(ReplyWindowPresence.isGone(appRunning: true, roleResult: .cannotComplete, inWindowList: nil))
        XCTAssertFalse(ReplyWindowPresence.isGone(appRunning: true, roleResult: .success, inWindowList: nil))
    }
}
