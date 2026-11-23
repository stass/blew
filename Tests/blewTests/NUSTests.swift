import XCTest
@testable import blew

private func makeRouter(interactive: Bool = false) -> CommandRouter {
    CommandRouter(globals: try! GlobalOptions.parse([]), isInteractiveMode: interactive)
}

private func bytes(_ s: String) -> Data { Data(s.utf8) }

/// Collects what a session or port delivers, from any thread.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    var data: Data { lock.withLock { stored } }
    func append(_ d: Data) { lock.withLock { stored.append(d) } }
}

// MARK: - Chunking

final class NUSChunkTests: XCTestCase {
    func testSplitsIntoPiecesOfAtMostMaxLength() {
        let chunks = NUS.chunks(bytes("abcdefg"), maxLength: 3)
        XCTAssertEqual(chunks, [bytes("abc"), bytes("def"), bytes("g")])
    }

    func testExactMultipleHasNoEmptyTail() {
        XCTAssertEqual(NUS.chunks(bytes("abcdef"), maxLength: 3), [bytes("abc"), bytes("def")])
    }

    func testEmptyDataHasNoChunks() {
        XCTAssertEqual(NUS.chunks(Data(), maxLength: 20), [])
    }

    func testSliceWithNonZeroStartIndex() {
        let slice = bytes("xxabcd").dropFirst(2)
        XCTAssertEqual(NUS.chunks(Data(slice), maxLength: 3), [bytes("abc"), bytes("d")])
        XCTAssertEqual(NUS.chunks(slice, maxLength: 3), [bytes("abc"), bytes("d")])
    }

    func testRejoinedChunksEqualInput() {
        let input = Data((0..<1000).map { UInt8($0 % 251) })
        let chunks = NUS.chunks(input, maxLength: 244)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 244 })
        XCTAssertEqual(chunks.reduce(Data(), +), input)
    }
}

// MARK: - Escapes

final class NUSUnescapeTests: XCTestCase {
    func testPlainTextPassesAsUTF8() {
        XCTAssertEqual(NUS.unescape("héllo"), bytes("héllo"))
    }

    func testPrintfEscapes() {
        XCTAssertEqual(NUS.unescape("a\\r\\n\\t\\0\\\\"), Data([0x61, 0x0D, 0x0A, 0x09, 0x00, 0x5C]))
    }

    func testHexEscape() {
        XCTAssertEqual(NUS.unescape("\\x41\\xff"), Data([0x41, 0xFF]))
    }

    func testUnknownEscapeIsRejected() {
        XCTAssertNil(NUS.unescape("\\q"))
    }

    func testTruncatedEscapesAreRejected() {
        XCTAssertNil(NUS.unescape("abc\\"))
        XCTAssertNil(NUS.unescape("\\x4"))
        XCTAssertNil(NUS.unescape("\\xzz"))
    }
}

// MARK: - Expect

final class NUSExpectTests: XCTestCase {
    func testMatchWithinOneChunk() {
        var e = NUSExpect(bytes("ok"))
        XCTAssertTrue(e.feed(bytes("all ok\n")))
    }

    func testMatchAcrossChunks() {
        var e = NUSExpect(bytes("hello"))
        XCTAssertFalse(e.feed(bytes("he")))
        XCTAssertFalse(e.feed(bytes("ll")))
        XCTAssertTrue(e.feed(bytes("o world")))
    }

    func testMatchOneByteAtATime() {
        var e = NUSExpect(bytes("abc"))
        let results = bytes("xxabc").map { e.feed(Data([$0])) }
        XCTAssertEqual(results, [false, false, false, false, true])
    }

    func testNoFalseMatchFromDiscardedBytes() {
        var e = NUSExpect(bytes("abc"))
        XCTAssertFalse(e.feed(bytes("ab")))
        XCTAssertFalse(e.feed(bytes("xc")))
        XCTAssertFalse(e.feed(bytes("bc")))
    }

    func testEmptyPatternMatchesAtOnce() {
        var e = NUSExpect(Data())
        XCTAssertTrue(e.feed(Data()))
    }
}

// MARK: - Session with a fake link

