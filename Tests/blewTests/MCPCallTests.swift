#if MCP_ENABLED
import XCTest
import Foundation
import MCP
import BLEManager
@testable import blew

extension BlewMCPServer {
    /// A server with no global options, as `blew mcp` starts one.
    convenience init() {
        self.init(globals: try! GlobalOptions.parse([]))
    }
}

/// Argument validation, time budgets, serialization and cancellation of
/// MCP tool calls. None of these calls reaches a device: each one fails
/// validation, or runs synthetic work on the tool-call queue.
final class MCPArgumentValidationTests: XCTestCase {

    private func call(_ name: String, _ args: [String: Value]) async throws -> CallTool.Result {
        try await BlewMCPServer().handleToolCall(CallTool.Parameters(name: name, arguments: args))
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { item -> String? in
            if case .text(let t, _, _) = item { return t }
            return nil
        }.joined()
    }

    func testStringDurationIsAnError() async throws {
        let result = try await call("ble_subscribe", ["char_uuid": .string("2A19"), "duration": .string("5")])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("duration"), text(result))
    }

    func testStringCountIsAnError() async throws {
        let result = try await call("ble_subscribe", ["char_uuid": .string("2A19"), "count": .string("3")])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("count"), text(result))
    }

    func testSubscribeWithoutDurationUsesTheDefaultBound() throws {
        let args = BlewMCPServer().buildSubArgs(["char_uuid": .string("2A19")])
        XCTAssertEqual(args.firstIndex(of: "-d").map { Double(args[$0 + 1]) }, 10)
        XCTAssertFalse(args.contains("-c"))
        let command = try BlewMCPServer().makeCommand("ble_subscribe", ["char_uuid": .string("2A19")])
        XCTAssertEqual(command.duration, BlewMCPServer.defaultSubscribeDuration)
    }

    func testDurationOverTheMaximumIsAnError() async throws {
        let result = try await call("ble_subscribe", ["char_uuid": .string("2A19"), "duration": .int(301)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("'duration' must be at most 300"), text(result))
    }

    func testZeroCountIsAnError() async throws {
        let result = try await call("ble_subscribe", ["char_uuid": .string("2A19"), "count": .int(0)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("'count' must be at least 1"), text(result))
    }

    func testUnknownArgumentIsAnError() async throws {
        let result = try await call("ble_subscribe", ["char_uuid": .string("2A19"), "durration": .int(5)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("unknown argument \"durration\""), text(result))
    }

    func testValidatorChecksArrayItemsAndEnums() throws {
        let advertise = try XCTUnwrap(BlewMCPServer.toolDefinitions.first { $0.name == "ble_periph_advertise" })
        XCTAssertThrowsError(try ToolArguments.validate(["services": .array([.string("180D"), .int(6159)])],
                                                        against: advertise.inputSchema)) { error in
            XCTAssertEqual(error as? ToolArgumentError, ToolArgumentError(message: "'services[1]' must be a string"))
        }
        let read = try XCTUnwrap(BlewMCPServer.toolDefinitions.first { $0.name == "ble_read" })
        XCTAssertThrowsError(try ToolArguments.validate(["char_uuid": .string("2A19"), "pick": .string("best")],
                                                        against: read.inputSchema))
        XCTAssertNoThrow(try ToolArguments.validate(["char_uuid": .string("2A19"), "pick": .string("only")],
                                                    against: read.inputSchema))
    }

    func testManufacturerIsAnIntegerCompanyIdentifierInEveryTool() throws {
        for name in ["ble_scan", "ble_connect", "ble_read"] {
            let tool = try XCTUnwrap(BlewMCPServer.toolDefinitions.first { $0.name == name })
            var base: [String: Value] = name == "ble_read" ? ["char_uuid": .string("2A19")] : [:]
            base["manufacturer"] = .int(76)
            XCTAssertNoThrow(try ToolArguments.validate(base, against: tool.inputSchema), name)
            for bad: Value in [.string("0x004C"), .int(65536), .int(-1)] {
                base["manufacturer"] = bad
                XCTAssertThrowsError(try ToolArguments.validate(base, against: tool.inputSchema), "\(name) \(bad)")
            }
        }
    }

    func testGlobalOptionsReachTheRouter() throws {
        let server = BlewMCPServer(globals: try GlobalOptions.parse(["-t", "30", "-v"]))
        XCTAssertEqual(server.router.globals.timeout, 30)
        XCTAssertEqual(server.router.globals.verbose, 1)
        // A longer -t widens the setup allowance of every call.
        XCTAssertEqual(server.callBudget(ToolCommand(duration: 5) { _ in CommandResult() }), 125)
    }

    func testCollectorDropsWhatArrivesAfterTheCallReturned() {
        let collector = StreamCollector()
        collector.collect(.message("during"))
        XCTAssertEqual(collector.close().count, 1)
        collector.collect(.message("after"))
        XCTAssertTrue(collector.close().isEmpty)
    }
}

/// Polls `condition` until it holds or `seconds` pass.
private func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

final class ToolCallQueueTests: XCTestCase {

    /// Work that runs until it is asked to stop, at most `limit` seconds.
    private func untilStopped(_ stop: StopRequest, limit: TimeInterval = 10) -> String {
        let deadline = Date().addingTimeInterval(limit)
        while stop.reason == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return "stopped"
    }

    func testConcurrentCallsNeverOverlap() async {
        let queue = ToolCallQueue()
        let log = Locked<[String]>([])
        let running = Locked(0)
        func work(_ name: String) -> (StopRequest) -> String {
            return { _ in
                running.withValue { $0 += 1 }
                log.withValue { $0.append("start \(name)") }
                XCTAssertEqual(running.value, 1, "\(name) overlapped another call")
                Thread.sleep(forTimeInterval: 0.1)
                log.withValue { $0.append("end \(name)") }
                running.withValue { $0 -= 1 }
                return name
            }
        }
        let first = Task { await queue.run(budget: 60, work("A")) }
        XCTAssertTrue(eventually { log.value.contains("start A") })
        // B and C race to the queue; each starts only after the one before
        // it has ended, whichever comes first.
        let second = Task { await queue.run(budget: 60, work("B")) }
        let third = Task { await queue.run(budget: 60, work("C")) }
        for call in [first, second, third] {
            guard case .finished = await call.value else { return XCTFail("a call did not finish") }
        }
        let events = log.value
        XCTAssertEqual(Array(events.prefix(2)), ["start A", "end A"])
        XCTAssertEqual(events.count, 6)
        for pair in stride(from: 0, to: events.count, by: 2) {
            let name = events[pair].dropFirst("start ".count)
            XCTAssertEqual(events[pair + 1], "end \(name)", "calls overlapped: \(events)")
        }
    }

    func testCancellingARunningCallStopsItPromptly() async {
        let queue = ToolCallQueue()
        let started = Locked(false)
        let call = Task {
            await queue.run(budget: 60) { stop -> String in
                started.set(true)
                return self.untilStopped(stop)
            }
        }
        XCTAssertTrue(eventually { started.value })
        let cancelledAt = Date()
        call.cancel()
        let outcome = await call.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
        guard case .cancelled = outcome else { return XCTFail("\(outcome)") }
    }

    func testCallCancelledWhileWaitingItsTurnDoesNotStart() async {
        let queue = ToolCallQueue()
        let blockerStarted = Locked(false)
        let releaseBlocker = Locked(false)
        let blocker = Task {
            await queue.run(budget: 60) { _ in
                blockerStarted.set(true)
                XCTAssertTrue(eventually { releaseBlocker.value })
            }
        }
        XCTAssertTrue(eventually { blockerStarted.value })
        let ran = Locked(false)
        let waiting = Task { await queue.run(budget: 60) { _ in ran.set(true) } }
        waiting.cancel()
        releaseBlocker.set(true)
        _ = await blocker.value
        let outcome = await waiting.value
        XCTAssertFalse(ran.value)
        guard case .cancelled = outcome else { return XCTFail("\(outcome)") }
    }

    /// The outcome is decided on the queue when the work returns: a
    /// cancellation that arrives after that, here while `settle` runs, does
    /// not turn a finished call into a cancelled one.
    func testCancellationAfterTheWorkReturnedDoesNotChangeTheOutcome() async {
        let queue = ToolCallQueue()
        let settling = Locked(false)
        let cancelSent = Locked(false)
        let call = Task {
            await queue.run(budget: 60) { _ in "done" } settle: { value, cancelled in
                settling.set(true)
                XCTAssertTrue(eventually { cancelSent.value })
                return cancelled ? "cancelled" : value
            }
        }
        XCTAssertTrue(eventually { settling.value })
        call.cancel()
        cancelSent.set(true)
        guard case .finished("done") = await call.value else { return XCTFail("the late cancellation changed the outcome") }
    }

    /// A client cancellation that arrives after the budget ran out, while
    /// the work is still stopping, cancels the call: the server answers a
    /// cancelled request with nothing.
    func testCancellationAfterTheBudgetRanOutCancelsTheCall() async {
        let queue = ToolCallQueue()
        let call = Task {
            await queue.run(budget: 0.1) { stop -> String in
                _ = self.untilStopped(stop)
                Thread.sleep(forTimeInterval: 0.5)
                return "stopped late"
            }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        call.cancel()
        guard case .cancelled = await call.value else { return XCTFail("the cancelled call was not cancelled") }
    }

    func testCallPastItsBudgetIsStopped() async {
        let queue = ToolCallQueue()
        let start = Date()
        let outcome = await queue.run(budget: 0.2) { stop in self.untilStopped(stop) }
        guard case .budgetExhausted = outcome else { return XCTFail("\(outcome)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: The server's side of a call

    /// A command that waits on the router until something stops it.
    private func waitingCommand() -> ToolCommand {
        ToolCommand(duration: 0) { router in
            var result = CommandResult()
            if case .interrupted = router.waitInterruptible({ try? await Task.sleep(nanoseconds: 30_000_000_000) }) {
                result.exitCode = BlewExitCode.interrupted.code
            }
            return result
        }
    }

    func testCallPastItsBudgetFailsWithTimeout() async throws {
        let start = Date()
        let result = try await BlewMCPServer().execute(waitingCommand(), name: "ble_subscribe", budget: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(result.isError, true)
        let text = result.content.compactMap { item -> String? in
            if case .text(let t, _, _) = item { return t }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("ble_subscribe did not finish within its 1-second budget"), text)
    }

    func testCancelledCallEndsPromptlyWithNoResult() async {
        let server = BlewMCPServer()
        let command = waitingCommand()
        let call = Task { try await server.execute(command, name: "ble_subscribe", budget: 60) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let cancelledAt = Date()
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("a cancelled call returned a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
    }

    func testOutOfRangeGlobalTimeoutIsRejected() {
        XCTAssertThrowsError(try GlobalOptions.parse(["-t", "1e11"]))
        XCTAssertThrowsError(try GlobalOptions.parse(["-t", "nan"]))
    }

    /// The router side of a stop: a wait inside `run(stoppingOn:)` ends as
    /// interrupted when the request is set.
    func testStopRequestEndsTheRoutersWait() throws {
        let router = CommandRouter(globals: try GlobalOptions.parse([]))
        let stop = StopRequest()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { stop.stop(.cancelled) }
        let start = Date()
        var outcome: CommandRouter.CommandOutcome?
        _ = router.run(stoppingOn: stop) {
            outcome = router.waitInterruptible { try? await Task.sleep(nanoseconds: 30_000_000_000) }
            return CommandResult()
        }
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// A stop requested before an operation starts keeps it from starting,
    /// and the wait reports interrupted.
    func testStopRequestedBeforeAnOperationKeepsItFromStarting() throws {
        let router = CommandRouter(globals: try GlobalOptions.parse([]))
        let stop = StopRequest()
        stop.stop(.cancelled)
        let ran = DispatchSemaphore(value: 0)
        var outcome: CommandRouter.CommandOutcome?
        _ = router.run(stoppingOn: stop) {
            outcome = router.waitInterruptible { ran.signal() }
            return CommandResult()
        }
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertEqual(ran.wait(timeout: .now() + 0.2), .timedOut, "an operation started after the stop")
    }

    /// A stop that arrives while an operation finishes leaves that
    /// operation's result alone (a completed write stays completed), and
    /// keeps the next operation from starting.
    func testAnOperationThatFinishesKeepsItsResultButTheNextDoesNotStart() throws {
        let router = CommandRouter(globals: try GlobalOptions.parse([]))
        let stop = StopRequest()
        var secondRan = false
        var outcomes: [CommandRouter.CommandOutcome] = []
        _ = router.run(stoppingOn: stop) {
            outcomes.append(router.waitInterruptible { stop.stop(.cancelled) })
            outcomes.append(router.waitInterruptible { secondRan = true })
            return CommandResult()
        }
        // .completed when the operation finishes before the 50 ms poll sees
        // the stop (the usual case); .interrupted if the poll wins the race.
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertNotEqual(outcomes.first, .timedOut)
        XCTAssertEqual(outcomes.last, .interrupted)
        XCTAssertFalse(secondRan)
    }

    /// A Ctrl-C that lands as a call's last step succeeds gives the call
    /// 130, as it does a one-shot command or a script command.
    func testACtrlCAsACallSucceedsGives130() throws {
        let signals = ProcessSignals()
        let router = CommandRouter(globals: try GlobalOptions.parse([]), signals: signals)
        let result = router.run(stoppingOn: StopRequest()) {
            XCTAssertNil(signals.respond(to: .interrupt), "the call had no span open")
            return CommandResult()
        }
        XCTAssertEqual(result.exitCode, BlewExitCode.interrupted.code, "the interrupted call reported success")
    }

    /// The call's own stop (its budget) leaves a success standing:
    /// `MCPServer.execute` maps the budget's outcome itself.
    func testABudgetStopLeavesASuccessStanding() throws {
        let router = CommandRouter(globals: try GlobalOptions.parse([]), signals: ProcessSignals())
        let stop = StopRequest()
        let result = router.run(stoppingOn: stop) {
            stop.stop(.budgetExhausted)
            return CommandResult()
        }
        XCTAssertEqual(result.exitCode, BlewExitCode.success.code)
    }

    /// Subscription setup waits for the device to confirm through
    /// `withDeadline`: a confirmation that never comes ends with a timeout.
    func testOperationThatNeverFinishesTimesOut() async {
        let start = Date()
        do {
            _ = try await CommandRouter.withDeadline(0.2) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return 1
            }
            XCTFail("no timeout")
        } catch {
            guard case .timeout? = error as? BLEError else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
#endif
