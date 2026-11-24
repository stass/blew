import XCTest
import BLEManager
@testable import blew

/// The renderers' full text output for each kind of result, pinned byte for
/// byte, with device text that needs escaping in every untrusted position.
final class TextRendererGoldenTests: XCTestCase {

    static func samples() -> [(String, CommandOutput)] {
        let hr = GATTDecoder.info(for: "2A37")!
        return [
            ("characteristicsWithValues", .characteristics([
                CharacteristicRow(uuid: "2A00", name: "🔥Na\u{1B}me", properties: ["read", "write"],
                                  value: "v\u{07}", valueFields: nil),
                CharacteristicRow(uuid: "2A37", name: nil, properties: ["notify"], value: nil,
                                  valueFields: [LabeledValue(label: "fl\u{9B}", value: "0x00"),
                                                LabeledValue(label: "bpm", value: "7\n2")]),
                CharacteristicRow(uuid: "2A19", name: "Battery Level", properties: ["read"],
                                  value: nil, valueFields: nil),
            ])),
            ("characteristicsWithoutValues", .characteristics([
                CharacteristicRow(uuid: "2A19", name: "Bat\u{202E}tery", properties: ["read"],
                                  value: nil, valueFields: nil),
            ])),
            ("gattTree", .gattTree([
                GATTTreeService(uuid: "180D", name: "s\u{1B}]0;x\u{07}", characteristics: [
                    GATTTreeCharacteristic(
                        uuid: "2A37", name: "n\u{1B}[1m", properties: ["read", "notify"], value: nil,
                        valueFields: [LabeledValue(label: "a", value: "1\u{07}"),
                                      LabeledValue(label: "b\u{0D}", value: "2")],
                        descriptors: [DescriptorRow(uuid: "2902", name: "d\u{9D}"),
                                      DescriptorRow(uuid: "2901", name: nil)]),
                    GATTTreeCharacteristic(
                        uuid: "2A38", name: nil, properties: ["read"], value: "x\u{1B}",
                        valueFields: nil, descriptors: [DescriptorRow(uuid: "2902", name: "CCCD")]),
                ]),
                GATTTreeService(uuid: "180F", name: nil, characteristics: [
                    GATTTreeCharacteristic(
                        uuid: "2A19", name: "Battery Level", properties: [], value: nil,
                        valueFields: nil, descriptors: []),
                ]),
            ])),
            ("characteristicInfo", .characteristicInfo(GATTCharInfo(
                uuid: hr.uuid, name: hr.name + "\u{1B}", description: "line1\nline2", fields: hr.fields))),
            ("characteristicInfoNoFields", .characteristicInfo(GATTCharInfo(
                uuid: "2A00", name: "Device Name", description: "d", fields: []))),
            ("devices", .devices([
                DeviceRow(id: "ID1", name: "\u{1B}]8;;http://x\u{07}Lamp", rssi: -50,
                          serviceUUIDs: ["180F"], serviceDisplayNames: ["Battery", "H\u{200F}R"],
                          manufacturer: .company(0x0059)),
                DeviceRow(id: "ID-LONGER", name: nil, rssi: -90, serviceUUIDs: [], serviceDisplayNames: []),
                DeviceRow(id: "ID3", name: nil, rssi: -70, serviceUUIDs: [], serviceDisplayNames: [],
                          manufacturer: .company(0xFFFF)),
                DeviceRow(id: "ID4", name: nil, rssi: -70, serviceUUIDs: [], serviceDisplayNames: [],
                          manufacturer: .tooShort(byteCount: 1)),
            ])),
            ("devicesEmpty", .devices([])),
            ("services", .services([ServiceRow(uuid: "180F", name: "B\u{85}", isPrimary: true)])),
            ("descriptors", .descriptors([DescriptorRow(uuid: "2902", name: nil)])),
            ("readValue", .readValue(ReadResult(char: "2A00", name: nil, value: "a\nb\u{1B}[2J", format: .utf8))),
            ("notification", .notification(NotificationValue(
                timestamp: "t", char: "2A37", name: nil, value: "n\u{1B}"))),
            ("message", .message("m\u{1B}[31m")),
            ("connectionStatus", .connectionStatus(ConnectionStatus(
                isConnected: true, deviceId: "ID1", deviceName: "x\u{1B}y",
                servicesCount: 1, characteristicsCount: 2, subscriptionsCount: 0,
                lastError: "e\u{07}"))),
            ("peripheralStatus", .peripheralStatus(PeripheralStatus(
                isAdvertising: true, advertisedName: "p\u{1B}", serviceCount: 1,
                characteristicCount: 1, subscriberCount: 0))),
            ("subscriptionsEmpty", .subscriptionList([])),
            ("subscriptions", .subscriptionList(["2A37", "abc\u{1B}"])),
            ("eventConnected", .peripheralEvent(PeriphEventRecord(
                timestamp: "t\u{1B}", event: .centralConnected(centralId: "12345678-AAAA")))),
            ("eventWrite", .peripheralEvent(PeriphEventRecord(
                timestamp: "t", event: .writeRequest(centralId: "c\u{1B}", characteristicUUID: "2A00",
                                                     value: Data([0x01, 0x1B]))))),
            ("eventSubscribed", .peripheralEvent(PeriphEventRecord(
                timestamp: "t", event: .subscribed(centralId: "c", characteristicUUID: "2A\u{1B}")))),
        ]
    }