final class NUSSessionTests: XCTestCase {
    /// A session over streams the test drives: `deviceSends` feeds TX, and
    /// what the session writes to RX lands in `rx`.
    private func makeSession(input: [Data], inputEnds: Bool = true,
                             expect: Data? = nil, linger: TimeInterval = 0.05,
                             sendFails: Bool = false)
        -> (NUSSession, AsyncStream<Data>.Continuation, Sink, Sink) {
        let rx = Sink()
        let delivered = Sink()
        let (received, deviceSends) = AsyncStream<Data>.makeStream()
        let (inputStream, inputCont) = AsyncStream<Data>.makeStream()
        input.forEach { inputCont.yield($0) }
        if inputEnds { inputCont.finish() }
        let session = NUSSession(
            send: { data in
                if sendFails { throw NUSPortError("link down") }
                rx.append(data)
            },
            received: received,
            input: inputStream,
            deliver: { delivered.append($0) },
            expect: expect,
            linger: linger)
        return (session, deviceSends, rx, delivered)
    }

    func testInputIsSentInOrderAndSessionEndsAfterLinger() async {
        let (session, _, rx, _) = makeSession(input: [bytes("one\n"), bytes("two\n")])
        let outcome = await session.run()
        XCTAssertEqual(outcome, .inputEnded)
        XCTAssertEqual(rx.data, bytes("one\ntwo\n"))
    }

    func testReceivedBytesAreDeliveredUnchanged() async {
        let (session, deviceSends, _, delivered) = makeSession(input: [], linger: 0.3)
        deviceSends.yield(bytes("a\r\n"))
        deviceSends.yield(Data([0x00, 0xFF]))
        _ = await session.run()
        XCTAssertEqual(delivered.data, bytes("a\r\n") + Data([0x00, 0xFF]))
    }

    func testExpectMatchEndsSessionBeforeLinger() async {
        let (session, deviceSends, _, _) = makeSession(input: [bytes("ping\n")], expect: bytes("pong"), linger: 30)
        deviceSends.yield(bytes("po"))
        deviceSends.yield(bytes("ng\n"))
        let start = Date()
        let outcome = await session.run()
        XCTAssertEqual(outcome, .matched)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testExpectMissedAfterLinger() async {
        let (session, deviceSends, _, _) = makeSession(input: [bytes("ping\n")], expect: bytes("pong"), linger: 0.1)
        deviceSends.yield(bytes("nope\n"))
        let outcome = await session.run()
        XCTAssertEqual(outcome, .expectMissed)
    }

    func testDeviceDisconnectIsLinkLost() async {
        let (session, deviceSends, _, _) = makeSession(input: [], inputEnds: false)
        deviceSends.finish()
        let outcome = await session.run()
        XCTAssertEqual(outcome, .linkLost("device disconnected"))
    }

    func testWriteFailureIsLinkLost() async {
        let (session, _, _, _) = makeSession(input: [bytes("x")], inputEnds: false, sendFails: true)
        let outcome = await session.run()
        guard case .linkLost(let reason) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(reason.hasPrefix("write failed"), reason)
    }
}

// MARK: - Ports

final class NUSPortTests: XCTestCase {
    private func firstChunk(_ stream: AsyncStream<Data>) async -> Data? {
        var it = stream.makeAsyncIterator()
        return await it.next()
    }

    func testFixedPortSendsOnceThenEnds() async {
        let port = NUSPort.fixed(bytes("hi"), write: { _ in })
        var all = Data()
        for await chunk in port.input() { all.append(chunk) }
        XCTAssertEqual(all, bytes("hi"))
        // A later session (after a reconnect) finds the input already ended.
        var count = 0
        for await _ in port.input() { count += 1 }
        XCTAssertEqual(count, 0)
    }

    func testPtyBridgesBothDirections() async throws {
        let port = try NUSPort.pty()
        defer { port.close() }
        XCTAssertTrue(port.label.hasPrefix("/dev/tty"), port.label)
        let input = port.input()

        // A terminal program opens the slave path, as it would a serial port.
        let fd = open(port.label, O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        _ = write(fd, "AT\r", 3)
        let got = await firstChunk(input)
        XCTAssertEqual(got, bytes("AT\r"), "raw mode: the CR passes unchanged")

        port.write(bytes("OK\r\n"))
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &buf, buf.count)
        XCTAssertEqual(Data(buf[0..<max(n, 0)]), bytes("OK\r\n"))
    }

