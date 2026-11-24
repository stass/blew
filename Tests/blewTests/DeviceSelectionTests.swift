import XCTest
@testable import blew
import BLEManager

private let nus = NUS.service

private func device(_ id: String, name: String? = nil, rssi: Int = -60, services: [String] = [],
                    manufacturer: [UInt8]? = nil) -> DiscoveredDevice {
    DiscoveredDevice(identifier: id, name: name, rssi: rssi, serviceUUIDs: services,
                     manufacturerData: manufacturer.map { Data($0) })
}

private func target(_ args: [String]) throws -> DeviceTarget {
    try DeviceTarget(CommandSyntax.targeting.parse(args))
}

final class DeviceFilterTests: XCTestCase {
    func testServiceFilterMatchesEverySpellingOfTheUUID() throws {
        let battery = device("A", services: ["180F"])
        for spelling in ["180F", "180f", "0000180F", "0000180f-0000-1000-8000-00805f9b34fb"] {
            XCTAssertTrue(try target(["-S", spelling]).filter.matches(battery), spelling)
        }
        XCTAssertFalse(try target(["-S", "180A"]).filter.matches(battery))
        XCTAssertFalse(try target(["-S", "180F"]).filter.matches(device("B")))
        XCTAssertTrue(try target(["-S", nus.lowercased()]).filter.matches(device("C", services: [nus])))
    }

    func testRepeatedServiceFiltersRequireEveryService() throws {
        let filter = try target(["-S", "180F", "-S", "180A"]).filter
        XCTAssertTrue(filter.matches(device("A", services: ["180A", "180F", "180D"])))
        XCTAssertFalse(filter.matches(device("B", services: ["180F"])))
    }

    func testManufacturerFilterReadsTheLittleEndianCompanyID() throws {
        let nordic = try target(["-m", "89"]).filter
        XCTAssertTrue(nordic.matches(device("A", manufacturer: [0x59, 0x00, 0x01, 0x02])))
        XCTAssertFalse(nordic.matches(device("B", manufacturer: [0x4C, 0x00, 0x59])))
        XCTAssertFalse(nordic.matches(device("C", manufacturer: [0x59])))
        XCTAssertFalse(nordic.matches(device("D")))
        XCTAssertTrue(try target(["-m", "76"]).filter.matches(device("E", manufacturer: [0x4C, 0x00])))
    }

    func testIdNameAndRSSIFilters() throws {
        let thingy = device("F3C2A1B0-1234-5678-ABCD-000000000001", name: "Nordic Thingy", rssi: -70)
        XCTAssertTrue(try target(["-i", "f3c2a1b0-1234-5678-abcd-000000000001"]).filter.matches(thingy))
        XCTAssertFalse(try target(["-i", "F3C2A1B0"]).filter.matches(thingy))
        XCTAssertTrue(try target(["-n", "thingy"]).filter.matches(thingy))
        XCTAssertFalse(try target(["-n", "thingy"]).filter.matches(device("X")))
        XCTAssertTrue(try target(["-R", "-70"]).filter.matches(thingy))
        XCTAssertFalse(try target(["-R", "-69"]).filter.matches(thingy))
        XCTAssertFalse(try target(["-n", "Thingy", "-R", "-60"]).filter.matches(thingy))
    }

    func testInvalidTargetingValuesAreErrors() {
        for args in [["-m", "abc"], ["-m", "65536"], ["-m", "-1"], ["-S", "xyz"], ["-S", "12345"],
                     ["-S", "180G"], ["-R", "loud"], ["-p", "bogus"], ["-p", "-n"], ["-n"], ["--service"],
                     ["-n", "A", "--name=B"], ["-i", "X", "-i", "Y"], ["-p", "first", "-p", "only"]] {
            XCTAssertThrowsError(try target(args), "\(args) should be rejected")
        }
    }

    func testParseSeparatesSelectorsFromPick() throws {
        XCTAssertTrue(try target([]).filter.isEmpty)
        XCTAssertNil(try target([]).pick)
        let onlyPick = try target(["-p", "first"])
        XCTAssertTrue(onlyPick.filter.isEmpty)
        XCTAssertEqual(onlyPick.pick, .first)
        XCTAssertEqual(try target(["--manufacturer=89", "--name=x"]).filter,
                       DeviceFilter(name: "x", manufacturer: 89))
    }

