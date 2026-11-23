import XCTest
import CoreGraphics
@testable import QuickEntryCore

final class CoordinateGeometryTests: XCTestCase {
    func testAppKitQuartzCoordinateRoundTrip() {
        let primaryHeight: CGFloat = 900
        let appKitRect = CGRect(x: 100, y: 700, width: 200, height: 150)
        let quartz = CoordinateGeometry.appKitToQuartz(rect: appKitRect, primaryDisplayHeight: primaryHeight)
        XCTAssertEqual(quartz, CGRect(x: 100, y: 50, width: 200, height: 150))

        let roundTrip = CoordinateGeometry.quartzToAppKit(rect: quartz, primaryDisplayHeight: primaryHeight)
        XCTAssertEqual(roundTrip, appKitRect)
    }

    func testScaledPixelSizeCapsLongEdge() {
        let capped = CoordinateGeometry.scaledPixelSize(
            pointSize: CGSize(width: 2000, height: 1000),
            backingScaleFactor: 2.0,
            maxLongEdge: 2560
        )
        XCTAssertEqual(capped.width, 2560)
        XCTAssertEqual(capped.height, 1280)
    }
}
