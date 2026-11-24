import Foundation
import BLEManager

// MARK: - nus: bridge a local port to the device's Nordic UART Service

/// The checked options of one `nus` command. `make` is the one constructor:
/// the REPL's parser, the `nus` subcommand and the MCP tool all build their
/// options through it, from typed values.
struct NUSOptions {
    enum Endpoint: Equatable {
        /// Standard input to the device, the device to standard output.
        case stdio
        /// The given bytes to the device, then listen (`--send`, `--file`,
        /// or nothing in the REPL, `exec` and MCP).
        case fixed(Data)
        /// A pseudo-terminal (`--pty`).
        case pty
        /// A TCP listener (`--listen`, `--bind`).
        case tcp(host: String, port: UInt16)
    }

    /// The device `ensureConnected` connects to. When it names no device,
    /// `nus` uses the connected device or scans for
    /// `deviceFilter`.
    var targeting: DeviceTarget
    var endpoint: Endpoint
    var expect: Data?
    /// Seconds to keep listening after the input ends; with `expect`, the
    /// deadline for the expected bytes.
    var linger: TimeInterval
    var writeType: WriteType
    var reconnect: Bool

    static let defaultLinger: TimeInterval = 1
    static let defaultExpectTimeout: TimeInterval = 5
    static let defaultBind = "127.0.0.1"

    /// The devices bare `nus` looks for: those advertising the Nordic UART Service.
    static let deviceFilter = DeviceFilter(services: [NUS.service])

    /// Check the raw values of a `nus` command and build its options.
    /// `stdinAvailable` is false in the REPL, `exec` and MCP, where standard
    /// input is not the user's to bridge. Throws an `InvalidArgument`.
    static func make(
        targeting: DeviceTarget, sends: [String] = [], file: String? = nil, expect: String? = nil,
        duration: Double? = nil, pty: Bool = false, listen: UInt16? = nil, bind: String? = nil,
        reconnect: Bool = false, withResponse: Bool = false, withoutResponse: Bool = false,
        stdinAvailable: Bool
    ) throws -> NUSOptions {
        func escaped(_ text: String, _ option: String) throws -> Data {
            guard let data = NUS.unescape(text) else {
                throw InvalidArgument("invalid escape in \(option) '\(text)' (use \\n \\r \\t \\0 \\\\ \\xHH)")
            }
            return data
        }

        let sources = [!sends.isEmpty, file != nil, pty, listen != nil].filter { $0 }.count
        guard sources <= 1 else { throw InvalidArgument("use only one of --send, --file, --pty and --listen") }
        guard bind == nil || listen != nil else { throw InvalidArgument("--bind needs --listen") }
        guard !(withResponse && withoutResponse) else {
            throw InvalidArgument("use only one of --with-response and --without-response")
        }
        if let duration, !CommandRouter.isValidDuration(duration) {
            throw InvalidArgument("invalid duration '\(duration)' (use 0 to \(Int(CommandRouter.maxDuration)) seconds)")
        }

        let endpoint: Endpoint
        if !sends.isEmpty {
            endpoint = .fixed(try sends.map { try escaped($0, "--send") }.reduce(Data(), +))
        } else if let file {
            guard let data = FileManager.default.contents(atPath: file) else {
                throw InvalidArgument("cannot read file '\(file)'")
            }
            endpoint = .fixed(data)
        } else if pty {
            endpoint = .pty
        } else if let listen {
            endpoint = .tcp(host: bind ?? defaultBind, port: listen)
        } else {
            endpoint = stdinAvailable ? .stdio : .fixed(Data())
        }

        let expected = try expect.map { try escaped($0, "--expect") }
        switch (expected, endpoint) {
        case (.some, .pty), (.some, .tcp):
            throw InvalidArgument("--expect works only with standard input/output, --send or --file")
        default: break
        }

        return NUSOptions(
            targeting: targeting,
            endpoint: endpoint,
            expect: expected,
            linger: duration ?? (expected == nil ? defaultLinger : defaultExpectTimeout),
            writeType: withResponse ? .withResponse : (withoutResponse ? .withoutResponse : .auto),
            reconnect: reconnect)
    }