    func testCanonicalUUID() {
        XCTAssertEqual(BLENames.canonicalUUID("180f"), "180F")
        XCTAssertEqual(BLENames.canonicalUUID("0000180F"), "180F")
        XCTAssertEqual(BLENames.canonicalUUID("1234ABCD"), "1234ABCD")
        XCTAssertEqual(BLENames.canonicalUUID("0000180F-0000-1000-8000-00805F9B34FB"), "180F")
        XCTAssertEqual(BLENames.canonicalUUID("1234abcd-0000-1000-8000-00805f9b34fb"), "1234ABCD")
        XCTAssertEqual(BLENames.canonicalUUID(nus.lowercased()), nus)
        XCTAssertNil(BLENames.canonicalUUID("180"))
        XCTAssertNil(BLENames.canonicalUUID("\u{FF11}80F"), "fullwidth digits are not hex")
        XCTAssertNil(BLENames.canonicalUUID("6E400001-B5A3-F393-E0A9-E50E24DCCA9Z"))
    }
}

final class PickStrategyTests: XCTestCase {
    /// In the order the scan first saw them.
    private let candidates = [device("A", rssi: -80), device("B", rssi: -50), device("C", rssi: -50)]

    func testFirstIsTheFirstSeenNotTheStrongest() {
        XCTAssertEqual(PickStrategy.first.choose(from: candidates), .picked(candidates[0]))
    }

    func testStrongestIsTheHighestRSSIEarlierSeenOnATie() {
        XCTAssertEqual(PickStrategy.strongest.choose(from: candidates), .picked(candidates[1]))
    }

    func testOnlyRequiresExactlyOneCandidate() {
        XCTAssertEqual(PickStrategy.only.choose(from: candidates), .several(candidates))
        XCTAssertEqual(PickStrategy.only.choose(from: [candidates[2]]), .picked(candidates[2]))
    }

    func testNoCandidates() {
        for pick in [PickStrategy.first, .strongest, .only] {
            XCTAssertEqual(pick.choose(from: []), .noDevices)
        }
    }
}

final class ScanResultsTests: XCTestCase {
    func testKeepsFirstSeenOrderAndMergesAdvertisements() {
        var results = ScanResults()
        results.add(device("A", name: "Alpha", rssi: -80, services: ["180F"], manufacturer: [0x59, 0x00]))
        results.add(device("B", rssi: -40))
        let quiet = results.add(device("A", rssi: -70))
        XCTAssertEqual(quiet.serviceUUIDs, ["180F"], "an advertisement without services keeps the last list")
        let merged = results.add(device("A", rssi: -30, services: [nus]))
        XCTAssertEqual(results.devices.map(\.identifier), ["A", "B"])
        XCTAssertEqual(merged.name, "Alpha")
        XCTAssertEqual(merged.rssi, -30)
        XCTAssertEqual(merged.serviceUUIDs, [nus], "a new list replaces the old one, so a record cannot grow")
        XCTAssertEqual(merged.manufacturerData, Data([0x59, 0x00]))
        XCTAssertEqual(results.devices.byRSSI.map(\.identifier), ["A", "B"])
    }

    func testFiltersSeeTheMergedRecord() throws {
        var results = ScanResults()
        results.add(device("A", services: [nus]))
        results.add(device("B", name: "erxos"))
        results.add(device("A", name: "erxos"))
        let filter = try target(["-n", "erxos", "-S", nus]).filter
        XCTAssertEqual(results.matching(filter).map(\.identifier), ["A"])
    }
}

final class AutoConnectPlanTests: XCTestCase {
    private let a = device("AAAAAAAA-0000-0000-0000-000000000001", name: "Alpha", services: ["180F"])
    private let nusFilter = DeviceFilter(services: [nus])
    private let b = "BBBBBBBB-0000-0000-0000-000000000002"

    private func plan(_ args: [String], connected: DiscoveredDevice?, record: Bool = true,
                      defaultFilter: DeviceFilter = DeviceFilter(), scanned: [String] = []) throws -> AutoConnectPlan {
        AutoConnectPlan.make(target: try target(args), defaultFilter: defaultFilter,
                             connected: connected.map { ConnectedDevice(id: $0.identifier, advertisement: record ? $0 : nil) },
                             scanned: scanned)
    }

    func testConnectedDeviceIsUsedWhenItMatchesOrNothingIsNamed() throws {
        for args in [[], ["-n", "alpha"], ["-S", "180F", "-R", "-90"], ["-i", a.identifier.lowercased()], ["-p", "only"]] {
            XCTAssertEqual(try plan(args, connected: a), .useConnected, "\(args)")
        }
        XCTAssertEqual(try plan([], connected: a, defaultFilter: nusFilter), .useConnected,
                       "a default filter never replaces the connected device")
    }

    func testAnotherTargetReplacesTheConnectedDevice() throws {
        XCTAssertEqual(try plan(["-n", "Beta"], connected: a), .scan(DeviceFilter(name: "Beta"), .strongest))
        XCTAssertEqual(try plan(["-i", "B"], connected: a, scanned: [b]), .connect(b))
        XCTAssertEqual(try plan(["-S", "180A", "-p", "first"], connected: a),
                       .scan(DeviceFilter(services: ["180A"]), .first))
    }