    func testTCPBridgesOneClientThenTheNext() async throws {
        let events = Sink()
        let port = try NUSPort.tcp(host: "127.0.0.1", port: 0, onEvent: { events.append(bytes($0 + "\n")) })
        defer { port.close() }
        let portNumber = try XCTUnwrap(UInt16(port.label.split(separator: ":").last ?? ""))
        XCTAssertNotEqual(portNumber, 0)
        let input = port.input()
        var it = input.makeAsyncIterator()

        for line in ["first\n", "second\n"] {
            let client = try connectLoopback(port: portNumber)
            _ = line.withCString { write(client, $0, strlen($0)) }
            let got = await it.next()
            XCTAssertEqual(got, bytes(line))

            port.write(bytes("echo"))
            var buf = [UInt8](repeating: 0, count: 16)
            let n = read(client, &buf, buf.count)
            XCTAssertEqual(Data(buf[0..<max(n, 0)]), bytes("echo"))
            close(client)
            // Give the port time to see the disconnect before the next client.
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        let log = String(decoding: events.data, as: UTF8.self)
        XCTAssertEqual(log.components(separatedBy: "client connected").count - 1, 2, log)
        XCTAssertTrue(log.contains("client disconnected"), log)
    }

    func testLoopbackDetection() {
        XCTAssertTrue(NUSPort.isLoopback("127.0.0.1"))
        XCTAssertTrue(NUSPort.isLoopback("::1"))
        XCTAssertTrue(NUSPort.isLoopback("localhost"))
        XCTAssertFalse(NUSPort.isLoopback("0.0.0.0"))
        XCTAssertFalse(NUSPort.isLoopback("192.168.1.2"))
    }

    private func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); throw NUSPortError("connect failed") }
        return fd
    }
}

// MARK: - Option parsing

final class NUSOptionTests: XCTestCase {
    private func parse(_ args: [String], stdin: Bool = true) throws -> NUSOptions {
        let router = makeRouter()
        return try router.parseNUSOptions(router.expandArgs(args, optionsWithValue: CommandRouter.nusOptionsWithValue),
                                          stdinAvailable: stdin)
    }

    func testDefaultsToStdioWithAutoWrites() throws {
        let o = try parse(["-n", "erxos"])
        XCTAssertEqual(o.endpoint, .stdio)
        XCTAssertNil(o.expect)
        XCTAssertEqual(o.linger, NUSOptions.defaultLinger)
        XCTAssertEqual(o.writeType, .auto)
        XCTAssertFalse(o.reconnect)
    }

    func testWithoutStdinListensOnly() throws {
        XCTAssertEqual(try parse([], stdin: false).endpoint, .fixed(Data()))
    }

    func testSendsAreJoinedWithEscapesDecoded() throws {
        let o = try parse(["-s", "a\\n", "--send", "b\\r\\n"])
        XCTAssertEqual(o.endpoint, .fixed(bytes("a\nb\r\n")))
    }

    func testExpectDefaultsToFiveSecondDeadline() throws {
        let o = try parse(["-s", "ping\\n", "-e", "pong"])
        XCTAssertEqual(o.expect, bytes("pong"))
        XCTAssertEqual(o.linger, NUSOptions.defaultExpectTimeout)
        XCTAssertEqual(try parse(["-e", "x", "-d", "2.5"]).linger, 2.5)
    }

    func testFileContentsAreSentUnchanged() throws {
        let path = NSTemporaryDirectory() + "blew-nus-\(UUID().uuidString)"
        try Data([0x00, 0x0D, 0x0A]).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(try parse(["--file", path]).endpoint, .fixed(Data([0x00, 0x0D, 0x0A])))
    }

    func testPtyAndListen() throws {
        XCTAssertEqual(try parse(["--pty"]).endpoint, .pty)
        XCTAssertEqual(try parse(["-l", "7000"]).endpoint, .tcp(host: "127.0.0.1", port: 7000))
        XCTAssertEqual(try parse(["--listen", "7000", "--bind", "0.0.0.0"]).endpoint, .tcp(host: "0.0.0.0", port: 7000))
    }