    /// What `nus` does after a session.
    enum Step: Equatable {
        /// Connect again.
        case reconnect
        /// End with this exit code and, when it failed, this message.
        case finish(exitCode: Int32, error: String?)
    }

    /// After a failed connect attempt: retry (after a pause) only under
    /// `--reconnect`, once a first connection was made, and never after
    /// Ctrl-C (exit code 130); otherwise end with the attempt's own result.
    static func retries(afterConnectFailure exitCode: Int32, reconnect: Bool, connectedOnce: Bool) -> Bool {
        exitCode != BlewExitCode.interrupted.code && reconnect && connectedOnce
    }

    /// After a session: nil means interrupted. A lost link reconnects under
    /// `--reconnect` only when the connection is gone, as the error itself
    /// shows (`linkDown`) or the connection state does once it settled
    /// (`stillConnected`); a failure while still connected (a subscribe or
    /// write error, a write timeout) ends the command, since reconnecting
    /// would not change it. A failure that ends the command with input
    /// still unsent says how much (`unsent` bytes, a lower bound: a stream
    /// source may hold bytes blew has not read).
    static func step(after outcome: NUSOutcome?, stillConnected: Bool, linger: TimeInterval,
                     reconnect: Bool, unsent: Int = 0) -> Step {
        switch outcome {
        case nil:
            return .finish(exitCode: BlewExitCode.interrupted.code, error: nil)
        case .matched, .inputEnded:
            return .finish(exitCode: 0, error: nil)
        case .expectMissed:
            return .finish(exitCode: BlewExitCode.timeout.code, error: "expected text not received within \(linger)s")
        case .linkLost(let reason, let exitCode, let linkDown):
            if reconnect && (linkDown || !stillConnected) { return .reconnect }
            return .finish(exitCode: exitCode,
                           error: unsent > 0 ? "\(reason) (at least \(unsent) bytes of input not sent)" : reason)
        }
    }

    /// How long a lost link the error does not explain (a write error, a
    /// timeout) waits for the disconnect to be reported before deciding
    /// whether to reconnect. CoreBluetooth reports the failed write and the
    /// disconnect back to back, so a second covers the gap between them.
    static let linkSettleTime: TimeInterval = 1

    /// Whether the connection stays up for `window` seconds: false as soon
    /// as `isConnected` reports it down, checked every `interval` seconds.
    /// A cancelled wait ends with the last answer.
    static func linkStaysUp(for window: TimeInterval, interval: TimeInterval = 0.05,
                            isConnected: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(window)
        while true {
            guard await isConnected() else { return false }
            if Date() >= deadline || Task.isCancelled { return true }
            try? await Task.sleep(nanoseconds: UInt64(max(interval, 0.001) * 1_000_000_000))
        }
    }
}

extension NUSOutcome {
    /// The link was lost because of `error` (`context` says what was being
    /// done), with the exit code `BlewExitCode(for:)` gives it, so Bluetooth
    /// becoming unavailable ends `nus` with exit code 3. A disconnect, no
    /// connection or Bluetooth becoming unavailable shows the link is gone.
    static func linkLost(_ context: String?, _ error: Error) -> NUSOutcome {
        let message = error.localizedDescription
        let reason = context.map { "\($0): \(message)" } ?? message
        let linkDown: Bool
        switch error as? BLEError {
        case .connectionFailed, .notConnected, .bluetoothUnavailable: linkDown = true
        default: linkDown = false
        }
        return .linkLost(reason, exitCode: BlewExitCode(for: error).code, linkDown: linkDown)
    }
}

