import Foundation
import BLEManager

/// Nordic UART Service: a byte pipe over GATT. The central writes to RX and
/// the peripheral notifies on TX. Everything here is CoreBluetooth-free so
/// the bridge logic is unit-tested with fake links and ports.
enum NUS {
    static let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// The central writes to RX (write or write without response).
    static let rx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// The peripheral notifies on TX.
    static let tx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    /// Decode the printf-style escapes of `--send` and `--expect` text:
    /// `\n`, `\r`, `\t`, `\0`, `\\` and `\xHH`. Any other byte passes through
    /// as UTF-8. Returns nil for an unknown or truncated escape.
    static func unescape(_ text: String) -> Data? {
        var out = Data()
        var cursor = text.unicodeScalars.makeIterator()
        while let scalar = cursor.next() {
            guard scalar == "\\" else {
                out.append(contentsOf: Array(String(scalar).utf8))
                continue
            }
            switch cursor.next() {
            case "n": out.append(0x0A)
            case "r": out.append(0x0D)
            case "t": out.append(0x09)
            case "0": out.append(0x00)
            case "\\": out.append(0x5C)
            case "x":
                guard let hi = cursor.next(), let lo = cursor.next(),
                      let byte = UInt8(String([Character(hi), Character(lo)]), radix: 16)
                else { return nil }
                out.append(byte)
            default:
                return nil
            }
        }
        return out
    }
}

/// Watches the received byte stream for an expected byte sequence, which may
/// arrive split across any number of notifications.
struct NUSExpect {
    let pattern: Data
    /// The last `pattern.count - 1` bytes seen, so a match spanning two
    /// chunks is found without keeping the whole stream.
    private var tail = Data()

    init(_ pattern: Data) {
        self.pattern = pattern
    }

    /// Feed the next received chunk; true once the pattern has appeared.
    mutating func feed(_ chunk: Data) -> Bool {
        guard !pattern.isEmpty else { return true }
        let window = tail + chunk
        if window.range(of: pattern) != nil { return true }
        tail = Data(window.suffix(pattern.count - 1))
        return false
    }
}

/// Why a bridge session ended.
enum NUSOutcome: Equatable {
    /// The local input ended and the linger time passed (no `--expect`).
    case inputEnded
    /// The `--expect` bytes arrived.
    case matched
    /// The local input ended and the `--expect` bytes did not arrive in time.
    case expectMissed
    /// The device disconnected, or a write to it failed: why, the exit code
    /// that ends the command when it does not reconnect, and whether the
    /// error itself shows the connection is gone (a disconnect, no
    /// connection, Bluetooth unavailable). When it does not, whether to
    /// reconnect is decided from the connection state.
    case linkLost(String, exitCode: Int32 = BlewExitCode.operationFailed.code, linkDown: Bool = false)
}

/// One connection's worth of bridging: local input goes to the device's RX
/// characteristic, TX notifications go to `deliver`. The session ends at the
/// first of: expected bytes received, input ended plus `linger` seconds,
/// or the link lost. Cancelling the task that runs it ends it too.
///
/// The session sends from the port's input buffer one piece (at most
/// `maxLength` bytes) at a time and consumes a piece only after its write
/// completed, so what a lost link left unsent stays in the buffer for the
/// next session. The piece whose write was under way when the link was lost
/// is sent again by the next session; a device may receive it twice.
struct NUSSession: Sendable {
    /// Writes one piece of local input to RX (flow control is the link's job).
    let send: @Sendable (Data) async throws -> Void
    /// The largest piece `send` is given.
    let maxLength: Int
    /// Seconds one `send` may take before the session ends with a timeout.
    let writeTimeout: TimeInterval
    /// TX notifications; the stream throws why when the connection ends.
    let received: NotificationStream
    /// Local input, shared with the sessions before and after this one.
    let input: NUSInputBuffer
    /// Where received bytes go: the local port or the command's output.
    let deliver: @Sendable (Data) -> Void
    let expect: Data?
    /// Seconds to keep listening after the input ends; with `expect`, the
    /// deadline for the expected bytes.
    let linger: TimeInterval

    func run() async -> NUSOutcome {
        await withTaskGroup(of: NUSOutcome.self) { group in
            group.addTask { [received, deliver, expect] in
                var matcher = expect.map(NUSExpect.init)
                do {
                    for try await chunk in received {
                        deliver(chunk)
                        if matcher?.feed(chunk) == true { return .matched }
                    }
                } catch {
                    return .linkLost(nil, error)
                }
                return .linkLost("device disconnected")
            }
            group.addTask { [input, send, maxLength, writeTimeout, expect, linger] in
                do {
                    while let piece = try await input.next(maxLength: maxLength) {
                        do {
                            try await CommandRouter.withDeadline(writeTimeout) { try await send(piece.data) }
                        } catch {
                            return .linkLost("write failed", error)
                        }
                        input.consume(piece)
                    }
                    try await Task.sleep(nanoseconds: UInt64(max(linger, 0) * 1_000_000_000))
                } catch {
                    // Only cancellation ends the waits above: the session is
                    // over and another outcome decides it.
                    return .linkLost("session stopped")
                }
                return expect == nil ? .inputEnded : .expectMissed
            }
            let first = await group.next() ?? .linkLost("session stopped")
            group.cancelAll()
            return first
        }
    }
}
