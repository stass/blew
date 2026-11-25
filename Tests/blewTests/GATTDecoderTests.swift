import XCTest
@testable import blew

final class GATTDecoderTests: XCTestCase {

    // MARK: - info(for:)

    func testInfoForBatteryLevelReturnsEntry() {
        let info = GATTDecoder.info(for: "2A19")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.uuid, "2A19")
        XCTAssertEqual(info?.name, "Battery Level")
        XCTAssertFalse(info?.description.isEmpty ?? true)
        XCTAssertFalse(info?.fields.isEmpty ?? true)
    }

    func testInfoForHeartRateMeasurement() {
        let info = GATTDecoder.info(for: "2A37")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.name, "Heart Rate Measurement")
        // Heart Rate Measurement has multiple fields including conditional ones
        XCTAssertGreaterThan(info?.fields.count ?? 0, 1)
    }

    func testInfoForUnknownUUIDReturnsNil() {
        XCTAssertNil(GATTDecoder.info(for: "ZZZZ"))
    }

    func testInfoForNonSIGUUIDReturnsNil() {
        XCTAssertNil(GATTDecoder.info(for: "12345678-1234-1234-1234-123456789ABC"))
    }

    func testInfoForLowercaseUUID() {
        let info = GATTDecoder.info(for: "2a19")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.name, "Battery Level")
    }

    func testInfoForFullBluetoothBaseUUID() {
        // 0000 2A19 -0000-1000-8000-00805F9B34FB
        let info = GATTDecoder.info(for: "00002A19-0000-1000-8000-00805F9B34FB")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.name, "Battery Level")
    }

    func testInfoFieldsHaveNames() {
        let info = GATTDecoder.info(for: "2A19")
        guard let fields = info?.fields else { return XCTFail("No info") }
        for field in fields {
            XCTAssertFalse(field.name.isEmpty, "Field has empty name")
            XCTAssertFalse(field.typeName.isEmpty, "Field has empty typeName")
        }
    }

    func testInfoConditionalFieldDescription() {
        let info = GATTDecoder.info(for: "2A37")
        guard let fields = info?.fields else { return XCTFail("No info") }
        // Heart Rate Measurement has conditional fields
        let conditionals = fields.filter { $0.conditionDescription != nil }
        XCTAssertFalse(conditionals.isEmpty, "Expected at least one conditional field")
    }

    func testInfoAlwaysPresentFieldHasNilCondition() {
        let info = GATTDecoder.info(for: "2A19")
        guard let fields = info?.fields else { return XCTFail("No info") }
        // Battery Level has one field, always present
        XCTAssertTrue(fields.allSatisfy { $0.conditionDescription == nil })
    }

    // MARK: - FieldInfo.sizeDescription helpers

    func testInfoSizeDescriptionSingleByte() {
        let info = GATTDecoder.info(for: "2A19")
        guard let fields = info?.fields else { return XCTFail("No info") }
        XCTAssertEqual(fields[0].sizeDescription, "1 byte")
    }

    func testInfoSizeDescriptionTwoBytes() throws {
        // 2A8D = Heart Rate Max — uint8 (1 byte), but let's find a uint16 char
        // 2A1C = Temperature Measurement has uint16 mantissa in FLOAT
        // Use 2A6E (Temperature) which is sint16
        let info = GATTDecoder.info(for: "2A6E")
        guard let fields = info?.fields else {
            throw XCTSkip("2A6E not in DB")
        }
        let twoByteField = fields.first { $0.sizeDescription == "2 bytes" }
        XCTAssertNotNil(twoByteField)
    }

    // MARK: - decode(_:uuid:)

    func testDecodeBatteryLevel() throws {
        // Battery Level 2A19: single uint8 field
        let data = Data([85])
        let result = try GATTDecoder.decode(data, uuid: "2A19")
        XCTAssertEqual(result, "85")
    }

    func testDecodeBatteryLevelMax() {
        let data = Data([100])
        XCTAssertEqual(try GATTDecoder.decode(data, uuid: "2A19"), "100")
    }

    func testDecodeBatteryLevelZero() {
        let data = Data([0])
        XCTAssertEqual(try GATTDecoder.decode(data, uuid: "2A19"), "0")
    }

    func testDecodeUnknownUUIDReturnsNil() {
        let data = Data([0x01, 0x02])
        XCTAssertNil(try GATTDecoder.decode(data, uuid: "FFFF"))
    }

    func testDecodeCustomUUIDReturnsNil() {
        let data = Data([0x01])
        XCTAssertNil(try GATTDecoder.decode(data, uuid: "12345678-1234-1234-1234-123456789ABC"))
    }

    func testDecodeHeartRateMeasurementSingleByte() throws {
        // Heart Rate Measurement: flag byte 0x00 (HR value 8-bit) + HR value uint8
        // Flags = 0x00 → bit 0 = 0 → 8-bit HR value
        let data = Data([0x00, 72])  // Flags=0, HR=72
        let result = try GATTDecoder.decode(data, uuid: "2A37")
        XCTAssertNotNil(result)
        // Result should contain "72" somewhere
        XCTAssertTrue(result?.contains("72") ?? false, "Expected 72 in result: \(result ?? "nil")")
    }

    func testDecodeHeartRateMeasurementConditionalFieldAbsent() throws {
        // Flags = 0x00 → Energy Expended (bit 3) absent, RR-interval (bit 4) absent
        let data = Data([0x00, 80])
        let result = try GATTDecoder.decode(data, uuid: "2A37")
        // Should not contain "Energy" or similar multi-field separator
        XCTAssertNotNil(result)
    }

    func testDecodeMultiFieldCharReturnsBarSeparated() throws {
        // Heart Rate with Energy Expended: flags bit 3 set
        // Flags = 0x08 (bit 3 set) → HR 8-bit present + Energy Expended uint16 present
        let flags: UInt8 = 0x08
        let hr: UInt8 = 65
        var energy: UInt16 = 1000
        let energyData = withUnsafeBytes(of: &energy) { Data($0) }
        let data = Data([flags, hr]) + energyData
        let result = try GATTDecoder.decode(data, uuid: "2A37")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("|") ?? false, "Expected '|' separator in multi-field result: \(result ?? "nil")")
    }

    func testDecodeEmptyDataForSingleFieldReturnsNil() throws {
        // Empty data for Battery Level: no field can be parsed → empty parts → nil
        let result = try GATTDecoder.decode(Data(), uuid: "2A19")
        XCTAssertNil(result)
    }

    func testDecodeManufacturerNameString() throws {
        // 2A29 = Manufacturer Name String (utf8s)
        let data = "Apple Inc.".data(using: .utf8)!
        let result = try GATTDecoder.decode(data, uuid: "2A29")
        XCTAssertEqual(result, "Apple Inc.")
    }

    // MARK: - Conditional fields

    func testDecodeBatteryLevelStatusSkipsFieldsItsFlagsClear() {
        // 2BED Battery Level Status: Flags 0x06 selects Battery Level (bit 1)
        // and Additional Status (bit 2) but not Identifier (bit 0).
        let data = Data([0x06, 0x00, 0x00, 0x50, 0x01])
        XCTAssertEqual(
            try GATTDecoder.decode(data, uuid: "2BED"),
            "Flags: 0x06 | Power State: 0x0000 | Battery Level: 80 | Additional Status: 0x01")
    }

    func testDecodeFieldSelectedByValue() {
        // 2B4D High Intensity Exercise Threshold: Field Selector 3 selects
        // the Percentage of Maximum Heart Rate field.
        XCTAssertEqual(
            try GATTDecoder.decode(Data([0x03, 90]), uuid: "2B4D"),
            "Field Selector: 3 | Threshold as Percentage of Maximum Heart Rate: 90")
    }

    func testDecodeFieldPresentIfValueIsNotZero() {
        // 2C27 Recipe Parameters: Cooking Process Type 0 leaves out Duration;
        // Flags bit 3 alone selects Temperature but not Temperature Gradient.
        let data = Data([0x08, 0x00, 0x01, 0x00, 0x00, 0xC8, 0x00])
        XCTAssertEqual(
            try GATTDecoder.decode(data, uuid: "2C27"),
            "Flags: 0x0008 | Cooking Step Index: 1 | Cooking Process Type: 0"
                + " | Temperature.Temperature: 20.0 degree Celsius")
    }

    func testDecodeFieldPresentIfTwoBitsSet() {
        // 2C27 Recipe Parameters: Temperature Gradient needs bits 3 and 4.
        let data = Data([0x18, 0x00, 0x01, 0x00, 0x00, 0xC8, 0x00, 0x05])
        XCTAssertEqual(
            try GATTDecoder.decode(data, uuid: "2C27"),
            "Flags: 0x0018 | Cooking Step Index: 1 | Cooking Process Type: 0"
                + " | Temperature.Temperature: 20.0 degree Celsius | Temperature Gradient: 5")
    }

    func testInfoDescribesEveryConditionKind() throws {
        func condition(_ uuid: String, _ field: String) throws -> String? {
            let info = try XCTUnwrap(GATTDecoder.info(for: uuid))
            return try XCTUnwrap(info.fields.first { $0.name == field }).conditionDescription
        }
        XCTAssertEqual(try condition("2BED", "Identifier"), "present if bit 0 of Flags is 1")
        XCTAssertEqual(try condition("2C27", "Temperature Gradient"),
                       "present if bit 3 of Flags is 1 and bit 4 of Flags is 1")
        XCTAssertEqual(try condition("2C27", "Duration"), "present if Cooking Process Type is not 0")
        XCTAssertEqual(try condition("2B4D", "Threshold as Heart Rate"), "present if Field Selector is 4")
        XCTAssertEqual(try condition("2AA9", "E2E-CRC"),
                       "present if E2E-CRC Supported bit in CGM Feature characteristic is set to 1")
        XCTAssertEqual(try condition("2B36", "E2E-CRC"),
                       "present if the service using this characteristic defines it")
        XCTAssertEqual(try condition("2C27", "Cooking Step Index"), nil)
    }

    /// The JSON object of one field of `gatt info`, as FieldInfo encodes it.
    private func fieldJSON(_ uuid: String, _ field: String) throws -> NSDictionary {
        let info = try XCTUnwrap(GATTDecoder.info(for: uuid))
        let fieldInfo = try XCTUnwrap(info.fields.first { $0.name == field })
        let data = try JSONEncoder().encode(fieldInfo)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testInfoJSONEncodesEveryConditionKind() throws {
        func condition(_ uuid: String, _ field: String) throws -> NSDictionary? {
            try fieldJSON(uuid, field)["condition"] as? NSDictionary
        }
        XCTAssertEqual(try condition("2BED", "Identifier"),
                       ["kind": "bit", "field": "Flags", "bit": 0, "value": 1])
        XCTAssertEqual(try condition("2C27", "Temperature Gradient"),
                       ["kind": "allOf", "conditions": [
                           ["kind": "bit", "field": "Flags", "bit": 3, "value": 1],
                           ["kind": "bit", "field": "Flags", "bit": 4, "value": 1],
                       ]])
        XCTAssertEqual(try condition("2B4D", "Threshold as Heart Rate"),
                       ["kind": "equals", "field": "Field Selector", "value": 4])
        XCTAssertEqual(try condition("2C27", "Duration"),
                       ["kind": "notEquals", "field": "Cooking Process Type", "value": 0])
        XCTAssertEqual(try condition("2AA9", "E2E-CRC"),
                       ["kind": "external",
                        "description": "E2E-CRC Supported bit in CGM Feature characteristic is set to 1"])
    }

    func testInfoJSONKeepsConditionDescriptionBesideCondition() throws {
        let json = try fieldJSON("2C27", "Temperature Gradient")
        XCTAssertEqual(json["conditionDescription"] as? String,
                       "present if bit 3 of Flags is 1 and bit 4 of Flags is 1")
    }

    func testInfoJSONOmitsConditionForUnconditionalField() throws {
        let json = try fieldJSON("2C27", "Cooking Step Index")
        XCTAssertEqual(Set(json.allKeys.compactMap { $0 as? String }),
                       ["name", "typeName", "sizeDescription"])
    }

    func testInfoJSONConditionRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (uuid, field) in [("2C27", "Temperature Gradient"), ("2AA9", "E2E-CRC"),
                              ("2C27", "Duration"), ("2C27", "Cooking Step Index")] {
            let info = try XCTUnwrap(GATTDecoder.info(for: uuid))
            let original = try XCTUnwrap(info.fields.first { $0.name == field })
            let data = try encoder.encode(original)
            let decoded = try JSONDecoder().decode(GATTDecoder.FieldInfo.self, from: data)
            XCTAssertEqual(try encoder.encode(decoded), data, "\(uuid) \(field)")
        }
    }

    func testInfoJSONRejectsUnknownConditionKind() {
        let json = #"{"name":"X","typeName":"uint8","sizeDescription":"1 byte","condition":{"kind":"anyOf","conditions":[]}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(GATTDecoder.FieldInfo.self, from: Data(json.utf8)))
    }

    // MARK: - SFLOAT and FLOAT (IEEE 11073-20601)

    private func sfloat(_ raw: UInt16) -> String {
        GATTDecoder.decodeMedfloat16(Data([UInt8(raw & 0xFF), UInt8(raw >> 8)]))
    }

    private func float(_ raw: UInt32) -> String {
        GATTDecoder.decodeMedfloat32(Data((0..<4).map { UInt8((raw >> ($0 * 8)) & 0xFF) }))
    }

    func testSFLOATSpecialValuesNeedExponentZero() {
        XCTAssertEqual(sfloat(0x07FF), "NaN")
        XCTAssertEqual(sfloat(0x0800), "NRes")
        XCTAssertEqual(sfloat(0x07FE), "+Inf")
        XCTAssertEqual(sfloat(0x0802), "-Inf")
        XCTAssertEqual(sfloat(0x0801), "Reserved")
        // The same mantissas with a nonzero exponent are ordinary numbers.
        XCTAssertEqual(sfloat(0x17FF), "20470")
        XCTAssertEqual(sfloat(0xF7FE), "204.6")
        XCTAssertEqual(sfloat(0x1800), "-20480")
        XCTAssertEqual(sfloat(0x1801), "-20470")
    }

    func testFLOATSpecialValuesNeedExponentZero() {
        XCTAssertEqual(float(0x007F_FFFF), "NaN")
        XCTAssertEqual(float(0x0080_0000), "NRes")
        XCTAssertEqual(float(0x007F_FFFE), "+Inf")
        XCTAssertEqual(float(0x0080_0002), "-Inf")
        XCTAssertEqual(float(0x0080_0001), "Reserved")
        XCTAssertEqual(float(0x017F_FFFF), "83886070")
        XCTAssertEqual(float(0xFF7F_FFFE), "838860.6")
    }

    // MARK: - GATTDecoder.info: manufacturer name is utf8

    func testInfoManufacturerNameFieldType() {
        let info = GATTDecoder.info(for: "2A29")
        XCTAssertNotNil(info)
        guard let field = info?.fields.first else { return XCTFail("No fields") }
        XCTAssertEqual(field.typeName, "utf8")
    }

    // MARK: - Various known characteristics

    func testInfoModelNumberString() {
        let info = GATTDecoder.info(for: "2A24")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.name, "Model Number String")
    }

    func testInfoFirmwareRevisionString() {
        // 2A26 = Firmware Revision String, a well-known device info characteristic
        let info = GATTDecoder.info(for: "2A26")
        XCTAssertNotNil(info)
    }

    // MARK: - Scale and unit (GSS "Represented values")

    /// temperature.yaml: sint16, base unit degree_celsius, M = 1, d = -2, b = 0.
    func testDecodeTemperatureAppliesDecimalExponentAndUnit() {
        XCTAssertEqual(try GATTDecoder.decode(Data([0x24, 0x09]), uuid: "2A6E"), "23.40 degree Celsius")
        XCTAssertEqual(try GATTDecoder.decode(Data([0xFB, 0xFF]), uuid: "2A6E"), "-0.05 degree Celsius")
        XCTAssertEqual(try GATTDecoder.decode(Data([0x00, 0x00]), uuid: "2A6E"), "0.00 degree Celsius")
    }

    /// humidity.yaml: uint16, base unit percentage, M = 1, d = -2, b = 0.
    func testDecodeHumidityAppliesDecimalExponentAndUnit() {
        XCTAssertEqual(try GATTDecoder.decode(Data([0xB4, 0x16]), uuid: "2A6F"), "58.12 percentage")
    }

    /// pressure.yaml: uint32, base unit pascal, M = 1, d = -1, b = 0.
    func testDecodePressureAppliesDecimalExponentAndUnit() {
        XCTAssertEqual(try GATTDecoder.decode(Data([0x02, 0x76, 0x0F, 0x00]), uuid: "2A6D"), "101325.0 pascal")
    }

    /// percentage_8.yaml (uint8, unit percentage) and temperature_8.yaml
    /// (sint8, unit degree_celsius): M = 1, d = 0, b = -1;
    /// chromaticity_coordinate.yaml (uint16, unit only in prose): b = -16.
    /// A binary exponent of -k prints ceil(k * log10 2) places, the places
    /// its resolution 2^-k supports: 1 for b = -1, 5 for b = -16
    /// (0x8000 / 65536 is 0.5).
    func testDecodeAppliesBinaryExponentToItsResolution() {
        XCTAssertEqual(try GATTDecoder.decode(Data([201]), uuid: "2B04"), "100.5 percentage")
        XCTAssertEqual(try GATTDecoder.decode(Data([0xFD]), uuid: "2B0D"), "-1.5 degree Celsius")
        XCTAssertEqual(try GATTDecoder.decode(Data([0x00, 0x80]), uuid: "2B1C"), "0.50000")
    }

    /// A value with more places than its resolution supports is rounded
    /// half away from zero, in integer arithmetic.
    func testScaledRoundsBinaryExponentsHalfAwayFromZero() {
        typealias Scale = GATTCharacteristicDB.Scale
        let chromaticity = Scale(multiplier: 1, decimalExponent: 0, binaryExponent: -16)
        // 1024 / 65536 = 0.015625, a tie at 5 places.
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 1024, by: chromaticity), "0.01563")
        XCTAssertEqual(GATTDecoder.scaled(negative: true, magnitude: 1024, by: chromaticity), "-0.01563")
        // 1 / 65536 = 0.0000152587890625; 65535 / 65536 = 0.9999847412109375.
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 1, by: chromaticity), "0.00002")
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 65535, by: chromaticity), "0.99998")
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 0, by: chromaticity), "0.00000")
        // b = -3: 1 place; 1/8 = 0.125 rounds down, 3/8 = 0.375 up.
        let eighths = Scale(multiplier: 1, decimalExponent: 0, binaryExponent: -3)
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 1, by: eighths), "0.1")
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 3, by: eighths), "0.4")
        // d and b together: 201 * 10^-2 * 2^-1 = 1.005 at 2 + 1 places;
        // 7 * 10^-1 * 2^-3 = 0.0875 at 1 + 1 places.
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 201,
                                          by: Scale(multiplier: 1, decimalExponent: -2, binaryExponent: -1)), "1.005")
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 7,
                                          by: Scale(multiplier: 1, decimalExponent: -1, binaryExponent: -3)), "0.09")
    }

    /// temperature.yaml:49 and humidity.yaml:49: "A value of 0x8000 (0xFFFF)
    /// represents "value is not known"", shown as that text, not as
    /// -327.68 or 655.35.
    func testDecodeSpecialValueShowsItsMeaning() {
        XCTAssertEqual(try GATTDecoder.decode(Data([0x00, 0x80]), uuid: "2A6E"), "value is not known")
        XCTAssertEqual(try GATTDecoder.decode(Data([0xFF, 0xFF]), uuid: "2A6F"), "value is not known")
        // time_accuracy.yaml (b = -3, second): "A value of 255 means drift is
        // unknown", a decimal special value; 253 is a number.
        XCTAssertEqual(try GATTDecoder.decode(Data([0xFF]), uuid: "2A12"), "drift is unknown")
        // 253 / 8 = 31.625, at the 1 place b = -3 supports.
        XCTAssertEqual(try GATTDecoder.decode(Data([0xFD]), uuid: "2A12"), "31.6 second")
        // high_voltage.yaml is in CONTRADICTED_SCALES but keeps its special value.
        XCTAssertEqual(try GATTDecoder.decode(Data([0xFF, 0xFF, 0xFF]), uuid: "2BE0"), "value is not known")
    }

    /// elevation.yaml: sint24, M = 1, d = -2, b = 0. Its unit,
    /// `length.meter`, is not an assigned unit, so none is shown.
    func testDecodeSint24AppliesScale() {
        XCTAssertEqual(try GATTDecoder.decode(Data([0xF4, 0x01, 0x00]), uuid: "2A6C"), "5.00")
        XCTAssertEqual(try GATTDecoder.decode(Data([0x0C, 0xFE, 0xFF]), uuid: "2A6C"), "-5.00")
    }

    /// The GSS states no negative multiplier or positive exponent on a field
    /// blew can test through `decode`, so these go to `scaled` directly.
    func testScaledHandlesNegativeMultiplierAndPositiveExponents() {
        typealias Scale = GATTCharacteristicDB.Scale
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 7,
                                          by: Scale(multiplier: -2, decimalExponent: 3, binaryExponent: 0)), "-14000")
        XCTAssertEqual(GATTDecoder.scaled(negative: true, magnitude: 7,
                                          by: Scale(multiplier: -2, decimalExponent: -1, binaryExponent: 0)), "1.4")
        XCTAssertEqual(GATTDecoder.scaled(negative: false, magnitude: 3,
                                          by: Scale(multiplier: 1, decimalExponent: 0, binaryExponent: 6)), "192")
        XCTAssertEqual(GATTDecoder.scaled(negative: true, magnitude: 0,
                                          by: Scale(multiplier: 1, decimalExponent: 2, binaryExponent: 0)), "0")
        XCTAssertNil(GATTDecoder.scaled(negative: false, magnitude: UInt64.max,
                                        by: Scale(multiplier: 2, decimalExponent: 0, binaryExponent: 0)))
    }

    /// battery_level.yaml names the base unit percentage but no scale, so the
    /// raw value is shown alone.
    func testDecodeFieldWithoutScaleShowsRawValueAlone() {
        XCTAssertEqual(try GATTDecoder.decode(Data([0x64]), uuid: "2A19"), "100")
    }

    /// high_voltage.yaml states b = 6 but "a resolution of 1/64V", so the
    /// generator lists it in CONTRADICTED_SCALES and the raw value is shown.
    func testDecodeContradictedScaleShowsRawValue() {
        XCTAssertEqual(try GATTDecoder.decode(Data([0x02, 0x00, 0x00]), uuid: "2BE0"), "2")
    }

    /// blood_pressure_measurement.yaml: the mmHg SFLOATs name their unit;
    /// the kPa ones state the base unit pascal with d = 3, which blew does
    /// not apply to a float, so they get no unit.
    func testDecodeFloatUnitOnlyWithoutScale() {
        // Flags 0x00 (mmHg): 120, 80, 93.
        let mmHg = Data([0x00, 0x78, 0x00, 0x50, 0x00, 0x5D, 0x00])
        XCTAssertEqual(try GATTDecoder.decode(mmHg, uuid: "2A35"),
                       "Flags: 0x00"
                       + " | Blood Pressure Measurement Compound Value - Systolic (mmHg): 120 millimetre of mercury"
                       + " | Blood Pressure Measurement Compound Value - Diastolic (mmHg): 80 millimetre of mercury"
                       + " | Blood Pressure Measurement Compound Value - Mean Arterial Pressure (mmHg): 93 millimetre of mercury")
        // Flags 0x01 (kPa): 16, 10.6 (mantissa 106, exponent -1), 12.
        let kPa = Data([0x01, 0x10, 0x00, 0x6A, 0xF0, 0x0C, 0x00])
        XCTAssertEqual(try GATTDecoder.decode(kPa, uuid: "2A35"),
                       "Flags: 0x01"
                       + " | Blood Pressure Measurement Compound Value - Systolic (kPa): 16"
                       + " | Blood Pressure Measurement Compound Value - Diastolic (kPa): 10.6"
                       + " | Blood Pressure Measurement Compound Value - Mean Arterial Pressure (kPa): 12")
    }

    func testInfoJSONEncodesScaleAndUnit() throws {
        let json = try fieldJSON("2A6E", "Temperature")
        XCTAssertEqual(json["scale"] as? NSDictionary,
                       ["multiplier": 1, "decimalExponent": -2, "binaryExponent": 0])
        XCTAssertEqual(json["unit"] as? String, "org.bluetooth.unit.thermodynamic_temperature.degree_celsius")
        let raw = try fieldJSON("2A19", "Battery Level")
        XCTAssertNil(raw["scale"])
        XCTAssertNil(raw["unit"])
    }

    func testInfoJSONScaleAndUnitRoundTrip() throws {
        let info = try XCTUnwrap(GATTDecoder.info(for: "2A6E")?.fields.first)
        let decoded = try JSONDecoder().decode(GATTDecoder.FieldInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded.scale, info.scale)
        XCTAssertEqual(decoded.unit, info.unit)
    }

    func testDecodeCurrentTimeCharacteristic() {
        // 2A2B = Current Time, has a complex multi-field structure
        let info = GATTDecoder.info(for: "2A2B")
        XCTAssertNotNil(info)
        XCTAssertGreaterThan(info?.fields.count ?? 0, 1)
    }

    // MARK: - utf8s fields

    /// A utf8s field is text by the strict UTF-8 check of `read -f utf8`
    /// (`DataFormatter.format(_:as: .utf8)`): every byte is kept, a leading
    /// byte-order mark included.
    func testUTF8FieldKeepsLeadingByteOrderMark() {
        XCTAssertEqual(CommandRouter.listedValue(Data([0xEF, 0xBB, 0xBF, 0x41]), uuid: "2A29", format: nil),
                       .value("\u{FEFF}A"))
    }

    /// Invalid UTF-8 is an error in the value's place, never its hex shown
    /// as the text.
    func testInvalidUTF8FieldFailsInsteadOfShowingHex() {
        XCTAssertEqual(CommandRouter.listedValue(Data([0xFF, 0xFE]), uuid: "2A29", format: nil),
                       .failed("not valid UTF-8"))
    }

    func testValidUTF8FieldIsTheText() {
        XCTAssertEqual(CommandRouter.listedValue(Data("Nordic Semiconductor".utf8), uuid: "2A29", format: nil),
                       .value("Nordic Semiconductor"))
    }

    /// The text is one field's value: a field separator in it does not make
    /// more fields.
    func testFieldSeparatorInTextStaysInTheValue() {
        XCTAssertEqual(CommandRouter.listedValue(Data("Acme | Serial: 1".utf8), uuid: "2A29", format: nil),
                       .value("Acme | Serial: 1"))
        // New Alert: Category ID 1, 2 new alerts, then the text.
        XCTAssertEqual(CommandRouter.listedValue(Data([0x01, 0x02]) + Data("a | b: c".utf8), uuid: "2A46", format: nil),
                       .fields([LabeledValue(label: "Category ID", value: "1"),
                                LabeledValue(label: "Number of New Alert", value: "2"),
                                LabeledValue(label: "Text String Information", value: "a | b: c")]))
    }

    /// A multi-field value with an invalid text field fails as a whole,
    /// naming the field; the other fields are not shown as if the value
    /// were complete.
    func testInvalidUTF8InAMultiFieldValueFailsTheValue() {
        XCTAssertEqual(CommandRouter.listedValue(Data([0x01, 0x02, 0xFF]), uuid: "2A46", format: nil),
                       .failed("Text String Information: not valid UTF-8"))
    }
}