extension CommandRouter {
    /// Parse `nus` arguments from the REPL or a script. Throws an
    /// `InvalidArgument` on invalid input.
    static func parseNUSOptions(_ args: [String], stdinAvailable: Bool) throws -> NUSOptions {
        let arguments = try CommandSyntax.nus.parse(args)
        let listen = try arguments.value(.listen).map { text in
            guard let port = UInt16(text) else { throw InvalidArgument("invalid port '\(text)'") }
            return port
        }
        let duration = try arguments.value(.duration).map { text in
            guard let seconds = Double(text) else { throw InvalidArgument("invalid duration '\(text)'") }
            return seconds
        }
        return try NUSOptions.make(
            targeting: DeviceTarget(arguments),
            sends: arguments.values(.send),
            file: arguments.value(.file),
            expect: arguments.value(.expect),
            duration: duration,
            pty: arguments.flag(.pty),
            listen: listen,
            bind: arguments.value(.bind),
            reconnect: arguments.flag(.reconnect),
            withResponse: arguments.flag(.withResponse),
            withoutResponse: arguments.flag(.withoutResponse),
            stdinAvailable: stdinAvailable)
    }

    /// `nus` from the REPL or a script: parse, then bridge.
    func runNUS(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        do {
            return runNUS(try Self.parseNUSOptions(args, stdinAvailable: !isInteractiveMode), emit: emit)
        } catch {
            return CommandResult(failing: error)
        }
    }

    /// Bridge a local port to the connected device's Nordic UART Service.
    /// Streaming: bytes from the device and bridge events go to `emit`.
    func runNUS(_ options: NUSOptions, emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        var result = CommandResult()

        let status: @Sendable (String, String) -> Void = { event, detail in
            emit(.nusStatus(NUSStatus(event: event, detail: detail)))
        }
        let toOutput: @Sendable (Data) -> Void = { data in
            emit(.nusData(NUSData(timestamp: ISO8601DateFormatter.shared.string(from: Date()), data: data)))
        }
        let port: NUSPort
        do {
            switch options.endpoint {
            case .stdio: port = NUSPort.standardInput(write: toOutput)
            case .fixed(let data): port = NUSPort.fixed(data, write: toOutput)
            case .pty: port = try NUSPort.pty()
            case .tcp(let host, let number):
                if !NUSPort.isLoopback(host) {
                    renderer.renderError("warning: listening on \(host) without authentication; anyone who can reach it can talk to the device")
                }
                port = try NUSPort.tcp(host: host, port: number, onEvent: { status("client", $0) })
            }
        } catch {
            result.fail(error)
            return result
        }
        defer { port.close() }
        switch options.endpoint {
        case .pty, .tcp: status("bridge", port.label)
        case .stdio, .fixed: break
        }
        let deliver: @Sendable (Data) -> Void = { data in
            if let lost = port.deliver(data) {
                status("dropped", "\(lost) bytes from the device: the local client is not reading or not connected")
            }
        }
        let finished = bridgeNUS(options: options, port: port, deliver: deliver, status: status)
        let dropped = port.droppedCount
        if dropped > 0 { status("dropped", "\(dropped) bytes from the device in total") }
        return finished
    }

    /// The connect, session and reconnect loop of `runNUS` over `port`.
    private func bridgeNUS(options: NUSOptions, port: NUSPort, deliver: @escaping @Sendable (Data) -> Void,
                           status: @escaping @Sendable (String, String) -> Void) -> CommandResult {
        var result = CommandResult()
        // After the first connection, reconnect only to that device, never
        // to whichever device matching the filter is strongest by then.
        var targeting = options.targeting
        var connectedOnce = false
        while true {
            let connectResult = ensureConnected(to: targeting, defaultFilter: NUSOptions.deviceFilter)
            if connectResult.exitCode != 0 {
                guard NUSOptions.retries(afterConnectFailure: connectResult.exitCode,
                                         reconnect: options.reconnect, connectedOnce: connectedOnce) else {
                    return connectResult
                }
                if case .interrupted = pauseInterruptibly(seconds: 1) {
                    result.exitCode = BlewExitCode.interrupted.code
                    return result
                }
                continue
            }

            let known = Set(manager.knownCharacteristicUUIDs().map { $0.uppercased() })
            guard known.contains(NUS.rx), known.contains(NUS.tx) else {
                result.errors.append("device has no Nordic UART Service (RX \(NUS.rx), TX \(NUS.tx))")
                result.exitCode = BlewExitCode.notFound.code
                return result
            }
            let device = connectedDevice()
            if let id = device.id { targeting = DeviceTarget(id: id) }
            connectedOnce = true
            status("connected", device.label)

            var outcome = runNUSSession(options: options, port: port, deliver: deliver, status: status)
            var stillConnected = outcome != nil && connectedDevice().id != nil
            // A write error can arrive before the disconnect that caused it:
            // let the connection state settle before deciding to reconnect.
            if options.reconnect, stillConnected, case .linkLost(_, _, false) = outcome {
                let up = Locked(true)
                let manager = self.manager
                let settled = waitInterruptible {
                    up.set(await NUSOptions.linkStaysUp(for: NUSOptions.linkSettleTime) {
                        await manager.status().isConnected
                    })
                }
                if case .interrupted = settled { outcome = nil }
                stillConnected = outcome != nil && up.value
            }
            switch NUSOptions.step(after: outcome, stillConnected: stillConnected,
                                   linger: options.linger, reconnect: options.reconnect,
                                   unsent: port.unsentCount) {
            case .reconnect:
                if case .linkLost(let reason, _, _) = outcome { status("disconnected", reason) }
                status("reconnecting", "")
            case .finish(let exitCode, let error):
                if case .linkLost(let reason, _, let linkDown) = outcome, linkDown || !stillConnected {
                    status("disconnected", reason)
                }
                result.exitCode = exitCode
                if let error { result.errors.append(error) }
                return result
            }
        }
    }