    func testTextAndKVOutputArePinned() {
        let samples = Self.samples()
        XCTAssertEqual(Set(samples.map(\.0)), Set(Self.expected.keys))
        for (name, output) in samples {
            guard let want = Self.expected[name] else { continue }
            let text = captureRendered { TextRenderer(verbosity: 0).render(output) }
            XCTAssertEqual(text, want.text.map { $0 + "\n" }.joined(), "text: \(name)")
            let kv = captureRendered { KVRenderer(verbosity: 0).render(output) }
            XCTAssertEqual(kv, want.kv.map { $0 + "\n" }.joined(), "kv: \(name)")
        }
    }
}

private func captureRendered(_ block: () -> Void) -> String {
    fflush(stdout)
    let pipe = Pipe()
    let original = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    block()
    fflush(stdout)
    dup2(original, STDOUT_FILENO)
    close(original)
    pipe.fileHandleForWriting.closeFile()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

extension TextRendererGoldenTests {
    /// Text and kv output per sample, one string per line.
    static let expected: [String: (text: [String], kv: [String])] = [
        "characteristicsWithValues": (
            text: [
                #"UUID  Name           Properties  Value"#,
                #"──────────────────────────────────────"#,
                #"2A00  🔥Na\x1bme     read,write  v\x07"#,
                #"2A37                 notify    "#,
                #"                                 fl\u009b: 0x00"#,
                #"                                 bpm: 7\n2"#,
                #"2A19  Battery Level  read      "#,
            ],
            kv: [
                #"uuid=2A00 name="🔥Na\x1bme" properties=read,write value="v\x07""#,
                #"uuid=2A37 name="" properties=notify value="fl\u009b: 0x00 | bpm: 7\n2""#,
                #"uuid=2A19 name="Battery Level" properties=read value="""#,
            ]),
        "characteristicsWithoutValues": (
            text: [
                #"UUID  Name           Properties"#,
                #"───────────────────────────────"#,
                #"2A19  Bat\u202etery  read      "#,
            ],
            kv: [
                #"uuid=2A19 name="Bat\u202etery" properties=read"#,
            ]),
        "gattTree": (
            text: [
                #"Service 180D  s\x1b]0;x\x07"#,
                #"├── 2A37  n\x1b[1m  [read, notify]"#,
                #"│     a: 1\x07"#,
                #"│     b\r: 2"#,
                #"│   ├── 2902  d\u009d"#,
                #"│   └── 2901"#,
                #"└── 2A38  [read]  = x\x1b"#,
                #"    └── 2902  CCCD"#,
                #""#,
                #"Service 180F"#,
                #"└── 2A19  Battery Level  []"#,
            ],
            kv: [
                #"type=service uuid=180D name="s\x1b]0;x\x07""#,
                #"type=characteristic service=180D uuid=2A37 name="n\x1b[1m" properties=read,notify value="a: 1\x07 | b\r: 2""#,
                #"type=descriptor char=2A37 uuid=2902 name="d\u009d""#,
                #"type=descriptor char=2A37 uuid=2901"#,
                #"type=characteristic service=180D uuid=2A38 properties=read value="x\x1b""#,
                #"type=descriptor char=2A38 uuid=2902 name=CCCD"#,
                #"type=service uuid=180F"#,
                #"type=characteristic service=180F uuid=2A19 name="Battery Level" properties="""#,
            ]),
        "characteristicInfo": (
            text: [
                #"Heart Rate Measurement\x1b (2A37)"#,
                #""#,
                #"line1\nline2"#,
                #""#,
                #"Structure:"#,
                #"  Flags                                             boolean[8]  1 byte"#,
                #"  Heart Rate Measurement Value (8 bit resolution)   uint8       1 byte  [present if bit 0 of Flags is 0]"#,
                #"  Heart Rate Measurement Value (16 bit resolution)  uint16      2 bytes  [present if bit 0 of Flags is 1]"#,
                #"  Energy Expended                                   uint16      2 bytes  [present if bit 3 of Flags is 1]"#,
                #"  RR-interval                                       opaque      variable (array)  [present if bit 4 of Flags is 1]"#,
            ],
            kv: [
                #"uuid=2A37 name="Heart Rate Measurement\x1b" description="line1\nline2""#,
                #"field=Flags type=boolean[8] size="1 byte""#,
                #"field="Heart Rate Measurement Value (8 bit resolution)" type=uint8 size="1 byte" condition="present if bit 0 of Flags is 0""#,
                #"field="Heart Rate Measurement Value (16 bit resolution)" type=uint16 size="2 bytes" condition="present if bit 0 of Flags is 1""#,
                #"field="Energy Expended" type=uint16 size="2 bytes" condition="present if bit 3 of Flags is 1""#,
                #"field=RR-interval type=opaque size="variable (array)" condition="present if bit 4 of Flags is 1""#,
            ]),
        "characteristicInfoNoFields": (
            text: [
                #"Device Name (2A00)"#,
                #""#,
                #"d"#,
            ],
            kv: [
                #"uuid=2A00 name="Device Name" description=d"#,
            ]),
        "devices": (
            text: [
                #"ID         Name                      RSSI  Signal    Manufacturer                     Services         "#,
                #"───────────────────────────────────────────────────────────────────────────────────────────────────────"#,
                #"ID1        \x1b]8;;http://x\x07Lamp  -50   ██████░░  0x0059 Nordic Semiconductor ASA  Battery, H\u200fR"#,
                #"ID-LONGER  (unknown)                 -90   █░░░░░░░                                                    "#,
                #"ID3        (unknown)                 -70   ███░░░░░  0xFFFF                                            "#,
                #"ID4        (unknown)                 -70   ███░░░░░  (too short: 1 byte)                               "#,
            ],
            kv: [
                #"id=ID1 name="\x1b]8;;http://x\x07Lamp" rssi=-50 manufacturer_id=0x0059 manufacturer="Nordic Semiconductor ASA" services=180F"#,
                #"id=ID-LONGER name=(unknown) rssi=-90 services="""#,
                #"id=ID3 name=(unknown) rssi=-70 manufacturer_id=0xFFFF services="""#,
                #"id=ID4 name=(unknown) rssi=-70 manufacturer_data_length=1 services="""#,
            ]),
        "devicesEmpty": (
            text: [
                #""#,
            ],
            kv: []),
        "services": (
            text: [
                #"UUID  Name     Primary"#,
                #"──────────────────────"#,
                #"180F  B\u0085  yes    "#,
            ],
            kv: [
                #"uuid=180F name="B\u0085" primary=yes"#,
            ]),
        "descriptors": (
            text: [
                #"UUID  Name"#,
                #"──────────"#,
                #"2902      "#,
            ],
            kv: [
                #"uuid=2902 name="""#,
            ]),
        "readValue": (
            text: [
                #"a\nb\x1b[2J"#,
            ],
            kv: [
                #"char=2A00 value="a\nb\x1b[2J" fmt=utf8"#,
            ]),
        "notification": (
            text: [
                #"n\x1b"#,
            ],
            kv: [
                #"ts=t char=2A37 value="n\x1b""#,
            ]),
        "message": (
            text: [
                #"m\x1b[31m"#,
            ],
            kv: [
                #"m\x1b[31m"#,
            ]),
        "connectionStatus": (
            text: [
                #"connected: yes"#,
                #"device: ID1"#,
                #"name: x\x1by"#,
                #"services: 1"#,
                #"characteristics: 2"#,
                #"subscriptions: 0"#,
                #"last_error: e\x07"#,
            ],
            kv: [
                #"connected=yes device=ID1 name="x\x1by" services=1 characteristics=2 subscriptions=0 last_error="e\x07""#,
            ]),
        "peripheralStatus": (
            text: [
                #"advertising: yes"#,
                #"name: p\x1b"#,
                #"services: 1"#,
                #"characteristics: 1"#,
                #"subscribers: 0"#,
            ],
            kv: [
                #"advertising=yes name="p\x1b" services=1 characteristics=1 subscribers=0"#,
            ]),
        "subscriptionsEmpty": (
            text: [
                #"No active background subscriptions."#,
            ],
            kv: []),
        "subscriptions": (
            text: [
                #"Active background subscriptions:"#,
                #"  2A37 (Heart Rate Measurement)"#,
                #"  abc\x1b"#,
            ],
            kv: [
                #"subscription=2A37"#,
                #"subscription="abc\x1b""#,
            ]),
        "eventConnected": (
            text: [
                #"[t\x1b] central 12345678 connected"#,
            ],
            kv: [
                #"event=connected ts="t\x1b" central=12345678-AAAA"#,
            ]),
        "eventWrite": (
            text: [
                #"[t] write 2A00 (Device Name) by c\x1b <- 011b"#,
            ],
            kv: [
                #"event=write ts=t central="c\x1b" char=2A00 value=011b"#,
            ]),
        "eventSubscribed": (
            text: [
                #"[t] subscribe 2A\x1b by c"#,
            ],
            kv: [
                #"event=subscribe ts=t central=c char="2A\x1b""#,
            ]),
    ]
}
