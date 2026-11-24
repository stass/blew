import XCTest
@testable import BLEManager
@testable import blew

/// `read -f` and `sub -f` show a value in the asked format only when its
/// bytes are exactly one value of it: a read that does not fit fails with
/// exit code 5, a notification that does not fit is an error marker of its
/// own and the subscription goes on, ending with exit code 5.
final class StrictValueFormatTests: XCTestCase {

    private func kv(_ output: CommandOutput) -> String {
        captureFD(STDOUT_FILENO) { KVRenderer(verbosity: 0).render(output) }
    }

    private func text(_ output: CommandOutput) -> String {
        captureFD(STDOUT_FILENO) { TextRenderer(verbosity: 0).render(output) }
    }

    private func assertReadFails(_ data: Data, _ format: ValueFormat, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CommandRouter.readResult(data, char: "FFF1", name: nil, format: format),
                             file: file, line: line) { error in
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
            XCTAssertEqual(BlewExitCode(for: error).code, BlewExitCode.operationFailed.code, file: file, line: line)
        }
    }

    // MARK: - read

    func testReadValueThatDoesNotFitTheFormatFails() {
        assertReadFails(Data([1, 2, 3, 4, 5]), .uint16le, "uint16le takes 2 bytes, got 5")
        assertReadFails(Data([1]), .uint16le, "uint16le takes 2 bytes, got 1")
        assertReadFails(Data(), .uint8, "uint8 takes 1 byte, got 0")
        assertReadFails(Data([1, 2]), .uint32le, "uint32le takes 4 bytes, got 2")
        assertReadFails(Data([1, 2, 3, 4, 5]), .float32le, "float32le takes 4 bytes, got 5")
        assertReadFails(Data([0x41, 0xFF, 0x1B]), .utf8, "not valid UTF-8")
    }

    func testReadValueThatFitsIsShown() throws {
        XCTAssertEqual(try CommandRouter.readResult(Data([0x34, 0x12]), char: "FFF1", name: nil, format: .uint16le).value,
                       "4660")
        XCTAssertEqual(try CommandRouter.readResult(Data("Thingy".utf8), char: "2A29", name: nil, format: .utf8).value,
                       "Thingy")
    }

    /// Without `-f` a read is hex, which fits any value; `raw` takes any
    /// bytes too.
    func testReadWithoutFormatAndRawShowAnyValue() throws {
        let five = Data([1, 2, 3, 4, 5])
        XCTAssertEqual(try CommandRouter.readResult(five, char: "FFF1", name: nil, format: .hex).value, "0102030405")
        XCTAssertEqual(try CommandRouter.readResult(Data(), char: "FFF1", name: nil, format: .hex).value, "")
        XCTAssertEqual(try CommandRouter.readResult(five, char: "FFF1", name: nil, format: .raw).value, "01 02 03 04 05")
    }

    // MARK: - sub

    private func notification(_ data: Data, _ format: ValueFormat) -> NotificationValue {
        NotificationValue(timestamp: "T", char: "2A19", name: nil, formatting: data, as: format)
    }

    func testNotificationThatDoesNotFitIsAnError() {
        let nv = notification(Data([1, 2]), .uint8)
        XCTAssertNil(nv.value)
        XCTAssertEqual(nv.valueError, "uint8 takes 1 byte, got 2")
        let ok = notification(Data([0x64]), .uint8)
        XCTAssertEqual(ok.value, "100")
        XCTAssertNil(ok.valueError)
    }

    func testTextShowsMismatchedNotificationAsErrorMarker() {
        XCTAssertEqual(text(.notification(notification(Data([1, 2]), .uint8))), "(error: uint8 takes 1 byte, got 2)\n")
        XCTAssertEqual(text(.notification(notification(Data([0x64]), .uint8))), "100\n")
    }

    func testKVMarksMismatchedNotificationAsErrorNotValue() {
        let out = kv(.notification(notification(Data([1, 2]), .uint8)))
        XCTAssertTrue(out.contains(#"error="uint8 takes 1 byte, got 2""#), out)
        XCTAssertFalse(out.contains("value="), out)
        XCTAssertTrue(kv(.notification(notification(Data([0x64]), .uint8))).contains("value=100"))
    }

    func testJSONMarksMismatchedNotificationAsValueError() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notification(Data([1, 2]), .uint8)))
            as? [String: Any]
        XCTAssertEqual(json?["valueError"] as? String, "uint8 takes 1 byte, got 2")
        XCTAssertNil(json?["value"])
        let okJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notification(Data([0x64]), .uint8)))
            as? [String: Any]
        XCTAssertEqual(okJSON?["value"] as? String, "100")
        XCTAssertNil(okJSON?["valueError"])
    }

    /// A notification that does not fit is shown and counted, and the
    /// subscription goes on to the next one.
    func testSubscriptionGoesOnPastAMismatchAndCountsIt() async throws {
        let stream = NotificationStream {}
        let sink = stream.sink
        for bytes: [UInt8] in [[1], [1, 2], [3]] { sink.yield(Data(bytes)) }
        let shown = Locked<[NotificationValue]>([])
        let mismatches = Locked(0)
        try await CommandRouter.forEachNotification(stream, maxCount: 3, duration: nil) { data in
            let nv = CommandRouter.notificationValue(data, char: "2A19", name: nil, format: .uint8, mismatches: mismatches)
            shown.withValue { $0.append(nv) }
        }
        XCTAssertEqual(shown.value.map(\.value), ["1", nil, "3"])
        XCTAssertEqual(shown.value.map(\.valueError), [nil, "uint8 takes 1 byte, got 2", nil])
        XCTAssertEqual(mismatches.value, 1)
    }

    private func finished(_ outcome: CommandRouter.CommandOutcome, mismatches: Int,
                          failedWith code: BlewExitCode? = nil) -> CommandResult {
        var result = CommandResult()
        if let code { result.exitCode = code.code }
        CommandRouter.finishSubscription(outcome, mismatches: mismatches, char: "2A19", format: .uint8, in: &result)
        return result
    }

    func testSubWithMismatchesExitsFive() {
        let clean = finished(.completed, mismatches: 0)
        XCTAssertEqual(clean.exitCode, 0)
        XCTAssertTrue(clean.errors.isEmpty)

        let failed = finished(.completed, mismatches: 2)
        XCTAssertEqual(failed.exitCode, BlewExitCode.operationFailed.code)
        XCTAssertEqual(failed.errors, ["2 notifications of 2A19 did not fit uint8"])
    }

    /// Values that did not fit are a failure, which keeps its code when
    /// Ctrl-C ends the subscription; a Ctrl-C alone is 130.
    func testSubMismatchesOutrankCtrlC() {
        XCTAssertEqual(finished(.interrupted, mismatches: 0).exitCode, BlewExitCode.interrupted.code)
        let stopped = finished(.interrupted, mismatches: 1)
        XCTAssertEqual(stopped.exitCode, BlewExitCode.operationFailed.code)
        XCTAssertEqual(stopped.errors, ["1 notification of 2A19 did not fit uint8"])
    }

    /// A failure the subscription already has (the link lost) keeps its own
    /// code, and the count is still reported.
    func testSubEarlierFailureKeepsItsCode() {
        let lost = finished(.interrupted, mismatches: 1, failedWith: .timeout)
        XCTAssertEqual(lost.exitCode, BlewExitCode.timeout.code)
        XCTAssertEqual(lost.errors, ["1 notification of 2A19 did not fit uint8"])
    }

    /// utf8 shows every byte: a leading byte-order mark stays in the text.
    func testUTF8KeepsByteOrderMark() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF, 0x41])
        XCTAssertEqual(Data(try DataFormatter.format(bytes, as: .utf8).utf8), bytes)
    }

    /// `periph set` shows the value it parsed through `format`, which must
    /// take what `parse` gives for every format.
    func testEveryParsedValueFitsItsFormat() throws {
        let inputs: [ValueFormat: String] = [.hex: "0a0b", .utf8: "\u{FEFF}hi", .base64: "AQI=", .uint8: "255",
                                             .uint16le: "65535", .uint32le: "4294967295", .float32le: "1.5",
                                             .raw: "01 02"]
        XCTAssertEqual(Set(inputs.keys), Set(ValueFormat.allCases))
        for (format, input) in inputs {
            let data = try XCTUnwrap(DataFormatter.parse(input, as: format), format.rawValue)
            XCTAssertNoThrow(try DataFormatter.format(data, as: format), format.rawValue)
        }
    }

    // MARK: - periph set|notify

    /// `periph set|notify -f` parse the value given on the command line; a
    /// value that is not one of the format is refused (exit code 6 through
    /// `parsePeriphValue`), never truncated to fit.
    func testPeriphValueThatDoesNotFitTheFormatIsNotParsed() {
        let router = CommandRouter(globals: try! GlobalOptions.parse([]))
        for (command, result) in [("set", router.runPeriphSet(["-f", "uint8", "2A19", "300"])),
                                  ("notify", router.runPeriphNotify(["-f", "uint16le", "2A19", "70000"]))] {
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code, command)
            XCTAssertTrue(result.errors.contains { $0.contains("invalid value") }, "\(command): \(result.errors)")
        }
        XCTAssertNil(DataFormatter.parse("300", as: .uint8))
        XCTAssertNil(DataFormatter.parse("-1", as: .uint8))
        XCTAssertNil(DataFormatter.parse("70000", as: .uint16le))
        XCTAssertNil(DataFormatter.parse("4294967296", as: .uint32le))
        XCTAssertNil(DataFormatter.parse("abc", as: .hex))
    }
}
