import XCTest
@testable import blew
import BLEManager

final class DeviceResolutionTests: XCTestCase {

    // MARK: - resolveDevice

    func testResolveDeviceExactUUIDMatch() {
        let router = routerWithDevices([
            device(id: "F3C2A1B0-1234-5678-ABCD-000000000001", name: "Thingy"),
        ])
        let result = router.resolveDevice("F3C2A1B0-1234-5678-ABCD-000000000001")
        if case .resolved(let d) = result {
            XCTAssertEqual(d.identifier, "F3C2A1B0-1234-5678-ABCD-000000000001")
        } else {
            XCTFail("Expected .resolved, got \(result)")
        }
    }

    func testResolveDeviceExactUUIDMatchCaseInsensitive() {
        let router = routerWithDevices([
            device(id: "F3C2A1B0-1234-5678-ABCD-000000000001", name: "Thingy"),
        ])
        let result = router.resolveDevice("f3c2a1b0-1234-5678-abcd-000000000001")
        if case .resolved(let d) = result {
            XCTAssertEqual(d.name, "Thingy")
        } else {
            XCTFail("Expected .resolved")
        }
    }

    func testResolveDeviceNameSubstringMatch() {
        let router = routerWithDevices([
            device(id: "AA", name: "Heart Rate Monitor"),
        ])
        let result = router.resolveDevice("Heart")
        if case .resolved(let d) = result {
            XCTAssertEqual(d.identifier, "AA")
        } else {
            XCTFail("Expected .resolved, got \(result)")
        }
    }

    func testResolveDeviceNameSubstringMatchCaseInsensitive() {
        let router = routerWithDevices([
            device(id: "AA", name: "Thingy"),
        ])
        let result = router.resolveDevice("thingy")
        if case .resolved(let d) = result {
            XCTAssertEqual(d.identifier, "AA")
        } else {
            XCTFail("Expected .resolved")
        }
    }

    func testResolveDeviceNameSubstringAmbiguous() {
        let router = routerWithDevices([
            device(id: "AA", name: "Thingy Alpha"),
            device(id: "BB", name: "Thingy Beta"),
        ])
        let result = router.resolveDevice("Thingy")
        if case .ambiguous(let matches) = result {
            XCTAssertEqual(matches.count, 2)
        } else {
            XCTFail("Expected .ambiguous, got \(result)")
        }
    }

    func testResolveDeviceUUIDSubstringMatch() {
        let router = routerWithDevices([
            device(id: "F3C2A1B0-1234-5678-ABCD-000000000001", name: nil),
        ])
        // Partial UUID without hyphens
        let result = router.resolveDevice("F3C2A1B0")
        if case .resolved(let d) = result {
            XCTAssertEqual(d.identifier, "F3C2A1B0-1234-5678-ABCD-000000000001")
        } else {
            XCTFail("Expected .resolved, got \(result)")
        }
    }

    func testResolveDeviceUUIDSubstringMatchStripsHyphens() {
        let router = routerWithDevices([
            device(id: "F3C2A1B0-1234-5678-ABCD-000000000001", name: nil),
        ])
        // Contains hyphens in input — should still match
        let result = router.resolveDevice("F3C2-A1B0")
        if case .resolved(let d) = result {
            XCTAssertEqual(d.identifier, "F3C2A1B0-1234-5678-ABCD-000000000001")
        } else {
            XCTFail("Expected .resolved, got \(result)")
        }
    }

    func testResolveDeviceNotFound() {
        let router = routerWithDevices([
            device(id: "AA", name: "Thingy"),
        ])
        if case .notFound = router.resolveDevice("ZZZZZZZZ") {
            // pass
        } else {
            XCTFail("Expected .notFound")
        }
    }

    func testResolveDeviceEmptyLastScanResults() {
        let router = routerWithDevices([])
        if case .notFound = router.resolveDevice("anything") {
            // pass
        } else {
            XCTFail("Expected .notFound")
        }
    }

    func testResolveDeviceUUIDSubstringAmbiguous() {
        let router = routerWithDevices([
            device(id: "AAAA1111-0000-0000-0000-000000000000", name: nil),
            device(id: "AAAA2222-0000-0000-0000-000000000000", name: nil),
        ])
        // "AAAA" matches both by UUID substring
        let result = router.resolveDevice("AAAA")
        if case .ambiguous(let matches) = result {
            XCTAssertEqual(matches.count, 2)
        } else {
            XCTFail("Expected .ambiguous, got \(result)")
        }
    }

    func testResolveDeviceExactUUIDTakesPriorityOverName() {
        // Both have a name, but one has an exact UUID match
        let router = routerWithDevices([
            device(id: "exact-id", name: "Thingy"),
            device(id: "other-id", name: "exact-id"),  // name == the UUID we're looking for
        ])
        let result = router.resolveDevice("exact-id")
        // Exact UUID match should come first
        if case .resolved(let d) = result {
            XCTAssertEqual(d.identifier, "exact-id")
        } else {
            XCTFail("Expected .resolved")
        }
    }

    // MARK: - resolveCharacteristic

    func testResolveCharacteristicNotFoundWhenNoKnownUUIDs() {
        // BLECentral.shared has no connection, so knownCharacteristicUUIDs() is empty
        let router = makeRouter()
        if case .notFound = router.resolveCharacteristic("2A19") {
            // pass: no known characteristics
        } else {
            XCTFail("Expected .notFound when no UUIDs are known")
        }
    }

    func testResolveCharacteristicNotFoundForBogusInput() {
        let router = makeRouter()
        if case .notFound = router.resolveCharacteristic("ZZZZZZZZ") {
            // pass
        } else {
            XCTFail("Expected .notFound")
        }
    }

    // MARK: - resolveService

    func testResolveServiceNotFoundWhenNoKnownUUIDs() {
        let router = makeRouter()
        if case .notFound = router.resolveService("180F") {
            // pass
        } else {
            XCTFail("Expected .notFound when no UUIDs are known")
        }
    }
}

// MARK: - Helpers

private func makeRouter() -> CommandRouter {
    CommandRouter(globals: makeGlobals())
}

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}

private func routerWithDevices(_ devices: [DiscoveredDevice]) -> CommandRouter {
    let router = makeRouter()
    router.lastScanResults = devices
    return router
}

private func device(id: String, name: String?) -> DiscoveredDevice {
    DiscoveredDevice(identifier: id, name: name, rssi: -60, serviceUUIDs: [], manufacturerData: nil)
}
