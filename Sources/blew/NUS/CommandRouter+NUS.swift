import Foundation
import BLEManager

// MARK: - nus: bridge a local port to the device's Nordic UART Service

/// The parsed options of one `nus` command.
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
}

extension CommandRouter {
    static let nusOptionsWithValue: Set<String> = [
        "-i", "--id", "-n", "--name", "-S", "--service", "-m", "--manufacturer",
        "-R", "--rssi-min", "-p", "--pick",
        "-s", "--send", "--file", "-e", "--expect", "-d", "--duration", "-l", "--listen", "--bind",
    ]

    /// Parse `nus` arguments. `stdinAvailable` is false in the REPL, `exec`
    /// and MCP, where standard input is not the user's to bridge. Throws a
    /// message for the user on invalid input.
    func parseNUSOptions(_ args: [String], stdinAvailable: Bool) throws -> NUSOptions {
        func fail(_ message: String) -> NUSPortError { NUSPortError(message) }
        func escaped(_ text: String, _ option: String) throws -> Data {
            guard let data = NUS.unescape(text) else {
                throw fail("invalid escape in \(option) '\(text)' (use \\n \\r \\t \\0 \\\\ \\xHH)")
            }
            return data
        }

        if let stray = positionalArgs(args, optionsWithValue: Self.nusOptionsWithValue).first {
            throw fail("unexpected argument '\(stray)'")
        }
        let sends = try parseAllStringOptions(args, short: "-s", long: "--send").map { try escaped($0, "--send") }
        let file = parseStringOption(args, short: "--file", long: "--file")
        let usePty = args.contains("--pty")
        let listen = parseStringOption(args, short: "-l", long: "--listen")
        let bind = parseStringOption(args, short: "--bind", long: "--bind")

        let sources = [!sends.isEmpty, file != nil, usePty, listen != nil].filter { $0 }.count
        guard sources <= 1 else { throw fail("use only one of --send, --file, --pty and --listen") }
        guard bind == nil || listen != nil else { throw fail("--bind needs --listen") }

        let endpoint: NUSOptions.Endpoint
        if !sends.isEmpty {
            endpoint = .fixed(sends.reduce(Data(), +))
        } else if let file {
            guard let data = FileManager.default.contents(atPath: file) else {
                throw fail("cannot read file '\(file)'")
            }
            endpoint = .fixed(data)
        } else if usePty {
            endpoint = .pty
        } else if let listen {
            guard let port = UInt16(listen) else { throw fail("invalid port '\(listen)'") }
            endpoint = .tcp(host: bind ?? NUSOptions.defaultBind, port: port)
        } else {
            endpoint = stdinAvailable ? .stdio : .fixed(Data())
        }

        let expect = try parseStringOption(args, short: "-e", long: "--expect").map { try escaped($0, "--expect") }
        switch (expect, endpoint) {
        case (.some, .pty), (.some, .tcp):
            throw fail("--expect works only with standard input/output, --send or --file")
        default: break
        }

        let durationText = parseStringOption(args, short: "-d", long: "--duration")
        let duration = durationText.flatMap(Double.init)
        guard durationText == nil || (duration ?? -1) >= 0 else {
            throw fail("invalid duration '\(durationText ?? "")'")
        }

        let withResponse = args.contains("-r") || args.contains("--with-response")
        let withoutResponse = args.contains("-w") || args.contains("--without-response")
        guard !(withResponse && withoutResponse) else {
            throw fail("use only one of --with-response and --without-response")
        }

        return NUSOptions(
            endpoint: endpoint,
            expect: expect,
            linger: duration ?? (expect == nil ? NUSOptions.defaultLinger : NUSOptions.defaultExpectTimeout),
            writeType: withResponse ? .withResponse : (withoutResponse ? .withoutResponse : .auto),
            reconnect: args.contains("--reconnect"))
    }

    /// Targeting arguments for `nus`: the user's, or the NUS service filter
    /// when the user named no device at all.
    func nusTargetingArgs(_ args: [String]) -> [String] {
        let targeting: Set<String> = ["-i", "--id", "-n", "--name", "-S", "--service",
                                      "-m", "--manufacturer", "-R", "--rssi-min"]
        let named = args.contains { arg in
            targeting.contains(arg) || targeting.contains { arg.hasPrefix("\($0)=") }
        }
        return named ? args : args + ["-S", NUS.service]
    }

    /// Bridge a local port to the connected device's Nordic UART Service.
    /// Streaming: bytes from the device and bridge events go to `emit`.
    func runNUS(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        let args = expandArgs(args, optionsWithValue: Self.nusOptionsWithValue)
        var result = CommandResult()

        let options: NUSOptions
        do {
            options = try parseNUSOptions(args, stdinAvailable: !isInteractiveMode)
        } catch {
            result.errors.append("\(error)")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

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

        let targetArgs = nusTargetingArgs(args)
        var connectedOnce = false
        while true {
            let connectResult = ensureConnected(args: targetArgs)
            if connectResult.exitCode != 0 {
                guard options.reconnect && connectedOnce else { return connectResult }
                if case .interrupted = pauseInterruptibly(seconds: 1) {
                    result.exitCode = 130
                    return result
                }
                continue
            }
            connectedOnce = true

            let known = Set(manager.knownCharacteristicUUIDs().map { $0.uppercased() })
            guard known.contains(NUS.rx), known.contains(NUS.tx) else {
                result.errors.append("device has no Nordic UART Service (RX \(NUS.rx), TX \(NUS.tx))")
                result.exitCode = BlewExitCode.notFound.code
                return result
            }
            status("connected", connectedDeviceLabel())

            switch runNUSSession(options: options, port: port) {
            case .none:
                result.exitCode = 130
                return result
            case .matched, .inputEnded:
                return result
            case .expectMissed:
                result.errors.append("expected text not received within \(options.linger)s")
                result.exitCode = BlewExitCode.timeout.code
                return result
            case .linkLost(let reason):
                status("disconnected", reason)
                guard options.reconnect else {
                    result.errors.append(reason)
                    result.exitCode = BlewExitCode.operationFailed.code
                    return result
                }
                status("reconnecting", "")
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

    private func connectedDeviceLabel() -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let label = Locked("")
        let manager = self.manager
        Task {
            let s = await manager.status()
            label.set([s.deviceName, s.deviceId.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
            semaphore.signal()
        }
        semaphore.wait()
        return label.value
    }
}