    func testFlags() throws {
        let o = try parse(["--reconnect", "-w"])
        XCTAssertTrue(o.reconnect)
        XCTAssertEqual(o.writeType, .withoutResponse)
        XCTAssertEqual(try parse(["-r"]).writeType, .withResponse)
    }

    func testInvalidCombinationsAreRejected() {
        let bad: [[String]] = [
            ["--send", "x", "--pty"],
            ["--pty", "--listen", "7000"],
            ["--file", "/nonexistent/blew-nus"],
            ["--bind", "0.0.0.0"],
            ["--listen", "notaport"],
            ["--pty", "--expect", "x"],
            ["--listen", "7000", "--expect", "x"],
            ["--send", "\\q"],
            ["-d", "-1"],
            ["-d", "soon"],
            ["-r", "-w"],
            ["stray"],
        ]
        for args in bad {
            XCTAssertThrowsError(try parse(args), "\(args) should be rejected")
        }
    }

    func testOptionValuesAreNeverReadAsOptions() throws {
        XCTAssertEqual(try parse(["-p", "--file=/etc/hosts"]).endpoint, .stdio)
        XCTAssertEqual(try parse(["-n", "--pty"]).endpoint, .stdio)
        XCTAssertEqual(try parse(["-s", "--listen=7000"]).endpoint, .fixed(bytes("--listen=7000")))
    }

    func testDurationMustBeFiniteAndBounded() {
        for text in ["inf", "nan", "1e30"] {
            XCTAssertThrowsError(try parse(["-d", text]), "-d \(text) should be rejected")
        }
    }

    func testTargetingDefaultsToTheNUSServiceFilter() {
        XCTAssertEqual(try parse(["-p", "only"]).targeting, ["-p", "only", "-S", NUS.service])
        XCTAssertEqual(try parse(["-n", "erxos"]).targeting, ["-n", "erxos"])
        XCTAssertEqual(try parse(["--id=ABC"]).targeting, ["--id=ABC"])
        XCTAssertEqual(try parse(["-S", "180D"]).targeting, ["-S", "180D"])
        XCTAssertEqual(try parse(["-p", "-n"]).targeting, ["-p", "-n", "-S", NUS.service])
        XCTAssertEqual(try parse(["-e", "--name=x"]).targeting, ["-e", "--name=x", "-S", NUS.service])
    }

    func testDispatchRejectsBadOptionsWithoutTouchingBluetooth() {
        let result = makeRouter(interactive: true).dispatch("nus --pty --expect x")
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
    }
}

// MARK: - Reconnect decisions

final class NUSStepTests: XCTestCase {
    private let failed = BlewExitCode.operationFailed.code

    func testConnectFailureRetriesOnlyUnderReconnectAfterAFirstConnection() {
        XCTAssertTrue(NUSOptions.retries(afterConnectFailure: failed, reconnect: true, connectedOnce: true))
        XCTAssertFalse(NUSOptions.retries(afterConnectFailure: failed, reconnect: true, connectedOnce: false))
        XCTAssertFalse(NUSOptions.retries(afterConnectFailure: failed, reconnect: false, connectedOnce: true))
    }

    func testCtrlCDuringAReconnectScanEnds() {
        XCTAssertFalse(NUSOptions.retries(afterConnectFailure: 130, reconnect: true, connectedOnce: true))
    }

    func testDisconnectReconnectsOnlyUnderReconnect() {
        let lost = NUSOutcome.linkLost("device disconnected")
        XCTAssertEqual(NUSOptions.step(after: lost, stillConnected: false, linger: 1, reconnect: true), .reconnect)
        XCTAssertEqual(NUSOptions.step(after: lost, stillConnected: false, linger: 1, reconnect: false),
                       .finish(exitCode: failed, error: "device disconnected"))
    }

    func testFailureWhileStillConnectedEndsEvenUnderReconnect() {
        let failure = NUSOutcome.linkLost("write failed: busy")
        XCTAssertEqual(NUSOptions.step(after: failure, stillConnected: true, linger: 1, reconnect: true),
                       .finish(exitCode: failed, error: "write failed: busy"))
    }

