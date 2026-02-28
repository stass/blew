import XCTest
@testable import blew

final class BLENamesTests: XCTestCase {

    // MARK: - shortUUID

    func testShortUUIDFourCharLowercase() {
        XCTAssertEqual(BLENames.shortUUID("180f"), "180F")
    }

    func testShortUUIDFourCharUppercase() {
        XCTAssertEqual(BLENames.shortUUID("180F"), "180F")
    }

    func testShortUUID2A19() {
        XCTAssertEqual(BLENames.shortUUID("2A19"), "2A19")
    }

    func testShortUUIDEightCharForm() {
        // 32-bit form: last 4 chars are the significant 16-bit part
        XCTAssertEqual(BLENames.shortUUID("0000180F"), "180F")
    }

    func testShortUUIDEightCharFormLowercase() {
        XCTAssertEqual(BLENames.shortUUID("0000180f"), "180F")
    }

    func testShortUUIDFullBluetoothBaseUUID() {
        XCTAssertEqual(BLENames.shortUUID("0000180F-0000-1000-8000-00805F9B34FB"), "180F")
    }

    func testShortUUIDFullBluetoothBaseUUIDLowercase() {
        XCTAssertEqual(BLENames.shortUUID("0000180f-0000-1000-8000-00805f9b34fb"), "180F")
    }

    func testShortUUIDCustom128BitReturnsNil() {
        // Not using Bluetooth Base UUID suffix
        XCTAssertNil(BLENames.shortUUID("12345678-1234-1234-1234-123456789ABC"))
    }

    func testShortUUIDInvalidLengthReturnsNil() {
        XCTAssertNil(BLENames.shortUUID("180"))   // 3 chars
        XCTAssertNil(BLENames.shortUUID("180FF"))  // 5 chars
        XCTAssertNil(BLENames.shortUUID(""))
    }

    func testShortUUIDNonHexFourCharReturnsNil() {
        // The check is allSatisfy isHexDigit; "ZZZZ" won't pass
        XCTAssertNil(BLENames.shortUUID("ZZZZ"))
    }

    // MARK: - name(for:category:)

    func testNameForKnownService() {
        // 180F = Battery Service
        let name = BLENames.name(for: "180F", category: .service)
        XCTAssertEqual(name, "Battery Service")
    }

    func testNameForKnownServiceLowercase() {
        let name = BLENames.name(for: "180f", category: .service)
        XCTAssertEqual(name, "Battery Service")
    }

    func testNameForKnownServiceFullUUID() {
        let name = BLENames.name(for: "0000180F-0000-1000-8000-00805F9B34FB", category: .service)
        XCTAssertEqual(name, "Battery Service")
    }

    func testNameForKnownCharacteristic() {
        // 2A19 = Battery Level
        let name = BLENames.name(for: "2A19", category: .characteristic)
        XCTAssertEqual(name, "Battery Level")
    }

    func testNameForKnownDescriptor() {
        // 2902 = Client Characteristic Configuration
        let name = BLENames.name(for: "2902", category: .descriptor)
        XCTAssertEqual(name, "Client Characteristic Configuration")
    }

    func testNameForUnknownUUIDReturnsNil() {
        XCTAssertNil(BLENames.name(for: "FFFF", category: .service))
    }

    func testNameForCustomUUIDReturnsNil() {
        XCTAssertNil(BLENames.name(for: "12345678-1234-1234-1234-123456789ABC", category: .characteristic))
    }

    func testNameWrongCategoryReturnsNil() {
        // 180F is a service UUID, not a characteristic
        let name = BLENames.name(for: "180F", category: .characteristic)
        XCTAssertNil(name)
    }

    func testNameForDeviceInformation() {
        let name = BLENames.name(for: "180A", category: .service)
        XCTAssertEqual(name, "Device Information")
    }

    func testNameForManufacturerNameString() {
        // 2A29 = Manufacturer Name String
        let name = BLENames.name(for: "2A29", category: .characteristic)
        XCTAssertEqual(name, "Manufacturer Name String")
    }

    // MARK: - displayUUID

    func testDisplayUUIDKnownService() {
        let display = BLENames.displayUUID("180F", category: .service)
        XCTAssertEqual(display, "180F (Battery Service)")
    }

    func testDisplayUUIDKnownCharacteristic() {
        let display = BLENames.displayUUID("2A19", category: .characteristic)
        XCTAssertEqual(display, "2A19 (Battery Level)")
    }

    func testDisplayUUIDUnknownReturnsRaw() {
        let uuid = "FFFF"
        XCTAssertEqual(BLENames.displayUUID(uuid, category: .service), uuid)
    }

    func testDisplayUUIDCustomUUIDReturnsRaw() {
        let uuid = "12345678-1234-1234-1234-123456789ABC"
        XCTAssertEqual(BLENames.displayUUID(uuid, category: .characteristic), uuid)
    }

    func testDisplayUUIDPreservesOriginalCasing() {
        // displayUUID uses the original uuid string, not the normalized form
        let display = BLENames.displayUUID("180f", category: .service)
        XCTAssertEqual(display, "180f (Battery Service)")
    }
}
