import XCTest

final class HintsPanelPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 360, height: 200)

    func testCapsuleRectSitsInsideWindowAtBottomInset() {
        let window = CGRect(x: 500, y: 300, width: PillLayout.outerWidth, height: PillLayout.outerHeight)
        let capsule = PillGeometry.capsuleRect(inWindowFrame: window)
        XCTAssertEqual(capsule.midX, window.midX)
        XCTAssertEqual(capsule.minY, window.minY + PillLayout.pillBottomInset)
        XCTAssertEqual(capsule.size, CGSize(width: PillLayout.pillWidth, height: PillLayout.pillHeight))
    }

    func testPlacesCentredAboveCapsuleWithGap() {
        let capsule = CGRect(x: 700, y: 400, width: 76, height: 28)
        let rect = HintsPanelPlacement.contentRect(contentSize: size, capsule: capsule, visible: visible)
        XCTAssertEqual(rect.midX, capsule.midX)
        XCTAssertEqual(rect.minY, capsule.maxY + HintsPanelPlacement.gap)
        XCTAssertEqual(rect.size, size)
    }

    func testFallsBelowWhenNoRoomAbove() {
        let capsule = CGRect(x: 700, y: 820, width: 76, height: 28)  // pill near the top edge
        let rect = HintsPanelPlacement.contentRect(contentSize: size, capsule: capsule, visible: visible)
        XCTAssertEqual(rect.maxY, capsule.minY - HintsPanelPlacement.gap)
        XCTAssertEqual(rect.midX, capsule.midX)
    }

    func testClampsHorizontallyToVisibleFrame() {
        let left = HintsPanelPlacement.contentRect(
            contentSize: size, capsule: CGRect(x: 10, y: 400, width: 76, height: 28), visible: visible
        )
        XCTAssertEqual(left.minX, visible.minX)
        let right = HintsPanelPlacement.contentRect(
            contentSize: size, capsule: CGRect(x: 1400, y: 400, width: 76, height: 28), visible: visible
        )
        XCTAssertEqual(right.maxX, visible.maxX)
    }

    func testRespectsVisibleFrameOriginOfSecondaryScreen() {
        let secondary = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        let capsule = CGRect(x: 1500, y: -190, width: 76, height: 28)
        let rect = HintsPanelPlacement.contentRect(contentSize: size, capsule: capsule, visible: secondary)
        XCTAssertGreaterThanOrEqual(rect.minX, secondary.minX)
        XCTAssertGreaterThanOrEqual(rect.minY, secondary.minY)
        XCTAssertLessThanOrEqual(rect.maxY, secondary.maxY)
    }

    func testNeverLeavesVisibleFrameVertically() {
        // Capsule in the middle of a tiny screen: neither side fits, result is clamped.
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 220)
        let rect = HintsPanelPlacement.contentRect(
            contentSize: size, capsule: CGRect(x: 400, y: 100, width: 76, height: 28), visible: tiny
        )
        XCTAssertGreaterThanOrEqual(rect.minY, tiny.minY)
        XCTAssertLessThanOrEqual(rect.maxY, tiny.maxY)
    }
}
