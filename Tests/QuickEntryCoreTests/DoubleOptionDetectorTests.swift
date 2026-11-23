import XCTest
@testable import QuickEntryCore

final class DoubleOptionDetectorTests: XCTestCase {
    func testValidDoubleTapTriggersOnce() {
        var detector = DoubleOptionDetector(maxTapDuration: 0.25, maxDoubleTapInterval: 0.35)

        XCTAssertFalse(detector.feed(.optionDown, at: 1.00))
        XCTAssertFalse(detector.feed(.optionUp, at: 1.08))
        XCTAssertFalse(detector.feed(.optionDown, at: 1.20))
        XCTAssertTrue(detector.feed(.optionUp, at: 1.28))
        XCTAssertEqual(detector.state, .idle)
    }

    func testSlowIntervalDoesNotTrigger() {
        var detector = DoubleOptionDetector(maxTapDuration: 0.25, maxDoubleTapInterval: 0.35)

        XCTAssertFalse(detector.feed(.optionDown, at: 1.00))
        XCTAssertFalse(detector.feed(.optionUp, at: 1.08))
        // Gap of 0.50s > 0.35s should reset and count as a fresh first tap
        XCTAssertFalse(detector.feed(.optionDown, at: 1.58))
        XCTAssertFalse(detector.feed(.optionUp, at: 1.65))
        XCTAssertEqual(detector.state, .awaitingSecondDown(firstReleasedAt: 1.65))
    }

    func testLongHoldDoesNotTrigger() {
        var detector = DoubleOptionDetector(maxTapDuration: 0.25, maxDoubleTapInterval: 0.35)

        XCTAssertFalse(detector.feed(.optionDown, at: 1.00))
        XCTAssertFalse(detector.feed(.optionUp, at: 1.45)) // Held 450ms
        XCTAssertEqual(detector.state, .idle)
    }

    func testOptionChordInterruptionCancelsDoubleTap() {
        var detector = DoubleOptionDetector(maxTapDuration: 0.25, maxDoubleTapInterval: 0.35)

        XCTAssertFalse(detector.feed(.optionDown, at: 1.00))
        XCTAssertFalse(detector.feed(.interruption, at: 1.05)) // e.g., Option+LeftArrow
        XCTAssertFalse(detector.feed(.optionUp, at: 1.10))
        XCTAssertFalse(detector.feed(.optionDown, at: 1.18))
        XCTAssertFalse(detector.feed(.optionUp, at: 1.25))
    }

    func testTripleTapTriggersOnlyOnce() {
        var detector = DoubleOptionDetector(maxTapDuration: 0.25, maxDoubleTapInterval: 0.35)

        XCTAssertFalse(detector.feed(.optionDown, at: 1.00))
        XCTAssertFalse(detector.feed(.optionUp, at: 1.05))
        XCTAssertFalse(detector.feed(.optionDown, at: 1.12))
        XCTAssertTrue(detector.feed(.optionUp, at: 1.18))
        // Immediate third tap starts a fresh first tap rather than firing again
        XCTAssertFalse(detector.feed(.optionDown, at: 1.24))
        XCTAssertFalse(detector.feed(.optionUp, at: 1.30))
    }
}
