#if MCP_ENABLED
import XCTest
import Foundation
import MCP
import BLEManager
@testable import blew

// MARK: - Helpers

private func makeServer() -> BlewMCPServer {
    BlewMCPServer(globals: try! GlobalOptions.parse([]))
}

private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}()

private let decoder = JSONDecoder()

// MARK: - MCPArgBuilderTests

final class MCPArgBuilderTests: XCTestCase {

    private var server: BlewMCPServer!

    override func setUp() {
        super.setUp()
        server = makeServer()
    }

    // MARK: buildTargetingArgs

    func testTargetingArgsEmptyInput() {
        XCTAssertEqual(server.buildTargetingArgs([:]), [])
    }

    func testTargetingArgsName() {
        let args: [String: Value] = ["name": .string("Foo")]
        XCTAssertEqual(server.buildTargetingArgs(args), ["-n", "Foo"])
    }

    func testTargetingArgsDeviceId() {
        let args: [String: Value] = ["device_id": .string("AABBCCDD")]
        XCTAssertEqual(server.buildTargetingArgs(args), ["-i", "AABBCCDD"])
    }

    func testTargetingArgsService() {
        let args: [String: Value] = ["service": .string("180F")]
        XCTAssertEqual(server.buildTargetingArgs(args), ["-S", "180F"])
    }

    func testTargetingArgsManufacturer() {
        let args: [String: Value] = ["manufacturer": .int(0x004C)]
        XCTAssertEqual(server.buildTargetingArgs(args), ["-m", "76"])
    }

    func testTargetingArgsRSSIMin() {
        let args: [String: Value] = ["rssi_min": .int(-70)]
        XCTAssertEqual(server.buildTargetingArgs(args), ["-R", "-70"])
    }

    func testTargetingArgsPick() {
        let args: [String: Value] = ["pick": .string("strongest")]
        XCTAssertEqual(server.buildTargetingArgs(args), ["-p", "strongest"])
    }

    func testTargetingArgsAllOptions() {
        let args: [String: Value] = [
            "name": .string("MyDevice"),
            "device_id": .string("AABB"),
            "service": .string("1809"),
            "manufacturer": .int(100),
            "rssi_min": .int(-60),
            "pick": .string("first"),
        ]
        let result = server.buildTargetingArgs(args)
        XCTAssertTrue(result.contains("-n"))
        XCTAssertTrue(result.contains("MyDevice"))
        XCTAssertTrue(result.contains("-i"))
        XCTAssertTrue(result.contains("AABB"))
        XCTAssertTrue(result.contains("-S"))
        XCTAssertTrue(result.contains("1809"))
        XCTAssertTrue(result.contains("-m"))
        XCTAssertTrue(result.contains("100"))
        XCTAssertTrue(result.contains("-R"))
        XCTAssertTrue(result.contains("-60"))
        XCTAssertTrue(result.contains("-p"))
        XCTAssertTrue(result.contains("first"))
    }

    // MARK: buildScanArgs

    func testScanArgsEmpty() {
        XCTAssertEqual(server.buildScanArgs([:]), [])
    }

    func testScanArgsDoubleTimeout() {
        let args: [String: Value] = ["timeout": .double(5.0)]
        let result = server.buildScanArgs(args)
        XCTAssertTrue(result.contains("-t"))
        XCTAssertTrue(result.contains("5.0"))
    }

    func testScanArgsIntTimeoutCoercedToDouble() {
        let args: [String: Value] = ["timeout": .int(3)]
        let result = server.buildScanArgs(args)
        XCTAssertTrue(result.contains("-t"))
        XCTAssertTrue(result.contains("3.0"))
    }

    func testScanArgsNameAndTimeout() {
        let args: [String: Value] = ["name": .string("Dev"), "timeout": .double(2.5)]
        let result = server.buildScanArgs(args)
        XCTAssertTrue(result.contains("-n"))
        XCTAssertTrue(result.contains("Dev"))
        XCTAssertTrue(result.contains("-t"))
        XCTAssertTrue(result.contains("2.5"))
    }

    // MARK: buildConnectArgs

    func testConnectArgsDeviceIdAsPositional() {
        let args: [String: Value] = ["device_id": .string("AABB-CCDD")]
        let result = server.buildConnectArgs(args)
        // device_id goes into targeting as -i
        XCTAssertTrue(result.contains("-i"))
        XCTAssertTrue(result.contains("AABB-CCDD"))
    }

    func testConnectArgsNoDeviceIdNotDuplicated() {
        let args: [String: Value] = ["name": .string("MyDev")]
        let result = server.buildConnectArgs(args)
        XCTAssertFalse(result.contains("-i"))
    }

    // MARK: buildReadArgs

    func testReadArgsCharUUID() {
        let args: [String: Value] = ["char_uuid": .string("2A19")]
        let result = server.buildReadArgs(args)
        XCTAssertTrue(result.contains("2A19"))
    }

