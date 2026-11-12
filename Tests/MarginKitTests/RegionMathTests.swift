import XCTest
@testable import MarginKit

final class RegionMathTests: XCTestCase {
    func testDragInAnyDirection() {
        let r = RegionMath.rect(from: CGPoint(x: 300, y: 50), to: CGPoint(x: 100, y: 250))
        XCTAssertEqual(r, CGRect(x: 100, y: 50, width: 200, height: 200))
    }

    func testFlipBetweenAppKitAndCoreGraphics() {
        // A 100pt tall box sitting 10pt above the bottom of a 900pt screen…
        let appKit = CGRect(x: 20, y: 10, width: 300, height: 100)
        let cg = RegionMath.flip(appKit, primaryHeight: 900)
        // …is 790pt from the top.
        XCTAssertEqual(cg, CGRect(x: 20, y: 790, width: 300, height: 100))
        XCTAssertEqual(RegionMath.flip(cg, primaryHeight: 900), appKit)
        // A screen above the primary one has negative CG y.
        XCTAssertEqual(RegionMath.flip(CGRect(x: 0, y: 900, width: 10, height: 10), primaryHeight: 900).minY, -10)
    }

    func testScreencaptureArgumentGrowsOutward() {
        XCTAssertEqual(RegionMath.screencaptureArgument(CGRect(x: 10.4, y: 20.6, width: 99.5, height: 50.1)), "10,20,100,51")
    }

    func testClicks() {
        XCTAssertTrue(RegionMath.isClick(CGRect(x: 0, y: 0, width: 2, height: 300)))
        XCTAssertFalse(RegionMath.isClick(CGRect(x: 0, y: 0, width: 20, height: 20)))
    }

    func testVideoSize() {
        XCTAssertEqual(RegionMath.videoSize(for: CGSize(width: 401, height: 301), scale: 2).width, 802)
        XCTAssertEqual(RegionMath.videoSize(for: CGSize(width: 401.3, height: 301), scale: 1).width, 400)
        let big = RegionMath.videoSize(for: CGSize(width: 2560, height: 1440), scale: 2)
        XCTAssertLessThanOrEqual(big.width, 3840)
        XCTAssertEqual(big.width % 2, 0)
        XCTAssertEqual(big.height % 2, 0)
        XCTAssertEqual(Double(big.width) / Double(big.height), 2560.0 / 1440.0, accuracy: 0.01)
    }

    func testDuration() {
        XCTAssertEqual(RegionMath.duration(7.2), "0:07")
        XCTAssertEqual(RegionMath.duration(60), "1:00")
        XCTAssertEqual(RegionMath.duration(-1), "0:00")
    }

    func testLabelStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let below = RegionMath.labelOrigin(for: CGRect(x: 100, y: 300, width: 200, height: 100), labelSize: CGSize(width: 80, height: 20), in: screen)
        XCTAssertEqual(below, CGPoint(x: 220, y: 272))
        let atBottom = RegionMath.labelOrigin(for: CGRect(x: 0, y: 0, width: 50, height: 100), labelSize: CGSize(width: 80, height: 20), in: screen)
        XCTAssertGreaterThanOrEqual(atBottom.y, 4)
        XCTAssertGreaterThanOrEqual(atBottom.x, 4)
    }
}