    /// `connect` naming the connected device reconnects to it by identifier;
    /// a scan would miss it, since a connected device usually stops advertising.
    func testReconnectNamingTheConnectedDeviceUsesItsIdentifier() throws {
        let t = try target(["-n", "Alpha"])
        XCTAssertEqual(AutoConnectPlan.make(target: t, connected: ConnectedDevice(id: a.identifier, advertisement: a),
                                            scanned: [], reconnect: true), .connect(a.identifier))
        XCTAssertEqual(AutoConnectPlan.make(target: try target(["-p", "only"]),
                                            connected: ConnectedDevice(id: a.identifier, advertisement: a),
                                            scanned: [], reconnect: true), .useConnected, "bare connect keeps the device")
        XCTAssertEqual(AutoConnectPlan.make(target: try target(["-n", "Beta"]),
                                            connected: ConnectedDevice(id: a.identifier, advertisement: a),
                                            scanned: [], reconnect: true), .scan(DeviceFilter(name: "Beta"), .strongest))
    }

    func testAConnectedDeviceWithoutAScanRecordMatchesOnlyByID() throws {
        XCTAssertEqual(try plan(["-n", "Alpha"], connected: a, record: false), .scan(DeviceFilter(name: "Alpha"), .strongest))
        XCTAssertEqual(try plan(["-i", a.identifier], connected: a, record: false), .useConnected)
    }

    func testNotConnected() throws {
        XCTAssertEqual(try plan(["-i", b.lowercased(), "-n", "Alpha"], connected: nil), .connect(b))
        XCTAssertEqual(try plan(["-m", "89"], connected: nil), .scan(DeviceFilter(manufacturer: 89), .strongest))
        XCTAssertEqual(try plan(["-p", "only"], connected: nil, defaultFilter: nusFilter), .scan(nusFilter, .only))
        XCTAssertEqual(try plan(["-n", "x"], connected: nil, defaultFilter: nusFilter),
                       .scan(DeviceFilter(name: "x"), .strongest), "a named device replaces the default filter")
        XCTAssertEqual(try plan(["-p", "first"], connected: nil), .noTarget)
    }
}

/// Scan options are checked before the scan starts, so these never reach the radio.
final class ScanArgumentTests: XCTestCase {
    private func router(_ globals: [String]) -> CommandRouter {
        CommandRouter(globals: try! GlobalOptions.parse(globals), renderer: NullRenderer())
    }

    /// An unbounded global `-t` is rejected when the global options are
    /// parsed, before any command (`scan -w`) can use it.
    func testUnboundedGlobalTimeoutIsRejected() {
        XCTAssertThrowsError(try GlobalOptions.parse(["-t", "inf", "-o", "kv"]))
    }

    func testWatchRejectsAnInvalidScanTimeout() {
        for value in ["inf", "nan", "-1"] {
            XCTAssertEqual(router(["-o", "kv"]).runScan(["-w", "-t", value]).exitCode,
                           BlewExitCode.invalidArguments.code, value)
        }
    }