    func testReadArgsFormat() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "format": .string("utf8")]
        let result = server.buildReadArgs(args)
        XCTAssertTrue(result.contains("-f"))
        XCTAssertTrue(result.contains("utf8"))
        XCTAssertTrue(result.contains("2A19"))
    }

    // MARK: buildWriteArgs

    func testWriteArgsBasic() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "data": .string("ff")]
        let result = server.buildWriteArgs(args)
        XCTAssertTrue(result.contains("2A19"))
        XCTAssertTrue(result.contains("ff"))
    }

    func testWriteArgsWithResponseTrue() {
        let args: [String: Value] = [
            "char_uuid": .string("2A19"),
            "data": .string("ff"),
            "with_response": .bool(true),
        ]
        let result = server.buildWriteArgs(args)
        XCTAssertTrue(result.contains("-r"))
        XCTAssertFalse(result.contains("-w"))
    }

    func testWriteArgsWithResponseFalse() {
        let args: [String: Value] = [
            "char_uuid": .string("2A19"),
            "data": .string("ff"),
            "with_response": .bool(false),
        ]
        let result = server.buildWriteArgs(args)
        XCTAssertTrue(result.contains("-w"))
        XCTAssertFalse(result.contains("-r"))
    }

    func testWriteArgsWithResponseAbsent() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "data": .string("ff")]
        let result = server.buildWriteArgs(args)
        XCTAssertFalse(result.contains("-r"))
        XCTAssertFalse(result.contains("-w"))
    }

    func testWriteArgsFormat() {
        let args: [String: Value] = [
            "char_uuid": .string("2A19"),
            "data": .string("hello"),
            "format": .string("utf8"),
        ]
        let result = server.buildWriteArgs(args)
        XCTAssertTrue(result.contains("-f"))
        XCTAssertTrue(result.contains("utf8"))
    }

    // MARK: buildSubArgs

    func testSubArgsExplicitCount() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "count": .int(5)]
        let result = server.buildSubArgs(args)
        XCTAssertTrue(result.contains("-c"))
        let idx = result.firstIndex(of: "-c")!
        XCTAssertEqual(result[result.index(after: idx)], "5")
    }

    func testSubArgsDurationOverridesDefault() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "duration": .double(3.0)]
        let result = server.buildSubArgs(args)
        XCTAssertEqual(result.firstIndex(of: "-d").map { result[$0 + 1] }, "3.0")
        XCTAssertFalse(result.contains("-c"))
    }

    func testSubArgsIntDurationCoercedToDouble() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "duration": .int(2)]
        let result = server.buildSubArgs(args)
        XCTAssertTrue(result.contains("-d"))
        XCTAssertTrue(result.contains("2.0"))
    }

    func testSubArgsFormat() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "format": .string("uint8")]
        let result = server.buildSubArgs(args)
        XCTAssertTrue(result.contains("-f"))
        XCTAssertTrue(result.contains("uint8"))
    }

    // MARK: buildPeriphAdvArgs

    func testPeriphAdvArgsEmpty() {
        let result = server.buildPeriphAdvArgs([:])
        XCTAssertEqual(result, ["adv"])
    }

    func testPeriphAdvArgsName() {
        let args: [String: Value] = ["name": .string("MyPeripheral")]
        let result = server.buildPeriphAdvArgs(args)
        XCTAssertTrue(result.contains("adv"))
        XCTAssertTrue(result.contains("-n"))
        XCTAssertTrue(result.contains("MyPeripheral"))
    }

    func testPeriphAdvArgsServices() {
        let args: [String: Value] = ["services": .array([.string("180F"), .string("1809")])]
        let result = server.buildPeriphAdvArgs(args)
        XCTAssertTrue(result.contains("-S"))
        XCTAssertTrue(result.contains("180F"))
        XCTAssertTrue(result.contains("1809"))
    }

    func testPeriphAdvArgsConfigFile() {
        let args: [String: Value] = ["config_file": .string("/tmp/config.json")]
        let result = server.buildPeriphAdvArgs(args)
        XCTAssertTrue(result.contains("-c"))
        XCTAssertTrue(result.contains("/tmp/config.json"))
    }

    // MARK: buildPeriphCloneArgs

    func testPeriphCloneArgsEmpty() {
        let result = server.buildPeriphCloneArgs([:])
        XCTAssertTrue(result.contains("clone"))
    }

    /// The built command line is one `periph clone` parses, with the file
    /// as its `--save` value.
    func testPeriphCloneArgsSaveFile() throws {
        let args: [String: Value] = ["save_file": .string("/tmp/clone.json")]
        let result = server.buildPeriphCloneArgs(args)
        XCTAssertEqual(result.first, "clone")
        let parsed = try CommandSyntax.periphClone.parse(Array(result.dropFirst()))
        XCTAssertEqual(parsed.value(.save), "/tmp/clone.json")
    }

    // MARK: buildPeriphSetArgs

    func testPeriphSetArgsSet() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "value": .string("64")]
        let result = server.buildPeriphSetArgs("set", args)
        XCTAssertEqual(result[0], "set")
        XCTAssertTrue(result.contains("2A19"))
        XCTAssertTrue(result.contains("64"))
    }

    func testPeriphSetArgsNotify() {
        let args: [String: Value] = ["char_uuid": .string("2A19"), "value": .string("64")]
        let result = server.buildPeriphSetArgs("notify", args)
        XCTAssertEqual(result[0], "notify")
    }

    func testPeriphSetArgsFormat() {
        let args: [String: Value] = [
            "char_uuid": .string("2A19"),
            "value": .string("100"),
            "format": .string("uint8"),
        ]
        let result = server.buildPeriphSetArgs("set", args)
        XCTAssertTrue(result.contains("-f"))
        XCTAssertTrue(result.contains("uint8"))
    }
}

// MARK: - MCPStructuredResultTests

