import XCTest
@testable import blew

final class RSSIBarTests: XCTestCase {

    // MARK: - rssiBar extremes

    func testRSSIBarMaxSignal() {
        // -30 dBm: clamped to -30, ratio = (70/70) = 1.0 => all 8 filled
        let bar = TextRenderer.rssiBar(-30)
        XCTAssertEqual(bar, "████████")
    }

    func testRSSIBarMinSignal() {
        // -100 dBm: clamped to -100, ratio = (0/70) = 0.0 => all 8 empty
        let bar = TextRenderer.rssiBar(-100)
        XCTAssertEqual(bar, "░░░░░░░░")
    }

    func testRSSIBarAboveMaxClamped() {
        // -10 dBm (above -30): clamped to -30 = all filled
        let bar = TextRenderer.rssiBar(-10)
        XCTAssertEqual(bar, "████████")
    }

    func testRSSIBarBelowMinClamped() {
        // -120 dBm (below -100): clamped to -100 = all empty
        let bar = TextRenderer.rssiBar(-120)
        XCTAssertEqual(bar, "░░░░░░░░")
    }

    func testRSSIBarMidRange() {
        // -65 dBm: ratio = (35/70) = 0.5 => 4 filled, 4 empty
        let bar = TextRenderer.rssiBar(-65)
        XCTAssertEqual(bar, "████░░░░")
    }

    func testRSSIBarQuarterSignal() {
        // -82.5 dBm -> ratio = (17.5/70) = 0.25 => 2 filled, 6 empty
        let bar = TextRenderer.rssiBar(-83)
        XCTAssertEqual(bar, "██░░░░░░")
    }

    func testRSSIBarCustomWidth4() {
        let bar = TextRenderer.rssiBar(-65, width: 4)
        XCTAssertEqual(bar.count, 4)
        XCTAssertEqual(bar, "██░░")
    }

    func testRSSIBarCustomWidth1Max() {
        let bar = TextRenderer.rssiBar(-30, width: 1)
        XCTAssertEqual(bar, "█")
    }

    func testRSSIBarCustomWidth1Min() {
        let bar = TextRenderer.rssiBar(-100, width: 1)
        XCTAssertEqual(bar, "░")
    }

    func testRSSIBarLengthIsAlwaysWidth() {
        for rssi in stride(from: -100, through: -30, by: 5) {
            let bar = TextRenderer.rssiBar(rssi, width: 8)
            // Count in terms of Unicode scalars since these are multi-byte chars
            let filledCount = bar.unicodeScalars.filter { $0.value == 0x2588 }.count
            let emptyCount = bar.unicodeScalars.filter { $0.value == 0x2591 }.count
            XCTAssertEqual(filledCount + emptyCount, 8, "Bar width wrong for RSSI \(rssi): \(bar)")
        }
    }

    func testRSSIBarFilledPlusEmptyEqualsWidth() {
        let bar = TextRenderer.rssiBar(-65, width: 10)
        let total = bar.unicodeScalars.filter { $0.value == 0x2588 || $0.value == 0x2591 }.count
        XCTAssertEqual(total, 10)
    }
}

/// The label a listing shows for a decoded field's GSS name.
final class FieldLabelTests: XCTestCase {

    func testPlainNameIsTheLabel() {
        XCTAssertEqual(CommandRouter.fieldLabel("Battery Level"), "Battery Level")
    }

    func testNestedNameTakesTheLastComponent() {
        XCTAssertEqual(CommandRouter.fieldLabel("Date Time.Year"), "Year")
        XCTAssertEqual(CommandRouter.fieldLabel("Outer.Middle.Leaf"), "Leaf")
    }

    func testLabelWithWhitespaceIsTrimmed() {
        XCTAssertEqual(CommandRouter.fieldLabel("A. B"), "B")
    }
}