    /// Auto-connect may replace the connected device, so a command's own
    /// arguments are checked first; these never scan or connect.
    func testCommandArgumentsAreCheckedBeforeAutoConnect() {
        let r = router(["-o", "kv"])
        XCTAssertEqual(r.runWrite(["-n", "B", "fff1", "zz"]).exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(r.runWrite(["-n", "B", "fff1"]).exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(r.runRead(["-n", "B"]).exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(r.runSub(["-n", "B"]).exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(r.runRead(["-n", "B", "-n", "C", "2a19"]).exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(r.runGATT(["dsc", "-n", "B"]).exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(r.runGATT(["desc", "-n", "B"]).exitCode, BlewExitCode.invalidArguments.code)
    }

    /// An `-i` that is neither an identifier nor a device of the last scan
    /// fails before anything is disconnected or connected.
    /// `-i` (here `connect`'s positional) never matches a name, whatever the
    /// last scan saw; each way it fails has its exit code.
    func testAnIdentifierThatDoesNotResolveFailsWithoutConnecting() {
        let r = router(["-o", "kv"])
        r.lastScanResults = [
            DiscoveredDevice(identifier: "AAAAAAAA-0000-0000-0000-000000000001", name: "1234ABCD", rssi: -50,
                             serviceUUIDs: [], manufacturerData: nil),
            DiscoveredDevice(identifier: "BBBBBBBB-1234-0000-0000-000000000002", name: "Thingy", rssi: -50,
                             serviceUUIDs: [], manufacturerData: nil),
        ]
        XCTAssertEqual(r.runConnect(["1234ABCD"]).exitCode, BlewExitCode.notFound.code)
        XCTAssertEqual(r.runConnect(["Thingy"]).exitCode, BlewExitCode.invalidArguments.code)
        let ambiguous = r.runConnect(["0000-0000"])
        XCTAssertEqual(ambiguous.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(ambiguous.errors.dropFirst(), ["  1234ABCD (AAAAAAAA-0000-0000-0000-000000000001)",
                                                      "  Thingy (BBBBBBBB-1234-0000-0000-000000000002)"])
    }

    func testInvalidFiltersAreRejected() {
        for args in [["-S", "nope"], ["-m", "0x59"], ["-p", "bogus"], ["-w", "-p", "first"], ["-t", "soon"]] {
            XCTAssertEqual(router(["-o", "kv"]).runScan(args).exitCode, BlewExitCode.invalidArguments.code, "\(args)")
        }
    }
}

/// `-i` and MCP `device_id` name a device by its identifier only: an
/// advertised name never takes part, so a nearby device cannot capture them.
final class IdentifierResolutionTests: XCTestCase {
    private let named = "AAAAAAAA-0000-0000-0000-000000000001"  // advertises the name "1234ABCD"
    private let byID = "1234ABCD-0000-0000-0000-000000000002"
    private let other = "CCCCCCCC-1234-0000-0000-000000000003"

    private func resolve(_ input: String, _ known: [String]) -> Result<String, IdentifierFailure> {
        DeviceTarget.resolveIdentifier(input, among: known)
    }

    private func target(_ id: String) throws -> DeviceTarget {
        try DeviceTarget(CommandSyntax.targeting.parse(["-i", id]))
    }

    func testAFragmentMatchesIdentifiersNotNames() {
        XCTAssertEqual(resolve("1234abcd", [named, byID]), .success(byID))
        XCTAssertEqual(resolve("1234-ABCD", [named, byID]), .success(byID), "hyphens are ignored")
        XCTAssertEqual(resolve("1234ABCD", [named]), .failure(.notFound))
    }

    func testAnAmbiguousFragmentListsEveryCandidate() {
        XCTAssertEqual(resolve("1234", [named, byID, other]), .failure(.ambiguous([byID, other])))
    }

    /// A UUID names exactly that identifier, known or not, and is never a
    /// fragment of a longer one.
    func testAUUIDNamesOnlyItself() {
        let unseen = "1234ABCD-0000-0000-0000-000000000009"
        XCTAssertEqual(resolve(unseen.lowercased(), [named, byID]), .success(unseen))
        XCTAssertEqual(resolve(byID.lowercased(), [byID]), .success(byID))
        XCTAssertEqual(resolve(unseen.replacingOccurrences(of: "-", with: ""), [byID]), .success(unseen),
                       "32 hex digits are a full identifier too")
    }

    func testANameIsNotAnIdentifier() {
        for input in ["Thingy", "", "-", "12 34", "\u{FF11}\u{FF12}"] {
            XCTAssertEqual(resolve(input, [byID]), .failure(.notAnIdentifier), input)
        }
    }

    /// `-i` resolves against the connected device too, which a scan usually
    /// misses because a connected device stops advertising.
    func testAFragmentOfTheConnectedDeviceKeepsIt() throws {
        let connected = ConnectedDevice(id: byID, advertisement: nil)
        XCTAssertEqual(AutoConnectPlan.make(target: try target("1234ABCD"), connected: connected, scanned: [named]),
                       .useConnected)
        XCTAssertEqual(AutoConnectPlan.make(target: try target("1234ABCD"), connected: connected, scanned: [byID, named]),
                       .useConnected, "the connected device is one candidate even when the scan saw it")
        XCTAssertEqual(AutoConnectPlan.make(target: try target("1234"), connected: connected, scanned: [other]),
                       .unresolvedIdentifier("1234", .ambiguous([other, byID])),
                       "a fragment of the connected device and another is ambiguous, not a switch")
    }

    func testAnUnresolvedIdentifierNeverConnects() throws {
        XCTAssertEqual(AutoConnectPlan.make(target: try target("1234ABCD"), connected: nil, scanned: [named]),
                       .unresolvedIdentifier("1234ABCD", .notFound))
        XCTAssertEqual(AutoConnectPlan.make(target: try target("Thingy"), connected: nil, scanned: [named]),
                       .unresolvedIdentifier("Thingy", .notAnIdentifier))
    }
}

final class DeviceSwitchTests: XCTestCase {
    private let a = "AAAAAAAA-0000-0000-0000-000000000001"
    private let b = "BBBBBBBB-0000-0000-0000-000000000002"

    func testASwitchIsReplacingAnotherConnectedDevice() {
        XCTAssertEqual(DeviceSwitch(replacing: ConnectedDevice(id: a, advertisement: nil), with: b)?.notice,
                       "disconnected \(a) to connect to \(b)")
        XCTAssertNil(DeviceSwitch(replacing: ConnectedDevice(id: a, advertisement: nil), with: a.lowercased()))
        XCTAssertNil(DeviceSwitch(replacing: nil, with: b))
    }
}
