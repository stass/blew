import XCTest
import CoreBluetooth
@testable import BLEManager

/// Requests a characteristic's properties do not allow are refused before
/// they reach CoreBluetooth, with exit code 5.
final class CharacteristicAccessTests: XCTestCase {
    private func refusal(_ body: () throws -> Void) -> BLEError? {
        do {
            try body()
            return nil
        } catch let error as BLEError {
            XCTAssertEqual(error.exitCode, 5)
            return error
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    func testReadNeedsTheReadProperty() {
        guard case .readFailed(let message)? = refusal({ try CharacteristicAccess.checkRead([.notify], of: "2A37") }) else {
            return XCTFail("a read of a characteristic that is not readable was not refused")
        }
        XCTAssertEqual(message, "characteristic 2A37 is not readable (properties: notify)")
        XCTAssertNil(refusal { try CharacteristicAccess.checkRead([.read], of: "2A19") })
    }

    func testWriteTypeMustBeOneTheCharacteristicTakes() {
        guard case .writeFailed? = refusal({ _ = try CharacteristicAccess.writeType(.withResponse, [.writeWithoutResponse], of: "FFF1") }) else {
            return XCTFail("-r to a characteristic without write was not refused")
        }
        guard case .writeFailed? = refusal({ _ = try CharacteristicAccess.writeType(.withoutResponse, [.write], of: "FFF1") }) else {
            return XCTFail("-w to a characteristic without writeNoResp was not refused")
        }
        guard case .writeFailed(let message)? = refusal({ _ = try CharacteristicAccess.writeType(.auto, [], of: "FFF1") }) else {
            return XCTFail("a write to a characteristic that is not writable was not refused")
        }
        XCTAssertEqual(message, "characteristic FFF1 is not writable (properties: none)")
        XCTAssertEqual(try CharacteristicAccess.writeType(.auto, [.write, .writeWithoutResponse], of: "FFF1"), .withoutResponse)
        XCTAssertEqual(try CharacteristicAccess.writeType(.auto, [.write], of: "FFF1"), .withResponse)
        XCTAssertEqual(try CharacteristicAccess.writeType(.withResponse, [.write, .writeWithoutResponse], of: "FFF1"), .withResponse)
    }

    func testWriteLongerThanTheMaximumIsRefused() {
        guard case .writeFailed? = refusal({ try CharacteristicAccess.checkWriteLength(21, maximum: 20, of: "FFF1") }) else {
            return XCTFail("a value longer than one write carries was not refused")
        }
        XCTAssertNil(refusal { try CharacteristicAccess.checkWriteLength(20, maximum: 20, of: "FFF1") })
    }

    func testSubscribeNeedsNotifyOrIndicate() {
        guard case .subscribeFailed? = refusal({ try CharacteristicAccess.checkSubscribe([.read, .write], of: "2A19") }) else {
            return XCTFail("a subscribe to a characteristic that neither notifies nor indicates was not refused")
        }
        XCTAssertNil(refusal { try CharacteristicAccess.checkSubscribe([.indicate], of: "2A05") })
        XCTAssertNil(refusal { try CharacteristicAccess.checkSubscribe([.notify], of: "2A37") })
    }
}
