import XCTest
import BLEManager
@testable import blew

final class CompanyIdentifierTests: XCTestCase {

    // MARK: - The generated table (Scripts/generate-ble-companies.rb)

    func testGeneratedTableNamesKnownCompanies() {
        XCTAssertEqual(CompanyIdentifier(0x004C).name, "Apple, Inc.")
        XCTAssertEqual(CompanyIdentifier(0x0059).name, "Nordic Semiconductor ASA")
        XCTAssertEqual(CompanyIdentifier(0x0000).name, "Ericsson AB")
    }

    func testGeneratedTableKeepsQuotesAndNonASCIINames() {
        XCTAssertEqual(CompanyIdentifier(0x0380).name, "LLC \"MEGA-F service\"")
        XCTAssertEqual(CompanyIdentifier(0x025C).name, "NetEase\u{FF08}Hangzhou\u{FF09}Network co.Ltd.")
    }

    func testIdentifierNotInTheTableHasNoName() {
        XCTAssertNil(CompanyIdentifier(0xFFFF).name)
    }

    func testHexIsFourUppercaseDigits() {
        XCTAssertEqual(CompanyIdentifier(0x004C).hex, "0x004C")
        XCTAssertEqual(CompanyIdentifier(0xABCD).hex, "0xABCD")
    }

    // MARK: - Parsing (-m)

    func testParsesDecimalAndHex() {
        XCTAssertEqual(CompanyIdentifier(parsing: "76"), 0x004C)
        XCTAssertEqual(CompanyIdentifier(parsing: "0"), 0)
        XCTAssertEqual(CompanyIdentifier(parsing: "65535"), 0xFFFF)
        XCTAssertEqual(CompanyIdentifier(parsing: "0x004C"), 0x004C)
        XCTAssertEqual(CompanyIdentifier(parsing: "0X4c"), 0x004C)
        XCTAssertEqual(CompanyIdentifier(parsing: "0xffff"), 0xFFFF)
        XCTAssertEqual(CompanyIdentifier(parsing: "0x0"), 0)
    }

    func testRejectsMalformedAndOutOfRangeForms() {
        for text in ["", "65536", "-1", "+76", " 76", "76 ", "4C", "0x", "0x10000", "0x0004C",
                     "0x-1", "0x+1", "0x4G", "x4C", "0b1", "١٢", "7.6"] {
            XCTAssertNil(CompanyIdentifier(parsing: text), text)
        }
    }

    // MARK: - Advertised manufacturer data

    func testManufacturerDataGivesTheLittleEndianIdentifier() {
        XCTAssertEqual(AdvertisedManufacturer(Data([0x59, 0x00, 0x01])), .company(0x0059))
        XCTAssertEqual(AdvertisedManufacturer(Data([0x4C, 0x00])), .company(0x004C))
        XCTAssertEqual(AdvertisedManufacturer(Data([0x59, 0x00, 0x01]).dropFirst()), .company(0x0100))
    }

    func testShortOrMissingDataGivesNoIdentifier() {
        XCTAssertNil(AdvertisedManufacturer(nil))
        XCTAssertEqual(AdvertisedManufacturer(Data([0x4C])), .tooShort(byteCount: 1))
        XCTAssertEqual(AdvertisedManufacturer(Data()), .tooShort(byteCount: 0))
    }

    // MARK: - Scan rows

    private func row(_ data: [UInt8]?) -> DeviceRow {
        let device = DiscoveredDevice(identifier: "ID", name: nil, rssi: -60, serviceUUIDs: [],
                                      manufacturerData: data.map { Data($0) })
        return CommandRouter.deviceRows([device])[0]
    }

    func testScanRowCarriesTheManufacturerAndNotAName() {
        let known = row([0x4C, 0x00, 0x02, 0x15])
        XCTAssertEqual(known.manufacturer, .company(0x004C))
        XCTAssertNil(known.name, "the Name column is not filled from the company")
        XCTAssertEqual(row([0x59]).manufacturer, .tooShort(byteCount: 1))
        XCTAssertNil(row(nil).manufacturer)
    }

    func testTextCellShowsIdentifierAndName() {
        XCTAssertEqual(TextRenderer.manufacturerCell(.company(0x004C)), "0x004C Apple, Inc.")
        XCTAssertEqual(TextRenderer.manufacturerCell(.company(0xFFFF)), "0xFFFF")
        XCTAssertEqual(TextRenderer.manufacturerCell(.tooShort(byteCount: 1)), "(too short: 1 byte)")
        XCTAssertEqual(TextRenderer.manufacturerCell(.tooShort(byteCount: 0)), "(too short: 0 bytes)")
        XCTAssertEqual(TextRenderer.manufacturerCell(nil), "")
    }

    private func json(_ data: [UInt8]?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try XCTUnwrap(String(data: encoder.encode(row(data)), encoding: .utf8))
    }

    func testJSONHasIdentifierAsNumberAndOmitsAbsentFields() throws {
        let known = try json([0x59, 0x00])
        XCTAssertTrue(known.contains(#""manufacturer":"Nordic Semiconductor ASA","manufacturerID":89,"#), known)
        XCTAssertFalse(known.contains("manufacturerDataLength"), known)

        let unlisted = try json([0xFF, 0xFF])
        XCTAssertTrue(unlisted.contains(#""manufacturerID":65535"#), unlisted)
        XCTAssertFalse(unlisted.contains(#""manufacturer":"#), unlisted)

        let short = try json([0x59])
        XCTAssertTrue(short.contains(#""manufacturerDataLength":1"#), short)
        XCTAssertFalse(short.contains(#""manufacturer":"#) || short.contains("manufacturerID"), short)

        XCTAssertFalse(try json(nil).contains("manufacturer"))
    }

    func testJSONRoundTripsEveryManufacturerCase() throws {
        for data: [UInt8]? in [[0x59, 0x00], [0xFF, 0xFF], [0x59], nil] {
            let original = row(data)
            let decoded = try JSONDecoder().decode(DeviceRow.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded.manufacturer, original.manufacturer, "\(String(describing: data))")
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertEqual(decoded.rssi, original.rssi)
        }
    }
}