final class MCPStructuredResultTests: XCTestCase {

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    private func jsonString<T: Codable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8)!
    }

    func testDevicesRoundTrip() throws {
        let rows = [DeviceRow(id: "AA:BB", name: "Foo", rssi: -55, serviceUUIDs: ["180F"], serviceDisplayNames: ["Battery Service"])]
        let original = StructuredResult.devices(rows)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"devices\""))
        XCTAssertTrue(json.contains("AA:BB"))
        let decoded = try roundTrip(original)
        if case .devices(let r) = decoded {
            XCTAssertEqual(r.first?.id, "AA:BB")
            XCTAssertEqual(r.first?.name, "Foo")
        } else {
            XCTFail("Expected .devices")
        }
    }

    func testServicesRoundTrip() throws {
        let rows = [ServiceRow(uuid: "180F", name: "Battery Service", isPrimary: true)]
        let original = StructuredResult.services(rows)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"services\""))
        let decoded = try roundTrip(original)
        if case .services(let r) = decoded {
            XCTAssertEqual(r.first?.uuid, "180F")
        } else {
            XCTFail("Expected .services")
        }
    }

    func testCharacteristicsRoundTrip() throws {
        let rows = [CharacteristicRow(uuid: "2A19", name: "Battery Level", properties: ["read"], value: nil, valueFields: nil)]
        let original = StructuredResult.characteristics(rows)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"characteristics\""))
        let decoded = try roundTrip(original)
        if case .characteristics(let r) = decoded {
            XCTAssertEqual(r.first?.uuid, "2A19")
        } else {
            XCTFail("Expected .characteristics")
        }
    }

    func testDescriptorsRoundTrip() throws {
        let rows = [DescriptorRow(uuid: "2902", name: "CCCD")]
        let original = StructuredResult.descriptors(rows)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"descriptors\""))
        let decoded = try roundTrip(original)
        if case .descriptors(let r) = decoded {
            XCTAssertEqual(r.first?.uuid, "2902")
        } else {
            XCTFail("Expected .descriptors")
        }
    }

    func testGattTreeRoundTrip() throws {
        let chars = [GATTTreeCharacteristic(uuid: "2A19", name: "Battery Level", properties: ["read"], value: nil, valueFields: nil, descriptors: [])]
        let tree = [GATTTreeService(uuid: "180F", name: "Battery Service", characteristics: chars)]
        let original = StructuredResult.gattTree(tree)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"gattTree\""))
        let decoded = try roundTrip(original)
        if case .gattTree(let t) = decoded {
            XCTAssertEqual(t.first?.uuid, "180F")
            XCTAssertEqual(t.first?.characteristics.first?.uuid, "2A19")
        } else {
            XCTFail("Expected .gattTree")
        }
    }

    func testCharacteristicInfoRoundTrip() throws {
        let field = GATTDecoder.FieldInfo(name: "Level", typeName: "uint8", sizeDescription: "1 byte", conditions: [])
        let info = GATTCharInfo(uuid: "2A19", name: "Battery Level", description: "Battery %", fields: [field])
        let original = StructuredResult.characteristicInfo(info)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"characteristicInfo\""))
        let decoded = try roundTrip(original)
        if case .characteristicInfo(let i) = decoded {
            XCTAssertEqual(i.uuid, "2A19")
            XCTAssertEqual(i.name, "Battery Level")
            XCTAssertEqual(i.fields.first?.name, "Level")
        } else {
            XCTFail("Expected .characteristicInfo")
        }
    }

    func testConnectionStatusRoundTrip() throws {
        let status = ConnectionStatus(isConnected: true, deviceId: "AA:BB", deviceName: "Dev", servicesCount: 3, characteristicsCount: 10, subscriptionsCount: 1)
        let original = StructuredResult.connectionStatus(status)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"connectionStatus\""))
        let decoded = try roundTrip(original)
        if case .connectionStatus(let s) = decoded {
            XCTAssertEqual(s.isConnected, true)
            XCTAssertEqual(s.deviceId, "AA:BB")
        } else {
            XCTFail("Expected .connectionStatus")
        }
    }

    func testPeripheralStatusRoundTrip() throws {
        let status = PeripheralStatus(isAdvertising: true, advertisedName: "MyPeripheral", serviceCount: 2, characteristicCount: 4, subscriberCount: 0)
        let original = StructuredResult.peripheralStatus(status)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"peripheralStatus\""))
        let decoded = try roundTrip(original)
        if case .peripheralStatus(let s) = decoded {
            XCTAssertEqual(s.isAdvertising, true)
            XCTAssertEqual(s.advertisedName, "MyPeripheral")
        } else {
            XCTFail("Expected .peripheralStatus")
        }
    }

    func testReadValueRoundTrip() throws {
        let rv = ReadResult(char: "2A19", name: "Battery Level", value: "64", format: .uint8)
        let original = StructuredResult.readValue(rv)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"readValue\""))
        let decoded = try roundTrip(original)
        if case .readValue(let r) = decoded {
            XCTAssertEqual(r.char, "2A19")
            XCTAssertEqual(r.value, "64")
            XCTAssertEqual(r.format, .uint8)
        } else {
            XCTFail("Expected .readValue")
        }
    }

    func testWriteSuccessRoundTrip() throws {
        let ws = WriteSuccessResult(char: "2A19", name: "Battery Level")
        let original = StructuredResult.writeSuccess(ws)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"writeSuccess\""))
        let decoded = try roundTrip(original)
        if case .writeSuccess(let w) = decoded {
            XCTAssertEqual(w.char, "2A19")
            XCTAssertEqual(w.name, "Battery Level")
        } else {
            XCTFail("Expected .writeSuccess")
        }
    }

    func testWriteSuccessNilNameRoundTrip() throws {
        let ws = WriteSuccessResult(char: "2A19", name: nil)
        let original = StructuredResult.writeSuccess(ws)
        let decoded = try roundTrip(original)
        if case .writeSuccess(let w) = decoded {
            XCTAssertNil(w.name)
        } else {
            XCTFail("Expected .writeSuccess")
        }
    }

    func testNotificationsRoundTrip() throws {
        let nv = NotificationValue(timestamp: "2025-01-01T00:00:00Z", char: "2A19", name: "Battery Level", value: "64")
        let original = StructuredResult.notifications([nv])
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"notifications\""))
        let decoded = try roundTrip(original)
        if case .notifications(let nvs, _) = decoded {
            XCTAssertEqual(nvs.first?.char, "2A19")
            XCTAssertEqual(nvs.first?.value, "64")
        } else {
            XCTFail("Expected .notifications")
        }
    }

    func testPeripheralSummaryRoundTrip() throws {
        let charDef = CharacteristicDefinition(uuid: try BLEUUID(parsing: "2A19"), properties: [.read])
        let svcDef = ServiceDefinition(uuid: try BLEUUID(parsing: "180F"), primary: true, characteristics: [charDef])
        let summary = PeriphSummaryResult(name: "TestPeripheral", serviceUUIDs: ["180F"], services: [svcDef])
        let original = StructuredResult.peripheralSummary(summary)
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"peripheralSummary\""))
        let decoded = try roundTrip(original)
        if case .peripheralSummary(let s) = decoded {
            XCTAssertEqual(s.name, "TestPeripheral")
            XCTAssertEqual(s.serviceUUIDs.first, "180F")
        } else {
            XCTFail("Expected .peripheralSummary")
        }
    }

    func testPeripheralEventsRoundTrip() throws {
        let event = PeripheralEvent.advertisingStarted(error: nil)
        let record = PeriphEventRecord(timestamp: "2025-01-01T00:00:00Z", event: event)
        let original = StructuredResult.peripheralEvents([record])
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"peripheralEvents\""))
        let decoded = try roundTrip(original)
        if case .peripheralEvents(let records) = decoded {
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.timestamp, "2025-01-01T00:00:00Z")
            if case .advertisingStarted(let error) = records.first?.event {
                XCTAssertNil(error)
            } else {
                XCTFail("Expected .advertisingStarted")
            }
        } else {
            XCTFail("Expected .peripheralEvents")
        }
    }

    func testSubscriptionListRoundTrip() throws {
        let original = StructuredResult.subscriptionList(["2A19", "2A37"])
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"subscriptionList\""))
        let decoded = try roundTrip(original)
        if case .subscriptionList(let uuids) = decoded {
            XCTAssertEqual(uuids, ["2A19", "2A37"])
        } else {
            XCTFail("Expected .subscriptionList")
        }
    }

    func testMessageRoundTrip() throws {
        let original = StructuredResult.message("hello world")
        let json = try jsonString(original)
        XCTAssertTrue(json.contains("\"type\":\"message\""))
        let decoded = try roundTrip(original)
        if case .message(let msg) = decoded {
            XCTAssertEqual(msg, "hello world")
        } else {
            XCTFail("Expected .message")
        }
    }

    func testUnknownTypeThrowsOnDecode() throws {
        let badJSON = """
        {"type":"unknownType","value":"x"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(StructuredResult.self, from: badJSON))
    }
}

// MARK: - MCPEncodeStructuredContentTests

final class MCPEncodeStructuredContentTests: XCTestCase {

    private var server: BlewMCPServer!

    override func setUp() {
        super.setUp()
        server = makeServer()
    }

    func testEmptyOutputReturnsNil() {
        XCTAssertNil(server.encodeStructuredContent([]))
    }

    func testOnlyEmptyItemsReturnsNil() {
        XCTAssertNil(server.encodeStructuredContent([.empty, .empty]))
    }

    func testCharacteristicInfoMapped() {
        let field = GATTDecoder.FieldInfo(name: "Level", typeName: "uint8", sizeDescription: "1 byte", conditions: [])
        let info = GATTCharInfo(uuid: "2A19", name: "Battery Level", description: "Battery %", fields: [field])
        let result = server.encodeStructuredContent([.characteristicInfo(info)])
        guard case .characteristicInfo(let i) = result else {
            XCTFail("Expected .characteristicInfo, got \(String(describing: result))")
            return
        }
        XCTAssertEqual(i.uuid, "2A19")
    }

    func testWriteSuccessMapped() {
        let result = server.encodeStructuredContent([.writeSuccess(char: "2A19", name: "Battery Level")])
        guard case .writeSuccess(let ws) = result else {
            XCTFail("Expected .writeSuccess")
            return
        }
        XCTAssertEqual(ws.char, "2A19")
        XCTAssertEqual(ws.name, "Battery Level")
    }

    func testWriteSuccessNilNameMapped() {
        let result = server.encodeStructuredContent([.writeSuccess(char: "2A19", name: nil)])
        guard case .writeSuccess(let ws) = result else {
            XCTFail("Expected .writeSuccess")
            return
        }
        XCTAssertNil(ws.name)
    }

    func testSingleNotificationAggregatedToArray() {
        let nv = NotificationValue(timestamp: "T", char: "2A19", name: nil, value: "ff")
        let result = server.encodeStructuredContent([.notification(nv)])
        guard case .notifications(let nvs, _) = result else {
            XCTFail("Expected .notifications")
            return
        }
        XCTAssertEqual(nvs.count, 1)
        XCTAssertEqual(nvs.first?.value, "ff")
    }

    func testMultipleNotificationsAggregated() {
        let nv1 = NotificationValue(timestamp: "T1", char: "2A19", name: nil, value: "01")
        let nv2 = NotificationValue(timestamp: "T2", char: "2A19", name: nil, value: "02")
        let nv3 = NotificationValue(timestamp: "T3", char: "2A19", name: nil, value: "03")
        let result = server.encodeStructuredContent([.notification(nv1), .notification(nv2), .notification(nv3)])
        guard case .notifications(let nvs, _) = result else {
            XCTFail("Expected .notifications")
            return
        }
        XCTAssertEqual(nvs.count, 3)
    }

    /// A `ble_subscribe` result says how many notifications were dropped;
    /// each report carries the total so far.
    func testDroppedNotificationsInTheSubscribeResult() throws {
        let nv = NotificationValue(timestamp: "T1", char: "2A19", name: nil, value: "01")
        let result = server.encodeStructuredContent([
            .notificationsDropped(NotificationDrops(char: "2A19", total: 3)), .notification(nv),
            .notificationsDropped(NotificationDrops(char: "2A19", total: 7)),
        ])
        guard case .notifications(let nvs, let dropped) = result else {
            return XCTFail("Expected .notifications")
        }
        XCTAssertEqual(nvs.count, 1)
        XCTAssertEqual(dropped, 7)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains("\"dropped\":7"), json)
    }

    func testMultiplePeripheralEventsAggregated() {
        let ev1 = PeriphEventRecord(timestamp: "T1", event: .advertisingStarted(error: nil))
        let ev2 = PeriphEventRecord(timestamp: "T2", event: .advertisingStarted(error: nil))
        let result = server.encodeStructuredContent([.peripheralEvent(ev1), .peripheralEvent(ev2)])
        guard case .peripheralEvents(let events) = result else {
            XCTFail("Expected .peripheralEvents")
            return
        }
        XCTAssertEqual(events.count, 2)
    }

    func testSubscriptionListMapped() {
        let result = server.encodeStructuredContent([.subscriptionList(["2A19", "2A37"])])
        guard case .subscriptionList(let uuids) = result else {
            XCTFail("Expected .subscriptionList")
            return
        }
        XCTAssertEqual(uuids, ["2A19", "2A37"])
    }

    func testMessageMapped() {
        let result = server.encodeStructuredContent([.message("hello")])
        guard case .message(let msg) = result else {
            XCTFail("Expected .message")
            return
        }
        XCTAssertEqual(msg, "hello")
    }

    func testDevicesMapped() {
        let row = DeviceRow(id: "AA", name: "Dev", rssi: -50, serviceUUIDs: [], serviceDisplayNames: [])
        let result = server.encodeStructuredContent([.devices([row])])
        guard case .devices(let rows) = result else {
            XCTFail("Expected .devices")
            return
        }
        XCTAssertEqual(rows.first?.id, "AA")
    }

    func testServicesMapped() {
        let row = ServiceRow(uuid: "180F", name: "Battery Service", isPrimary: true)
        let result = server.encodeStructuredContent([.services([row])])
        guard case .services(let rows) = result else {
            XCTFail("Expected .services")
            return
        }
        XCTAssertEqual(rows.first?.uuid, "180F")
    }

    func testFirstNonEmptyItemWins() {
        let row = ServiceRow(uuid: "180F", name: nil, isPrimary: true)
        // .empty first, then .services — should return .services
        let result = server.encodeStructuredContent([.empty, .services([row])])
        guard case .services = result else {
            XCTFail("Expected .services after skipping .empty")
            return
        }
    }
}

// MARK: - MCPToolDispatchTests

final class MCPToolDispatchTests: XCTestCase {

    private var server: BlewMCPServer!

    override func setUp() {
        super.setUp()
        server = makeServer()
    }

    // MARK: ble_gatt_info

    func testGATTInfoKnownUUID() async throws {
        let params = CallTool.Parameters(name: "ble_gatt_info", arguments: ["char_uuid": .string("2A19")])
        let result = try await server.handleToolCall(params)
        XCTAssertNotEqual(result.isError, true)
        // structuredContent should be present and have type=characteristicInfo
        XCTAssertNotNil(result.structuredContent)
        if let sc = result.structuredContent,
           case .object(let obj) = sc,
           case .string(let type) = obj["type"] {
            XCTAssertEqual(type, "characteristicInfo")
        } else {
            XCTFail("Expected structuredContent with type=characteristicInfo")
        }
    }

    func testGATTInfoStructuredContentCarriesFieldCondition() async throws {
        let params = CallTool.Parameters(name: "ble_gatt_info", arguments: ["char_uuid": .string("2C27")])
        let result = try await server.handleToolCall(params)
        let sc = try XCTUnwrap(result.structuredContent)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sc)) as? NSDictionary)
        let info = try XCTUnwrap(json["characteristicInfo"] as? NSDictionary)
        let fields = try XCTUnwrap(info["fields"] as? [NSDictionary])
        let duration = try XCTUnwrap(fields.first { $0["name"] as? String == "Duration" })
        XCTAssertEqual(duration["condition"] as? NSDictionary,
                       ["kind": "notEquals", "field": "Cooking Process Type", "value": 0])
        XCTAssertEqual(duration["conditionDescription"] as? String, "present if Cooking Process Type is not 0")
        let index = try XCTUnwrap(fields.first { $0["name"] as? String == "Cooking Step Index" })
        XCTAssertNil(index["condition"])
        XCTAssertNil(index["conditionDescription"])
    }

    func testGATTInfoFullUUID() async throws {
        let params = CallTool.Parameters(name: "ble_gatt_info", arguments: ["char_uuid": .string("00002A19-0000-1000-8000-00805F9B34FB")])
        let result = try await server.handleToolCall(params)
        XCTAssertNotEqual(result.isError, true)
    }

    func testGATTInfoUnknownUUID() async throws {
        let params = CallTool.Parameters(name: "ble_gatt_info", arguments: ["char_uuid": .string("ZZZZ")])
        let result = try await server.handleToolCall(params)
        XCTAssertEqual(result.isError, true)
    }

    func testGATTInfoMissingCharUUID() async throws {
        let params = CallTool.Parameters(name: "ble_gatt_info", arguments: [:])
        let result = try await server.handleToolCall(params)
        XCTAssertEqual(result.isError, true)
    }

    func testGATTInfoTextContentContainsBatteryLevel() async throws {
        let params = CallTool.Parameters(name: "ble_gatt_info", arguments: ["char_uuid": .string("2A19")])
        let result = try await server.handleToolCall(params)
        let text = result.content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("Battery Level"), "Expected 'Battery Level' in text content: \(text)")
    }

    // MARK: ble_status

    func testStatusReturnsConnectionStatus() async throws {
        let params = CallTool.Parameters(name: "ble_status", arguments: [:])
        let result = try await server.handleToolCall(params)
        XCTAssertNotEqual(result.isError, true)
        if let sc = result.structuredContent,
           case .object(let obj) = sc,
           case .string(let type) = obj["type"] {
            XCTAssertEqual(type, "connectionStatus")
        } else {
            XCTFail("Expected structuredContent with type=connectionStatus")
        }
    }

    // MARK: ble_periph_status

    func testPeriphStatusReturnsPeripheralStatus() async throws {
        let params = CallTool.Parameters(name: "ble_periph_status", arguments: [:])
        let result = try await server.handleToolCall(params)
        XCTAssertNotEqual(result.isError, true)
        if let sc = result.structuredContent,
           case .object(let obj) = sc,
           case .string(let type) = obj["type"] {
            XCTAssertEqual(type, "peripheralStatus")
        } else {
            XCTFail("Expected structuredContent with type=peripheralStatus")
        }
    }

    // MARK: ble_periph_stop

    func testPeriphStopReturnsSuccess() async throws {
        let params = CallTool.Parameters(name: "ble_periph_stop", arguments: [:])
        let result = try await server.handleToolCall(params)
        XCTAssertNotEqual(result.isError, true)
    }

    // MARK: Unknown tool

    func testUnknownToolThrows() async {
        let params = CallTool.Parameters(name: "ble_does_not_exist", arguments: [:])
        do {
            _ = try await server.handleToolCall(params)
            XCTFail("Expected MCPError to be thrown for unknown tool")
        } catch let error as MCPError {
            if case .methodNotFound = error {
                // expected
            } else {
                XCTFail("Expected methodNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: buildMCPResult

    func testBuildMCPResultSuccessIsNotError() {
        var commandResult = CommandResult()
        commandResult.exitCode = 0
        commandResult.output = [.message("ok")]
        let mcpResult = server.buildMCPResult(commandResult)
        XCTAssertNotEqual(mcpResult.isError, true)
    }

    func testBuildMCPResultFailureIsError() {
        var commandResult = CommandResult()
        commandResult.exitCode = BlewExitCode.notFound.code
        commandResult.errors = ["not found"]
        let mcpResult = server.buildMCPResult(commandResult)
        XCTAssertEqual(mcpResult.isError, true)
    }

    func testBuildMCPResultTextContentIncludesErrors() {
        var commandResult = CommandResult()
        commandResult.exitCode = 1
        commandResult.errors = ["something failed"]
        let mcpResult = server.buildMCPResult(commandResult)
        let text = mcpResult.content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("something failed"), "Error text should appear in content: \(text)")
    }

    func testBuildMCPResultEmptyOutputTextIsOK() {
        let commandResult = CommandResult()  // exitCode=0, no output
        let mcpResult = server.buildMCPResult(commandResult)
        let text = mcpResult.content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined()
        XCTAssertEqual(text, "OK")
    }

    /// A call that replaced the connected device says so in its structured
    /// result, beside the command's own fields, and in its text.
    func testACallThatSwitchedDevicesReportsTheSwitch() async throws {
        let a = "AAAAAAAA-0000-0000-0000-000000000001", b = "BBBBBBBB-0000-0000-0000-000000000002"
        let replaced = try XCTUnwrap(DeviceSwitch(replacing: ConnectedDevice(id: a, advertisement: nil), with: b))
        let command = ToolCommand(duration: 0) { router in
            router.reportDeviceSwitch(replaced)
            var result = CommandResult()
            result.output = [.message("done")]
            return result
        }
        let mcpResult = try await server.execute(command, name: "ble_read", budget: 5)
        let fields = try XCTUnwrap(mcpResult.structuredContent?.objectValue)
        XCTAssertEqual(fields["deviceSwitches"], .array([.object(["from": .string(a), "to": .string(b)])]))
        XCTAssertEqual(fields["message"], .string("done"))
        let text = mcpResult.content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined()
        XCTAssertTrue(text.contains(b), text)

        let next = try await server.execute(ToolCommand(duration: 0) { _ in CommandResult() }, name: "ble_status", budget: 5)
        XCTAssertNil(next.structuredContent, "a switch belongs to the call that made it")
    }

    /// Two calls in flight, the first one's reply held back until the second
    /// has run and replied: each reply reports only the switch its own call
    /// made.
    func testEachReplyReportsOnlyItsOwnCallsSwitches() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs task executors") }
        let a = "AAAAAAAA-0000-0000-0000-000000000001", b = "BBBBBBBB-0000-0000-0000-000000000002",
            c = "CCCCCCCC-0000-0000-0000-000000000003"
        let first = try XCTUnwrap(DeviceSwitch(replacing: ConnectedDevice(id: a, advertisement: nil), with: b))
        let second = try XCTUnwrap(DeviceSwitch(replacing: ConnectedDevice(id: b, advertisement: nil), with: c))
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let replies = HeldExecutor()
        let server: BlewMCPServer = self.server
        let firstCall = Task(executorPreference: replies) {
            try await server.execute(ToolCommand(duration: 0) { router in
                router.reportDeviceSwitch(first)
                started.signal()
                finish.wait()
                return CommandResult()
            }, name: "ble_read", budget: 30)
        }
        await withCheckedContinuation { done in DispatchQueue.global().async { started.wait(); done.resume() } }
        // The first call's work is running: hold the job that resumes its reply.
        replies.hold()
        let secondCall = Task {
            try await server.execute(ToolCommand(duration: 0) { router in
                router.reportDeviceSwitch(second)
                return CommandResult()
            }, name: "ble_read", budget: 30)
        }
        finish.signal()
        let secondReply = try await secondCall.value
        XCTAssertGreaterThan(replies.release(), 0, "the first call's reply was not held back")
        let firstReply = try await firstCall.value

        func switches(_ reply: CallTool.Result) -> Value? { reply.structuredContent?.objectValue?["deviceSwitches"] }
        XCTAssertEqual(switches(secondReply), .array([.object(["from": .string(b), "to": .string(c)])]))
        XCTAssertEqual(switches(firstReply), .array([.object(["from": .string(a), "to": .string(b)])]))
    }

    /// A call cancelled while it runs switches A to B; the task that would
    /// resume it is held back while a second call switches B to C and
    /// replies. The second reply reports both switches, in the order the
    /// calls ran, and nothing is left for a later reply.
    func testACancelledCallsSwitchGoesWithTheNextReplyInRunOrder() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs task executors") }
        let a = "AAAAAAAA-0000-0000-0000-000000000001", b = "BBBBBBBB-0000-0000-0000-000000000002",
            c = "CCCCCCCC-0000-0000-0000-000000000003"
        let first = try XCTUnwrap(DeviceSwitch(replacing: ConnectedDevice(id: a, advertisement: nil), with: b))
        let second = try XCTUnwrap(DeviceSwitch(replacing: ConnectedDevice(id: b, advertisement: nil), with: c))
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let replies = HeldExecutor()
        let server: BlewMCPServer = self.server
        let cancelledCall = Task(executorPreference: replies) {
            try await server.execute(ToolCommand(duration: 0) { router in
                router.reportDeviceSwitch(first)
                started.signal()
                finish.wait()
                return CommandResult()
            }, name: "ble_read", budget: 30)
        }
        await withCheckedContinuation { done in DispatchQueue.global().async { started.wait(); done.resume() } }
        cancelledCall.cancel()
        replies.hold()
        let secondCall = Task {
            try await server.execute(ToolCommand(duration: 0) { router in
                router.reportDeviceSwitch(second)
                return CommandResult()
            }, name: "ble_read", budget: 30)
        }
        finish.signal()
        let secondReply = try await secondCall.value
        XCTAssertGreaterThan(replies.release(), 0, "the cancelled call's task was not held back")
        do {
            _ = try await cancelledCall.value
            XCTFail("a cancelled call replied")
        } catch is CancellationError {}

        func switches(_ reply: CallTool.Result) -> Value? { reply.structuredContent?.objectValue?["deviceSwitches"] }
        XCTAssertEqual(switches(secondReply), .array([
            .object(["from": .string(a), "to": .string(b)]),
            .object(["from": .string(b), "to": .string(c)]),
        ]))
        let later = try await server.execute(ToolCommand(duration: 0) { _ in CommandResult() }, name: "ble_status", budget: 5)
        XCTAssertNil(switches(later), "a switch is reported once")
    }

    /// Cancelled calls that switched nothing leave nothing behind, however
    /// many a client sends.
    func testCancelledCallsWithoutSwitchesRetainNothing() async throws {
        let server: BlewMCPServer = self.server
        for _ in 0..<3 {
            let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
            let call = Task {
                try await server.execute(ToolCommand(duration: 0) { _ in
                    started.signal()
                    finish.wait()
                    return CommandResult()
                }, name: "ble_read", budget: 30)
            }
            await withCheckedContinuation { done in DispatchQueue.global().async { started.wait(); done.resume() } }
            call.cancel()
            finish.signal()
            do {
                _ = try await call.value
                XCTFail("a cancelled call replied")
            } catch is CancellationError {}
        }
        XCTAssertTrue(server.unreportedSwitches.isEmpty)
    }
}

/// Runs a task's jobs on the global queue, except while held: then it keeps
/// them until `release`.
@available(macOS 15.0, *)
private final class HeldExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false
    private var held: [UnownedJob] = []

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let runNow = lock.withLock { () -> Bool in
            if holding { held.append(job) }
            return !holding
        }
        if runNow { start(job) }
    }

    func hold() { lock.withLock { holding = true } }

    /// Run the jobs held; returns how many there were.
    @discardableResult
    func release() -> Int {
        let jobs = lock.withLock { () -> [UnownedJob] in
            holding = false
            defer { held = [] }
            return held
        }
        jobs.forEach(start)
        return jobs.count
    }

    private func start(_ job: UnownedJob) {
        DispatchQueue.global().async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

// MARK: - MCPToolDefinitionTests

final class MCPToolDefinitionTests: XCTestCase {

    private let tools = BlewMCPServer.toolDefinitions
    private var toolsByName: [String: Tool] = [:]

    override func setUp() {
        super.setUp()
        for tool in tools {
            toolsByName[tool.name] = tool
        }
    }

    func testToolCount() {
        XCTAssertEqual(tools.count, 19)
    }

    func testAllExpectedToolsPresent() {
        let expectedNames = [
            "ble_scan", "ble_connect", "ble_disconnect", "ble_status",
            "ble_gatt_services", "ble_gatt_tree", "ble_gatt_chars",
            "ble_gatt_descriptors", "ble_gatt_info",
            "ble_read", "ble_write", "ble_subscribe",
            "ble_periph_advertise", "ble_periph_clone", "ble_periph_stop",
            "ble_periph_set", "ble_periph_notify", "ble_periph_status", "ble_nus",
        ]
        for name in expectedNames {
            XCTAssertNotNil(toolsByName[name], "Missing tool: \(name)")
        }
    }

    func testGATTInfoIsReadOnly() {
        let tool = toolsByName["ble_gatt_info"]
        XCTAssertNotNil(tool, "ble_gatt_info should exist")
        XCTAssertEqual(tool?.annotations.readOnlyHint, true)
    }

    func testWriteIsNotReadOnly() {
        let tool = toolsByName["ble_write"]
        XCTAssertNotNil(tool, "ble_write should exist")
        XCTAssertEqual(tool?.annotations.readOnlyHint, false)
    }

    func testScanIsReadOnly() {
        let tool = toolsByName["ble_scan"]
        XCTAssertEqual(tool?.annotations.readOnlyHint, true)
    }

    func testPeriphAdvertiseIsNotReadOnly() {
        let tool = toolsByName["ble_periph_advertise"]
        XCTAssertEqual(tool?.annotations.readOnlyHint, false)
    }

    func testToolsHaveDescriptions() {
        for tool in tools {
            XCTAssertFalse(tool.description?.isEmpty ?? true, "Tool \(tool.name) has empty description")
        }
    }

    func testGATTInfoRequiresCharUUID() {
        guard let tool = toolsByName["ble_gatt_info"],
              case .object(let schema) = tool.inputSchema,
              case .array(let required) = schema["required"] else {
            XCTFail("ble_gatt_info should have required array in schema")
            return
        }
        XCTAssertTrue(required.contains(.string("char_uuid")), "ble_gatt_info should require char_uuid")
    }

    func testWriteRequiresCharUUIDAndData() {
        guard let tool = toolsByName["ble_write"],
              case .object(let schema) = tool.inputSchema,
              case .array(let required) = schema["required"] else {
            XCTFail("ble_write should have required array in schema")
            return
        }
        XCTAssertTrue(required.contains(.string("char_uuid")))
        XCTAssertTrue(required.contains(.string("data")))
    }

    func testDisconnectHasNoRequiredFields() {
        guard let tool = toolsByName["ble_disconnect"],
              case .object(let schema) = tool.inputSchema else {
            XCTFail("ble_disconnect missing schema")
            return
        }
        // disconnect has no required array, or required is absent/empty
        if let required = schema["required"] {
            if case .array(let arr) = required {
                XCTAssertTrue(arr.isEmpty)
            }
        }
    }

    func testPeriphStopIsIdempotent() {
        let tool = toolsByName["ble_periph_stop"]
        XCTAssertEqual(tool?.annotations.idempotentHint, true)
    }
}

// MARK: - MCPIntegrationTests

final class MCPIntegrationTests: XCTestCase {

    private var binaryPath: String {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent(".build/debug/blew")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return ""
    }

    private func blewAvailable() -> Bool { !binaryPath.isEmpty }

    private func sendMessage(_ data: Data, to stdin: FileHandle) throws {
        stdin.write(data)
    }

    /// Launch `blew mcp`, send one JSON-RPC request, read lines until the response id matches.
    private func runMCPExchange(requests: [[String: Any]]) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["mcp"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write all requests, each terminated with a newline
        var requestData = Data()
        for request in requests {
            let data = try JSONSerialization.data(withJSONObject: request)
            requestData.append(data)
            requestData.append(0x0A) // newline
        }
        stdinPipe.fileHandleForWriting.write(requestData)
        // Close stdin after a short delay to let the server process messages
        Thread.sleep(forTimeInterval: 2.0)
        try stdinPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        // Parse newline-delimited JSON responses
        var responses: [[String: Any]] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            responses.append(json)
        }
        return responses
    }

    func testInitializeHandshake() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }

        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "0.1"],
            ],
        ]
        let responses = try runMCPExchange(requests: [initRequest])
        let initResponse = responses.first { ($0["id"] as? Int) == 1 }
        XCTAssertNotNil(initResponse, "Should receive initialize response")
        XCTAssertNil(initResponse?["error"], "Initialize should succeed")
        let result = initResponse?["result"] as? [String: Any]
        XCTAssertNotNil(result?["serverInfo"], "serverInfo should be present")
        XCTAssertNotNil(result?["capabilities"], "capabilities should be present")
    }

    func testToolsListReturns17Tools() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }

        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "0.1"],
            ],
        ]
        let initNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        let listRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]

        let responses = try runMCPExchange(requests: [initRequest, initNotification, listRequest])
        let listResponse = responses.first { ($0["id"] as? Int) == 2 }
        XCTAssertNotNil(listResponse, "Should receive tools/list response")
        let result = listResponse?["result"] as? [String: Any]
        let toolsArray = result?["tools"] as? [[String: Any]]
        XCTAssertNotNil(toolsArray, "tools array should be present")
        XCTAssertEqual(toolsArray?.count, 19, "Should have 19 tools")
    }

    func testGATTInfoToolCallReturnsCharacteristicInfo() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }

        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "0.1"],
            ],
        ]
        let initNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        let callRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "ble_gatt_info",
                "arguments": ["char_uuid": "2A19"],
            ],
        ]

        let responses = try runMCPExchange(requests: [initRequest, initNotification, callRequest])
        let callResponse = responses.first { ($0["id"] as? Int) == 3 }
        XCTAssertNotNil(callResponse, "Should receive tools/call response")
        let result = callResponse?["result"] as? [String: Any]
        XCTAssertNotNil(result, "Result should be present (not error)")

        // Check structuredContent
        if let sc = result?["structuredContent"] as? [String: Any] {
            XCTAssertEqual(sc["type"] as? String, "characteristicInfo")
        }

        // Check text content contains Battery Level
        if let contentArray = result?["content"] as? [[String: Any]] {
            let text = contentArray.compactMap { $0["text"] as? String }.joined()
            XCTAssertTrue(text.contains("Battery Level") || text.contains("2A19"),
                          "Text should contain characteristic info: \(text)")
        }
    }
}

// MARK: - MCPCommandLineTests

/// A tool argument reaches the router as the value its field names,
/// whatever it looks like: values never stand where options go.
final class MCPCommandLineTests: XCTestCase {
    private let server = makeServer()
    private let router = CommandRouter(globals: try! GlobalOptions.parse([]))
    func testWriteDataThatLooksLikeAnOptionIsTheData() throws {
        let built = try CommandSyntax.write.parse(server.buildWriteArgs([
            "char_uuid": .string("2A19"), "data": .string("-abc"), "format": .string("utf8"),
        ]))
        XCTAssertEqual(built.positionals, ["2A19", "-abc"])
        XCTAssertEqual(try CommandRouter.valueFormat(built), .utf8)
    }

    func testReadAndSubscribeCharacteristicIsNeverAnOption() throws {
        let read = try CommandSyntax.read.parse(server.buildReadArgs(["char_uuid": .string("--format=raw")]))
        XCTAssertEqual(read.positionals, ["--format=raw"])
        XCTAssertEqual(try CommandRouter.valueFormat(read), .hex)

        let sub = try CommandSyntax.subForeground.parse(
            server.buildSubArgs(["char_uuid": .string("-c"), "count": .int(2)]))
        XCTAssertEqual(sub.positionals, ["-c"])
        XCTAssertEqual(try CommandRouter.notificationCount(sub), 2)
    }

    func testPeripheralValueThatLooksLikeAnOptionIsTheValue() throws {
        for subcommand in [CommandSyntax.PeriphValueSubcommand.set, .notify] {
            let command = subcommand.rawValue
            let built = server.buildPeriphSetArgs(command, [
                "char_uuid": .string("FFF1"), "value": .string("-abc"), "format": .string("utf8"),
            ])
            XCTAssertEqual(built.first, command)
            let parsed = try CommandSyntax.periphValue(subcommand).parse(Array(built.dropFirst()))
            XCTAssertEqual(parsed.positionals, ["FFF1", "-abc"], command)
            XCTAssertEqual(try CommandRouter.valueFormat(parsed), .utf8, command)
        }
    }

    /// The `gatt` command line of a call, read with the syntax `runGATT`
    /// reads it with: its subcommand's.
    private func gatt(_ sub: String, _ args: [String: Value]) throws -> ParsedArguments {
        let line = server.buildGATTArgs(sub, args)
        XCTAssertEqual(try CommandSyntax.gatt.subcommand(in: line), sub)
        return try XCTUnwrap(CommandSyntax.gattSubcommands[sub]).parse(line)
    }

    func testGATTServiceAndCharacteristicAreNeverOptions() throws {
        let chars = try gatt("chars", ["service_uuid": .string("-n"), "read_values": .bool(true)])
        XCTAssertEqual(chars.positionals, ["chars", "-n"])
        XCTAssertTrue(chars.flag(.readValues))
        XCTAssertEqual(try gatt("desc", ["char_uuid": .string("-x")]).positionals, ["desc", "-x"])
        XCTAssertEqual(try gatt("info", ["char_uuid": .string("--read")]).positionals, ["info", "--read"])
    }

    /// Only `read_values` and `descriptors` turn on the gatt flags: a
    /// service UUID or a name that spells one does not.
    func testGATTFlagsComeOnlyFromTheirFields() throws {
        let calls: [(String, [String: Value])] = [
            ("chars", ["service_uuid": .string("--read")]),
            ("chars", ["service_uuid": .string("-r")]),
            ("chars", ["name": .string("-r"), "service_uuid": .string("180F")]),
            ("tree", ["name": .string("-d")]),
            ("tree", ["name": .string("--read")]),
        ]
        for (sub, args) in calls {
            let parsed = try gatt(sub, args)
            XCTAssertFalse(parsed.flag(.readValues), "\(sub) \(args)")
            if sub == "tree" { XCTAssertFalse(parsed.flag(.descriptors), "\(sub) \(args)") }
        }
        let both = try gatt("tree", ["descriptors": .bool(true), "read_values": .bool(true)])
        XCTAssertTrue(both.flag(.readValues))
        XCTAssertTrue(both.flag(.descriptors))
    }

    /// Every `format` a tool takes lists the formats blew has, in their order.
    func testFormatEnumsAreTheValueFormats() {
        let formats = Value.array(ValueFormat.allCases.map { .string($0.rawValue) })
        let tools = Dictionary(uniqueKeysWithValues: BlewMCPServer.toolDefinitions.map { ($0.name, $0) })
        for name in ["ble_read", "ble_write", "ble_subscribe", "ble_periph_set", "ble_periph_notify"] {
            guard case .object(let schema) = tools[name]?.inputSchema,
                  case .object(let properties) = schema["properties"],
                  case .object(let format) = properties["format"] else {
                XCTFail("\(name) has no format property")
                continue
            }
            XCTAssertEqual(format["enum"], formats, name)
        }
    }
}
#endif
