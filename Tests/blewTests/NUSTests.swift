import XCTest
@testable import BLEManager
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

// MARK: - Input buffer

final class NUSInputBufferTests: XCTestCase {
    /// Take every piece the buffer gives, consuming each.
    private func drain(_ buffer: NUSInputBuffer, maxLength: Int) async throws -> [Data] {
        var pieces: [Data] = []
        while let piece = try await buffer.next(maxLength: maxLength) {
            pieces.append(piece.data)
            buffer.consume(piece)
        }
        return pieces
    }

    func testPiecesAreAtMostMaxLengthAndNeverSpanTwoReads() async throws {
        let buffer = NUSInputBuffer(capacity: 1024)
        buffer.append(bytes("abcdefg"))
        buffer.append(bytes("hi"))
        buffer.end()
        let pieces = try await drain(buffer, maxLength: 3)
        XCTAssertEqual(pieces, [bytes("abc"), bytes("def"), bytes("g"), bytes("hi")])
    }

    func testRejoinedPiecesEqualInput() async throws {
        let input = Data((0..<1000).map { UInt8($0 % 251) })
        let buffer = NUSInputBuffer(capacity: 4096)
        buffer.append(Data(bytes("xx").dropFirst(2)) + input)
        buffer.end()
        let pieces = try await drain(buffer, maxLength: 244)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 244 })
        XCTAssertEqual(pieces.reduce(Data(), +), input)
        XCTAssertEqual(buffer.pendingCount, 0)
    }

    func testNextLeavesBytesUntilConsumed() async throws {
        let buffer = NUSInputBuffer(capacity: 1024)
        buffer.append(bytes("abcd"))
        let taken = try await buffer.next(maxLength: 2)
        let first = try XCTUnwrap(taken)
        let again = try await buffer.next(maxLength: 2)
        XCTAssertEqual(first.data, bytes("ab"))
        XCTAssertEqual(again?.data, bytes("ab"), "a piece not consumed is given again")
        buffer.consume(first)
        let rest = try await buffer.next(maxLength: 8)
        XCTAssertEqual(rest?.data, bytes("cd"))
        XCTAssertEqual(buffer.pendingCount, 2)
    }

    /// A TCP client left: its bytes are dropped, and the write of a piece
    /// taken before that removes nothing of what the next client sends.
    func testDiscardDropsHeldBytesAndStalePiecesConsumeNothing() async throws {
        let buffer = NUSInputBuffer(capacity: 1024)
        buffer.append(bytes("secret"))
        let taken = try await buffer.next(maxLength: 4)
        let inFlight = try XCTUnwrap(taken)
        XCTAssertEqual(buffer.discard(), 6)
        buffer.append(bytes("next"))
        buffer.consume(inFlight)
        let front = try await buffer.next(maxLength: 8)
        XCTAssertEqual(front?.data, bytes("next"))
    }

    func testNextWaitsForInputAndEndsWhenCancelled() async throws {
        let buffer = NUSInputBuffer(capacity: 1024)
        let waiting = Task { try await buffer.next(maxLength: 8) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("a cancelled wait returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let woken = Task { try await buffer.next(maxLength: 8) }
        try await Task.sleep(nanoseconds: 50_000_000)
        buffer.append(bytes("x"))
        let got = try await woken.value
        XCTAssertEqual(got?.data, bytes("x"))
    }
}

// MARK: - Dropped device bytes

final class NUSDropTallyTests: XCTestCase {
    func testEachRunOfLossesIsReportedOnceAndAllAreCounted() {
        var tally = NUSDropTally()
        XCTAssertNil(tally.record(offered: 10, delivered: 10))
        XCTAssertEqual(tally.record(offered: 10, delivered: 4), 6, "a run starts")
        XCTAssertNil(tally.record(offered: 10, delivered: 0), "the run goes on")
        XCTAssertNil(tally.record(offered: 5, delivered: 5), "delivery resumes")
        XCTAssertEqual(tally.record(offered: 5, delivered: 0), 5, "a new run")
        XCTAssertEqual(tally.total, 21)
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
        -> (NUSSession, NotificationSink, Sink, Sink) {
        let rx = Sink()
        let delivered = Sink()
        let buffer = NUSInputBuffer(capacity: 1024)
        input.forEach { buffer.append($0) }
        if inputEnds { buffer.end() }
        let (session, deviceSends) = makeSession(input: buffer, expect: expect, linger: linger,
                                                 deliver: { delivered.append($0) }) { data in
            if sendFails { throw NUSPortError("link down") }
            rx.append(data)
        }
        return (session, deviceSends, rx, delivered)
    }

    private func makeSession(input: NUSInputBuffer, maxLength: Int = 64, writeTimeout: TimeInterval = 5,
                             expect: Data? = nil, linger: TimeInterval = 0.05,
                             deliver: @escaping @Sendable (Data) -> Void = { _ in },
                             send: @escaping @Sendable (Data) async throws -> Void)
        -> (NUSSession, NotificationSink) {
        let received = NotificationStream {}
        let deviceSends = received.sink
        let session = NUSSession(send: send, maxLength: maxLength, writeTimeout: writeTimeout,
                                 received: received, input: input, deliver: deliver,
                                 expect: expect, linger: linger)
        return (session, deviceSends)
    }

    /// `--reconnect` with `--send` or piped input: the piece whose write the
    /// lost link failed, and everything after it, go out on the next
    /// connection, and the command ends only once they did.
    func testInputALostLinkLeftUnsentIsSentByTheNextSession() async {
        let port = NUSPort.fixed(bytes("abcdef"), write: { _ in })
        let sentFirst = Sink()
        let (first, _) = makeSession(input: port.input(), maxLength: 2) { piece in
            if !sentFirst.data.isEmpty { throw BLEError.connectionFailed("disconnected") }
            sentFirst.append(piece)
        }
        let lost = await first.run()
        XCTAssertEqual(lost, .linkLost("write failed: Connection failed: disconnected",
                                       exitCode: BlewExitCode.operationFailed.code, linkDown: true))
        XCTAssertEqual(sentFirst.data, bytes("ab"))
        XCTAssertEqual(port.unsentCount, 4)
        XCTAssertEqual(NUSPort.fixed(bytes("abcdef"), write: { _ in }).unsentCount, 6,
                       "input not read yet counts as unsent")

        let sentSecond = Sink()
        let (second, _) = makeSession(input: port.input(), maxLength: 2) { sentSecond.append($0) }
        let outcome = await second.run()
        XCTAssertEqual(outcome, .inputEnded)
        XCTAssertEqual(sentSecond.data, bytes("cdef"))
        XCTAssertEqual(port.unsentCount, 0)
    }

    /// A write the device never completes ends the session with a timeout
    /// (exit code 4) after the write timeout, not never.
    func testAWriteThatNeverCompletesTimesOut() async {
        let buffer = NUSInputBuffer(capacity: 1024)
        buffer.append(bytes("x"))
        let (session, _) = makeSession(input: buffer, writeTimeout: 0.2) { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let start = Date()
        let outcome = await session.run()
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(outcome, .linkLost("write failed: Operation timed out", exitCode: BlewExitCode.timeout.code))
        XCTAssertEqual(buffer.pendingCount, 1, "the timed-out piece is not consumed")
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
        deviceSends.finish(throwing: BLEError.connectionFailed("disconnected"))
        let outcome = await session.run()
        XCTAssertEqual(outcome, .linkLost("Connection failed: disconnected",
                                          exitCode: BlewExitCode.operationFailed.code, linkDown: true))
    }

    func testWriteFailureIsLinkLost() async {
        let (session, _, _, _) = makeSession(input: [bytes("x")], inputEnds: false, sendFails: true)
        let outcome = await session.run()
        guard case .linkLost(let reason, _, _) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(reason.hasPrefix("write failed"), reason)
    }

    /// Bluetooth becoming unavailable ends the TX stream with
    /// bluetoothUnavailable, and `nus` without `--reconnect` exits 3.
    func testBluetoothUnavailableEndsTheSessionWithExitCode3() async {
        let (session, deviceSends, _, _) = makeSession(input: [], inputEnds: false)
        deviceSends.finish(throwing: BLEError.bluetoothUnavailable("Bluetooth is powered off"))
        let outcome = await session.run()
        XCTAssertEqual(outcome, .linkLost("Bluetooth unavailable: Bluetooth is powered off",
                                          exitCode: BlewExitCode.bluetoothUnavailable.code, linkDown: true))
        XCTAssertEqual(NUSOptions.step(after: outcome, stillConnected: false, linger: 1, reconnect: false),
                       .finish(exitCode: BlewExitCode.bluetoothUnavailable.code,
                               error: "Bluetooth unavailable: Bluetooth is powered off"))
    }
}

// MARK: - Ports

final class NUSPortTests: XCTestCase {
    /// The next read from the port's input, consumed.
    private func nextRead(_ input: NUSInputBuffer) async throws -> Data? {
        guard let piece = try await input.next(maxLength: 4096) else { return nil }
        input.consume(piece)
        return piece.data
    }

    func testFixedPortSendsOnceThenEnds() async throws {
        let port = NUSPort.fixed(bytes("hi"), write: { _ in })
        let first = try await nextRead(port.input())
        XCTAssertEqual(first, bytes("hi"))
        // A later session (after a reconnect) finds the input ended.
        let later = try await nextRead(port.input())
        XCTAssertNil(later)
    }

    /// A source faster than the device: the reader stops once the buffer
    /// holds its capacity, and reads again when a session consumes.
    func testReaderStopsWhileTheInputBufferIsFull() async throws {
        let reads = Locked(0)
        let closed = Locked(false)
        let port = NUSPort(label: "test", capacity: 4 * 4096, read: {
            if closed.value { return nil }
            reads.withValue { $0 += 1 }
            return Data(count: 4096)
        }, write: { $0.count }, close: { closed.set(true) })
        defer { port.close() }
        let input = port.input()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(reads.value, 4)
        XCTAssertEqual(port.unsentCount, 4 * 4096)

        _ = try await nextRead(input)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(reads.value, 5, "consuming makes room for one more read")
    }

    /// A pty nobody reads, and a TCP listener with no client: bytes from
    /// the device that do not fit are counted, and the first loss of each
    /// run is reported.
    func testBytesTheLocalEndDoesNotTakeAreCounted() throws {
        let pty = try NUSPort.pty()
        defer { pty.close() }
        let big = Data(count: 1 << 20)
        let firstLoss = try XCTUnwrap(pty.deliver(big), "a full pty drops bytes")
        XCTAssertGreaterThan(firstLoss, 0)
        XCTAssertNil(pty.deliver(big), "the same run is reported once")
        XCTAssertEqual(pty.droppedCount, firstLoss + big.count)

        let tcp = try NUSPort.tcp(host: "127.0.0.1", port: 0, onEvent: { _ in })
        defer { tcp.close() }
        XCTAssertEqual(tcp.deliver(bytes("hello")), 5, "no client takes nothing")
        XCTAssertEqual(tcp.droppedCount, 5)
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
        let got = try await nextRead(input)
        XCTAssertEqual(got, bytes("AT\r"), "raw mode: the CR passes unchanged")

        _ = port.deliver(bytes("OK\r\n"))
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

        for line in ["first\n", "second\n"] {
            let client = try connectLoopback(port: portNumber)
            _ = line.withCString { write(client, $0, strlen($0)) }
            let got = try await nextRead(input)
            XCTAssertEqual(got, bytes(line))

            _ = port.deliver(bytes("echo"))
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
        XCTAssertEqual(try parse(["-i", "--file=/etc/hosts"]).endpoint, .stdio)
        XCTAssertThrowsError(try parse(["-p", "--file=/etc/hosts"]), "a pick value is checked, not read as --file")
        XCTAssertEqual(try parse(["-n", "--pty"]).endpoint, .stdio)
        XCTAssertEqual(try parse(["-s", "--listen=7000"]).endpoint, .fixed(bytes("--listen=7000")))
    }

    func testDurationMustBeFiniteAndBounded() {
        for text in ["inf", "nan", "1e30"] {
            XCTAssertThrowsError(try parse(["-d", text]), "-d \(text) should be rejected")
        }
    }

    /// The NUS service filter is applied by `ensureConnected` only when the
    /// targeting names no device (see AutoConnectPlanTests), so the targeting
    /// passes through unchanged; its values are checked before any endpoint opens.
    func testTargetingIsCheckedAndPassedThrough() throws {
        XCTAssertEqual(try parse(["-p", "only"]).targeting, ["-p", "only"])
        XCTAssertEqual(try parse(["-n", "erxos"]).targeting, ["-n", "erxos"])
        XCTAssertEqual(try parse(["-e", "--name=x"]).targeting, ["-e", "--name=x"])
        XCTAssertThrowsError(try parse(["-p", "-n"]))
        XCTAssertThrowsError(try parse(["-S", "not-a-uuid"]))
        XCTAssertEqual(BLENames.canonicalUUID(NUS.service), NUS.service,
                       "the default filter compares canonical UUIDs")
        XCTAssertEqual(NUSOptions.deviceFilter, DeviceFilter(services: [NUS.service]))
    }

    /// An option that takes a value is refused without it or when given
    /// twice, never read as absent; every refused option is exit code 6.
    func testValueOptionsNeedTheirValueOnce() {
        let bad: [[String]] = [
            ["-s"], ["--send"], ["-s", "x", "-s"], ["-d"], ["-e"], ["--file"], ["-l"], ["--listen", "7000", "--bind"],
            ["--file", "a", "--file", "b"], ["-e", "a", "-e", "b"], ["-d", "1", "-d", "2"],
        ]
        for args in bad {
            XCTAssertThrowsError(try parse(args, stdin: false), "\(args) should be rejected") { error in
                XCTAssertEqual(BlewExitCode(for: error).code, BlewExitCode.invalidArguments.code, "\(args): \(error)")
            }
        }
    }

    func testRefusedOptionsMapToTheInvalidArgumentsCode() {
        for args in [["stray"], ["--listen", "notaport"], ["-r", "-w"], ["--send", "\\q"], ["-S", "not-a-uuid"]] {
            XCTAssertThrowsError(try parse(args)) { error in
                XCTAssertEqual(BlewExitCode(for: error).code, BlewExitCode.invalidArguments.code, "\(args): \(error)")
            }
        }
    }

    func testDispatchRejectsBadOptionsWithoutTouchingBluetooth() {
        let result = makeRouter(interactive: true).dispatch("nus --pty --expect x")
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
    }
}

// MARK: - Reconnect decisions

final class NUSStepTests: XCTestCase {
    private let failed = BlewExitCode.operationFailed.code

    /// A lost link takes the exit code `BlewExitCode(for:)` gives its error.
    func testLinkLostTakesTheSharedExitCode() {
        guard case .linkLost(let reason, let exitCode, let linkDown) =
                NUSOutcome.linkLost("write failed", InvalidArgument("value too long")) else {
            return XCTFail("not a lost link")
        }
        XCTAssertEqual(reason, "write failed: value too long")
        XCTAssertEqual(exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertFalse(linkDown)
        guard case .linkLost(_, let otherCode, _) = NUSOutcome.linkLost(nil, NUSPortError("closed")) else {
            return XCTFail("not a lost link")
        }
        XCTAssertEqual(otherCode, failed)
    }

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

    /// A write failed by the disconnect (or after it) reconnects even when
    /// the connection state has not caught up with the disconnect yet.
    func testWriteErrorFromALostLinkReconnects() {
        for error in [BLEError.connectionFailed("disconnected"), .notConnected] {
            let outcome = NUSOutcome.linkLost("write failed", error)
            XCTAssertEqual(NUSOptions.step(after: outcome, stillConnected: true, linger: 1, reconnect: true),
                           .reconnect, "\(error)")
        }
        let timedOut = NUSOutcome.linkLost("write failed", BLEError.timeout)
        XCTAssertEqual(NUSOptions.step(after: timedOut, stillConnected: true, linger: 1, reconnect: true),
                       .finish(exitCode: BlewExitCode.timeout.code, error: "write failed: Operation timed out"))
    }

    /// A write error the disconnect report follows: the settle wait sees
    /// the link go down and the step reconnects.
    func testSettleWaitSeesALateDisconnect() async {
        let probes = Locked(0)
        let up = await NUSOptions.linkStaysUp(for: 5, interval: 0.01) {
            probes.withValue { $0 += 1; return $0 < 3 }
        }
        XCTAssertFalse(up)
        XCTAssertEqual(probes.value, 3)
        let failure = NUSOutcome.linkLost("write failed", BLEError.writeFailed("connection timed out"))
        XCTAssertEqual(NUSOptions.step(after: failure, stillConnected: up, linger: 1, reconnect: true), .reconnect)
    }

    func testSettleWaitEndsWhenTheLinkStaysUp() async {
        let start = Date()
        let up = await NUSOptions.linkStaysUp(for: 0.1, interval: 0.01) { true }
        XCTAssertTrue(up)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Without `--reconnect`, a lost link with input left over fails and
    /// says how much was not sent.
    func testUnsentInputIsReported() {
        XCTAssertEqual(NUSOptions.step(after: .linkLost("device disconnected"), stillConnected: false,
                                       linger: 1, reconnect: false, unsent: 12),
                       .finish(exitCode: failed, error: "device disconnected (at least 12 bytes of input not sent)"))
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
    func testDurationEndsASubscriptionThatReceivesNothing() async throws {
        let stream = NotificationStream {}
        let continuation = stream.sink
        let start = Date()
        try await CommandRouter.forEachNotification(stream, maxCount: nil, duration: 0.2) { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        continuation.finish()
    }

    func testCountEndsTheSubscription() async throws {
        let stream = NotificationStream {}
        let continuation = stream.sink
        for byte in 0..<5 { continuation.yield(Data([UInt8(byte)])) }
        let sink = Sink()
        try await CommandRouter.forEachNotification(stream, maxCount: 3, duration: nil) { sink.append($0) }
        XCTAssertEqual(sink.data, Data([0, 1, 2]))
    }

    /// The connection ending (a disconnect, Bluetooth going off) ends `sub`
    /// with the stream's error, whose exit code the command reports.
    func testTheStreamsErrorEndsTheSubscription() async {
        let stream = NotificationStream {}
        let continuation = stream.sink
        continuation.yield(Data([1]))
        continuation.finish(throwing: BLEError.bluetoothUnavailable("Bluetooth is powered off"))
        let sink = Sink()
        do {
            try await CommandRouter.forEachNotification(stream, maxCount: nil, duration: 5) { sink.append($0) }
            XCTFail("the subscription ended without the stream's error")
        } catch let error as BLEError {
            XCTAssertEqual(error.exitCode, BlewExitCode.bluetoothUnavailable.code)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(sink.data, Data([1]))
    }

    /// Notifications that came faster than `sub` wrote them out are
    /// reported: once when the first drops are seen, and with the total when
    /// the subscription ends if more were dropped after that.
    func testDroppedNotificationsAreReported() async throws {
        let stream = NotificationStream {}
        let capacity = NotificationStream.capacity
        for i in 0..<(capacity + 10) { stream.sink.yield(Data([UInt8(i & 0xFF)])) }
        let reports = Locked<[Int]>([])
        let handled = Locked(0)
        try await CommandRouter.forEachNotification(stream, maxCount: capacity + 1, duration: nil,
                                                    dropped: { total in reports.withValue { $0.append(total) } }) { _ in
            // The first value read: more come while the reader is busy.
            if handled.withValue({ $0 += 1; return $0 }) == 1 {
                for _ in 0..<5 { stream.sink.yield(Data([0])) }
            }
        }
        XCTAssertEqual(reports.value, [10, 14], "the drops were not reported at the first loss and in total at the end")
    }

    func testNoDropsNoReport() async throws {
        let stream = NotificationStream {}
        for byte in 0..<3 { stream.sink.yield(Data([UInt8(byte)])) }
        let reports = Locked<[Int]>([])
        try await CommandRouter.forEachNotification(stream, maxCount: 3, duration: nil,
                                                    dropped: { total in reports.withValue { $0.append(total) } }) { _ in }
        XCTAssertEqual(reports.value, [])
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
        let o = try BlewMCPServer().buildNUSOptions(["pick": .string("first"), "name": .string("--file=/etc/hosts")])
        XCTAssertEqual(o.endpoint, .fixed(Data()), "the name value was read as --file")
        XCTAssertEqual(o.targeting, ["-n", "--file=/etc/hosts", "-p", "first"])
        XCTAssertThrowsError(try BlewMCPServer().buildNUSOptions(["pick": .string("--file=/etc/hosts")]),
                             "a pick value is checked")
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
