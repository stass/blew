import XCTest
@testable import blew
import BLEManager

final class DeviceResolutionTests: XCTestCase {

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
