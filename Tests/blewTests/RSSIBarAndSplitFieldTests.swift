import XCTest
@testable import blew

final class RSSIBarTests: XCTestCase {

    // MARK: - rssiBar extremes

    func testRSSIBarMaxSignal() {
        // -30 dBm: clamped to -30, ratio = (70/70) = 1.0 => all 8 filled
        let bar = CommandRouter.rssiBar(-30)
        XCTAssertEqual(bar, "████████")
    }

    func testRSSIBarMinSignal() {
        // -100 dBm: clamped to -100, ratio = (0/70) = 0.0 => all 8 empty
        let bar = CommandRouter.rssiBar(-100)
        XCTAssertEqual(bar, "░░░░░░░░")
    }

    func testRSSIBarAboveMaxClamped() {
        // -10 dBm (above -30): clamped to -30 = all filled
        let bar = CommandRouter.rssiBar(-10)
        XCTAssertEqual(bar, "████████")
    }

    func testRSSIBarBelowMinClamped() {
        // -120 dBm (below -100): clamped to -100 = all empty
        let bar = CommandRouter.rssiBar(-120)
        XCTAssertEqual(bar, "░░░░░░░░")
    }

    func testRSSIBarMidRange() {
        // -65 dBm: ratio = (35/70) = 0.5 => 4 filled, 4 empty
        let bar = CommandRouter.rssiBar(-65)
        XCTAssertEqual(bar, "████░░░░")
    }

    func testRSSIBarQuarterSignal() {
        // -82.5 dBm -> ratio = (17.5/70) = 0.25 => 2 filled, 6 empty
        let bar = CommandRouter.rssiBar(-83)
        XCTAssertEqual(bar, "██░░░░░░")
    }

    func testRSSIBarCustomWidth4() {
        let bar = CommandRouter.rssiBar(-65, width: 4)
        XCTAssertEqual(bar.count, 4)
        XCTAssertEqual(bar, "██░░")
    }

    func testRSSIBarCustomWidth1Max() {
        let bar = CommandRouter.rssiBar(-30, width: 1)
        XCTAssertEqual(bar, "█")
    }

    func testRSSIBarCustomWidth1Min() {
        let bar = CommandRouter.rssiBar(-100, width: 1)
        XCTAssertEqual(bar, "░")
    }

    func testRSSIBarLengthIsAlwaysWidth() {
        for rssi in stride(from: -100, through: -30, by: 5) {
            let bar = CommandRouter.rssiBar(rssi, width: 8)
            // Count in terms of Unicode scalars since these are multi-byte chars
            let filledCount = bar.unicodeScalars.filter { $0.value == 0x2588 }.count
            let emptyCount = bar.unicodeScalars.filter { $0.value == 0x2591 }.count
            XCTAssertEqual(filledCount + emptyCount, 8, "Bar width wrong for RSSI \(rssi): \(bar)")
        }
    }

    func testRSSIBarFilledPlusEmptyEqualsWidth() {
        let bar = CommandRouter.rssiBar(-65, width: 10)
        let total = bar.unicodeScalars.filter { $0.value == 0x2588 || $0.value == 0x2591 }.count
        XCTAssertEqual(total, 10)
    }
}

final class SplitFieldPartTests: XCTestCase {

    // MARK: - Simple "Label: value" patterns

    func testSimpleFieldPart() {
        let lv = CommandRouter.splitFieldPart("Battery Level: 85")
        XCTAssertEqual(lv.label, "Battery Level")
        XCTAssertEqual(lv.value, "85")
    }

    func testNumericValue() {
        let lv = CommandRouter.splitFieldPart("Heart Rate: 72")
        XCTAssertEqual(lv.label, "Heart Rate")
        XCTAssertEqual(lv.value, "72")
    }

    func testStringValue() {
        let lv = CommandRouter.splitFieldPart("Name: Apple Inc.")
        XCTAssertEqual(lv.label, "Name")
        XCTAssertEqual(lv.value, "Apple Inc.")
    }

    // MARK: - Dot-separated names (struct inlining)

    func testDotSeparatedNameTakesLastComponent() {
        let lv = CommandRouter.splitFieldPart("Date Time.Year: 2026")
        XCTAssertEqual(lv.label, "Year")
        XCTAssertEqual(lv.value, "2026")
    }

    func testMultipleDotsTakesLastComponent() {
        let lv = CommandRouter.splitFieldPart("Outer.Middle.Leaf: 42")
        XCTAssertEqual(lv.label, "Leaf")
        XCTAssertEqual(lv.value, "42")
    }

    func testSingleDotComponent() {
        let lv = CommandRouter.splitFieldPart("Parent.Child: hello")
        XCTAssertEqual(lv.label, "Child")
        XCTAssertEqual(lv.value, "hello")
    }

    // MARK: - Edge cases

    func testNoColonReturnsEmptyLabelAndFullString() {
        let lv = CommandRouter.splitFieldPart("NoColonHere")
        XCTAssertEqual(lv.label, "")
        XCTAssertEqual(lv.value, "NoColonHere")
    }

    func testColonInValuePreserved() {
        let lv = CommandRouter.splitFieldPart("URL: http://example.com:8080")
        XCTAssertEqual(lv.label, "URL")
        XCTAssertEqual(lv.value, "http://example.com:8080")
    }

    func testEmptyValue() {
        let lv = CommandRouter.splitFieldPart("Flags: ")
        XCTAssertEqual(lv.label, "Flags")
        XCTAssertEqual(lv.value, "")
    }

    func testHexValue() {
        let lv = CommandRouter.splitFieldPart("Flags: 0x0A")
        XCTAssertEqual(lv.label, "Flags")
        XCTAssertEqual(lv.value, "0x0A")
    }

    func testLabelWithWhitespaceIsTrimmed() {
        let lv = CommandRouter.splitFieldPart("A. B: value")
        XCTAssertEqual(lv.label, "B")
    }
}