    func testSessionEnds() {
        XCTAssertEqual(NUSOptions.step(after: nil, stillConnected: true, linger: 1, reconnect: true),
                       .finish(exitCode: 130, error: nil))
        XCTAssertEqual(NUSOptions.step(after: .matched, stillConnected: true, linger: 1, reconnect: true),
                       .finish(exitCode: 0, error: nil))
        XCTAssertEqual(NUSOptions.step(after: .expectMissed, stillConnected: true, linger: 2, reconnect: true),
                       .finish(exitCode: BlewExitCode.timeout.code, error: "expected text not received within 2.0s"))
    }
}

// MARK: - sub deadline

final class SubDeadlineTests: XCTestCase {
    func testDurationEndsASubscriptionThatReceivesNothing() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let start = Date()
        await CommandRouter.forEachNotification(stream, maxCount: nil, duration: 0.2) { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        continuation.finish()
    }

    func testCountEndsTheSubscription() async {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        for byte in 0..<5 { continuation.yield(Data([UInt8(byte)])) }
        let sink = Sink()
        await CommandRouter.forEachNotification(stream, maxCount: 3, duration: nil) { sink.append($0) }
        XCTAssertEqual(sink.data, Data([0, 1, 2]))
    }

    func testHugeDurationsAreRejectedBeforeBluetooth() {
        for command in ["sub -d 1e30 2A19", "sub -d inf 2A19", "sleep inf", "sleep 1e30", "scan -t inf", "scan -t -1"] {
            let result = makeRouter(interactive: true).dispatch(command)
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code, command)
        }
    }
}

// MARK: - CLI parsing

final class NUSCLIParsingTests: XCTestCase {
    func testNUSSubcommandParses() throws {
        _ = try Blew.parseAsRoot(["nus"])
        _ = try Blew.parseAsRoot(["nus", "-n", "erxos", "-s", "ping\\n", "-e", "ping", "-d", "3"])
        _ = try Blew.parseAsRoot(["nus", "--pty", "--reconnect"])
        _ = try Blew.parseAsRoot(["nus", "-l", "7000", "--bind", "0.0.0.0", "-w"])
        _ = try Blew.parseAsRoot(["nus", "--file", "/tmp/x", "-r"])
    }

    func testInvalidPortIsRejected() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["nus", "-l", "70000"]))
    }
}

// MARK: - MCP

#if MCP_ENABLED
import MCP

final class NUSMCPTests: XCTestCase {
    func testBuildNUSOptions() throws {
        let o = try BlewMCPServer().buildNUSOptions([
            "name": .string("erxos"), "send": .string("ping\n"), "expect": .string("ping"),
            "duration": .double(2), "with_response": .bool(false),
        ])
        XCTAssertEqual(o.targeting, ["-n", "erxos"])
        XCTAssertEqual(o.endpoint, .fixed(Data("ping\n".utf8)))
        XCTAssertEqual(o.expect, Data("ping".utf8))
        XCTAssertEqual(o.linger, 2)
        XCTAssertEqual(o.writeType, .withoutResponse)
    }

    func testFreeTextFieldsNeverBecomeOptions() throws {
        let o = try BlewMCPServer().buildNUSOptions(["pick": .string("--file=/etc/hosts")])
        XCTAssertEqual(o.endpoint, .fixed(Data()), "the pick value was read as --file")
        XCTAssertEqual(o.targeting, ["-p", "--file=/etc/hosts", "-S", NUS.service])
    }

    func testNUSOutputIsOneTranscript() throws {
        let output: [CommandOutput] = [
            .nusStatus(NUSStatus(event: "connected", detail: "erxos")),
            .nusData(NUSData(timestamp: "t1", data: Data("pi".utf8))),
            .nusData(NUSData(timestamp: "t2", data: Data("ng\n".utf8))),
        ]
        guard case .nus(let transcript) = BlewMCPServer().encodeStructuredContent(output) else {
            return XCTFail("expected a nus transcript")
        }
        XCTAssertEqual(transcript, NUSTranscript(received: "ping\n", receivedHex: "70696e670a"))
        let json = try JSONEncoder().encode(StructuredResult.nus(transcript))
        guard case .nus(let back) = try JSONDecoder().decode(StructuredResult.self, from: json) else {
            return XCTFail("round trip lost the type")
        }
        XCTAssertEqual(back, transcript)
    }
}
#endif
