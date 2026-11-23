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

    /// Device-targeting arguments for `ensureConnected`; the NUS service
    /// filter when the user named no device.
    var targeting: [String]
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

    static let targetingOptions: Set<String> = ["-i", "--id", "-n", "--name", "-S", "--service",
                                                "-m", "--manufacturer", "-R", "--rssi-min"]

    /// Check the raw values of a `nus` command and build its options.
    /// `stdinAvailable` is false in the REPL, `exec` and MCP, where standard
    /// input is not the user's to bridge. Throws a message for the user.
    static func make(
        targeting: [String], sends: [String] = [], file: String? = nil, expect: String? = nil,
        duration: Double? = nil, pty: Bool = false, listen: UInt16? = nil, bind: String? = nil,
        reconnect: Bool = false, withResponse: Bool = false, withoutResponse: Bool = false,
        stdinAvailable: Bool
    ) throws -> NUSOptions {
        func fail(_ message: String) -> NUSPortError { NUSPortError(message) }
        func escaped(_ text: String, _ option: String) throws -> Data {
            guard let data = NUS.unescape(text) else {
                throw fail("invalid escape in \(option) '\(text)' (use \\n \\r \\t \\0 \\\\ \\xHH)")
            }
            return data
        }

        let sources = [!sends.isEmpty, file != nil, pty, listen != nil].filter { $0 }.count
        guard sources <= 1 else { throw fail("use only one of --send, --file, --pty and --listen") }
        guard bind == nil || listen != nil else { throw fail("--bind needs --listen") }
        guard !(withResponse && withoutResponse) else {
            throw fail("use only one of --with-response and --without-response")
        }
        if let duration, !CommandRouter.isValidDuration(duration) {
            throw fail("invalid duration '\(duration)' (use 0 to \(Int(CommandRouter.maxDuration)) seconds)")
        }

        let endpoint: Endpoint
        if !sends.isEmpty {
            endpoint = .fixed(try sends.map { try escaped($0, "--send") }.reduce(Data(), +))
        } else if let file {
            guard let data = FileManager.default.contents(atPath: file) else {
                throw fail("cannot read file '\(file)'")
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
            throw fail("--expect works only with standard input/output, --send or --file")
        default: break
        }

        let named = CommandRouter.scanOptions(targeting, optionsWithValue: CommandRouter.nusOptionsWithValue)
            .contains { targetingOptions.contains($0.name) }
        return NUSOptions(
            targeting: named ? targeting : targeting + ["-S", NUS.service],
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
        exitCode != 130 && reconnect && connectedOnce
    }

    /// After a session: nil means interrupted. A lost link reconnects under
    /// `--reconnect` only when the device really disconnected; a failure
    /// while still connected (a subscribe or write error) ends the command,
    /// since reconnecting would not change it.
    static func step(after outcome: NUSOutcome?, stillConnected: Bool, linger: TimeInterval, reconnect: Bool) -> Step {
        switch outcome {
        case nil:
            return .finish(exitCode: 130, error: nil)
        case .matched, .inputEnded:
            return .finish(exitCode: 0, error: nil)
        case .expectMissed:
            return .finish(exitCode: BlewExitCode.timeout.code, error: "expected text not received within \(linger)s")
        case .linkLost(let reason):
            return reconnect && !stillConnected
                ? .reconnect
                : .finish(exitCode: BlewExitCode.operationFailed.code, error: reason)
        }
    }
}

extension CommandRouter {
    static let nusOptionsWithValue: Set<String> = targetingOptionsWithValue.union([
        "-s", "--send", "--file", "-e", "--expect", "-d", "--duration", "-l", "--listen", "--bind",
    ])

    /// Parse `nus` arguments from the REPL or a script. Throws a message for
    /// the user on invalid input.
    func parseNUSOptions(_ args: [String], stdinAvailable: Bool) throws -> NUSOptions {
        let valueOptions = Self.nusOptionsWithValue
        func value(_ short: String, _ long: String) -> String? {
            parseStringOption(args, short: short, long: long, optionsWithValue: valueOptions)
        }
        func flag(_ short: String, _ long: String) -> Bool {
            hasFlag(args, short: short, long: long, optionsWithValue: valueOptions)
        }

        if let stray = positionalArgs(args, optionsWithValue: valueOptions).first {
            throw NUSPortError("unexpected argument '\(stray)'")
        }
        let listen = try value("-l", "--listen").map { text in
            guard let port = UInt16(text) else { throw NUSPortError("invalid port '\(text)'") }
            return port
        }
        let duration = try value("-d", "--duration").map { text in
            guard let seconds = Double(text) else { throw NUSPortError("invalid duration '\(text)'") }
            return seconds
        }
        return try NUSOptions.make(
            targeting: args,
            sends: parseAllStringOptions(args, short: "-s", long: "--send", optionsWithValue: valueOptions),
            file: value("--file", "--file"),
            expect: value("-e", "--expect"),
            duration: duration,
            pty: flag("--pty", "--pty"),
            listen: listen,
            bind: value("--bind", "--bind"),
            reconnect: flag("--reconnect", "--reconnect"),
            withResponse: flag("-r", "--with-response"),
            withoutResponse: flag("-w", "--without-response"),
            stdinAvailable: stdinAvailable)
    }

    /// `nus` from the REPL or a script: parse, then bridge.
    func runNUS(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        let args = expandArgs(args, optionsWithValue: Self.nusOptionsWithValue)
        do {
            return runNUS(try parseNUSOptions(args, stdinAvailable: !isInteractiveMode), emit: emit)
        } catch {
            return Self.nusInvalid(error)
        }
    }

    /// The result for options `NUSOptions.make` refused.
    static func nusInvalid(_ error: Error) -> CommandResult {
        var result = CommandResult()
        result.errors.append("\(error)")
        result.exitCode = BlewExitCode.invalidArguments.code
        return result
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
            result.errors.append("\(error)")
            result.exitCode = BlewExitCode.operationFailed.code
            return result
        }
        defer { port.close() }
        switch options.endpoint {
        case .pty, .tcp: status("bridge", port.label)
        case .stdio, .fixed: break
        }

        // After the first connection, reconnect only to that device, never
        // to whichever device matching the filter is strongest by then.
        var targeting = options.targeting
        var connectedOnce = false
        while true {
            let connectResult = ensureConnected(args: targeting, optionsWithValue: Self.nusOptionsWithValue)
            if connectResult.exitCode != 0 {
                guard NUSOptions.retries(afterConnectFailure: connectResult.exitCode,
                                         reconnect: options.reconnect, connectedOnce: connectedOnce) else {
                    return connectResult
                }
                if case .interrupted = pauseInterruptibly(seconds: 1) {
                    result.exitCode = 130
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
            if let id = device.id { targeting = ["-i", id] }
            connectedOnce = true
            status("connected", device.label)

            let outcome = runNUSSession(options: options, port: port)
            let stillConnected = outcome != nil && connectedDevice().id != nil
            switch NUSOptions.step(after: outcome, stillConnected: stillConnected,
                                   linger: options.linger, reconnect: options.reconnect) {
            case .reconnect:
                if case .linkLost(let reason) = outcome { status("disconnected", reason) }
                status("reconnecting", "")
            case .finish(let exitCode, let error):
                if case .linkLost(let reason) = outcome, !stillConnected { status("disconnected", reason) }
                result.exitCode = exitCode
                if let error { result.errors.append(error) }
                return result
            }
        }
    }

    /// Run one session on the current connection. Nil when interrupted.
    private func runNUSSession(options: NUSOptions, port: NUSPort) -> NUSOutcome? {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = Locked<NUSOutcome>(.linkLost("session did not start"))
        let manager = self.manager
        let task = Task {
            defer { semaphore.signal() }
            do {
                let received = try await manager.subscribe(characteristicUUID: NUS.tx)
                // Chunks fit one ATT packet whatever the write type, so the
                // device never needs a long (prepared) write.
                let maxLength = try manager.maximumWriteLength(withResponse: false)
                let session = NUSSession(
                    send: { data in
                        for chunk in NUS.chunks(data, maxLength: maxLength) {
                            try await manager.writeCharacteristic(NUS.rx, data: chunk, type: options.writeType)
                        }
                    },
                    received: received,
                    input: port.input(),
                    deliver: port.write,
                    expect: options.expect,
                    linger: options.linger)
                outcome.set(await session.run())
            } catch {
                outcome.set(.linkLost("\(error.localizedDescription)"))
            }
        }
        if case .interrupted = waitInterruptible(task, semaphore: semaphore) { return nil }
        return outcome.value
    }

    private func pauseInterruptibly(seconds: TimeInterval) -> CommandOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            semaphore.signal()
        }
        return waitInterruptible(task, semaphore: semaphore)
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