    /// Run one session on the current connection. Nil when interrupted.
    /// Notifications the session did not read fast enough to keep
    /// (`NotificationStream.capacity`) are reported as a "dropped" status:
    /// at the first loss, as it is seen, and with the total when the
    /// session ends if more were lost since.
    private func runNUSSession(options: NUSOptions, port: NUSPort,
                               deliver: @escaping @Sendable (Data) -> Void,
                               status: @escaping @Sendable (String, String) -> Void) -> NUSOutcome? {
        let outcome = Locked<NUSOutcome>(.linkLost("session did not start"))
        let manager = self.manager
        // The operation timeout bounds the subscribe and each write.
        let operationTimeout = globals.timeout ?? 5.0
        let reported = Locked(0)
        let operation: () async -> Void = {
            do {
                let received = try await Self.withDeadline(operationTimeout) {
                    try await manager.subscribe(characteristicUUID: NUS.tx)
                }
                // Pieces fit one ATT packet whatever the write type, so the
                // device never needs a long (prepared) write.
                let maxLength = try manager.maximumWriteLength(withResponse: false)
                guard maxLength > 0 else {
                    throw BLEError.writeFailed("the connection reports a maximum write length of \(maxLength)")
                }
                let session = NUSSession(
                    send: { piece in
                        try await manager.writeCharacteristic(NUS.rx, data: piece, type: options.writeType)
                    },
                    maxLength: maxLength,
                    writeTimeout: operationTimeout,
                    received: received,
                    input: port.input(),
                    deliver: { data in
                        if reported.value == 0 {
                            let lost = received.droppedCount
                            if lost > 0 {
                                reported.set(lost)
                                status("dropped", "\(lost) notifications from the device: they came faster than blew delivered them")
                            }
                        }
                        deliver(data)
                    },
                    expect: options.expect,
                    linger: options.linger)
                outcome.set(await session.run())
                let lost = received.droppedCount
                if lost > reported.value {
                    status("dropped", "\(lost) notifications from the device in this session")
                }
            } catch {
                outcome.set(.linkLost(nil, error))
            }
        }
        if case .interrupted = waitInterruptible(operation) { return nil }
        return outcome.value
    }

    private func pauseInterruptibly(seconds: TimeInterval) -> CommandOutcome {
        waitInterruptible {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    /// The connected device's label for status lines and its identifier;
    /// the identifier is nil when no device is connected.
    private func connectedDevice() -> (label: String, id: String?) {
        let semaphore = DispatchSemaphore(value: 0)
        let device = Locked<(label: String, id: String?)>(("", nil))
        let manager = self.manager
        Task {
            let s = await manager.status()
            let label = [s.deviceName, s.deviceId.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            device.set((label, s.isConnected ? s.deviceId : nil))
            semaphore.signal()
        }
        semaphore.wait()
        return device.value
    }
}
