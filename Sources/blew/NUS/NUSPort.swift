import Foundation

/// The local end of a NUS bridge: where bytes for the device come from and
/// where bytes from the device go. Bytes pass unchanged in both directions.
///
/// Input belongs to the port, not to a session. A port reads on one
/// background thread for its whole life into its `NUSInputBuffer`, and each
/// session (one BLE connection) sends from that buffer, removing bytes only
/// once they are written. Input one session did not send is therefore sent
/// by the next one after a reconnect. The reader stops reading while the
/// buffer holds `inputCapacity` bytes, which pushes back on the source: a
/// pipe or file waits, and a TCP or pty client's writes wait in its kernel
/// buffer.
///
/// Bytes from the device cannot be pushed back on (notifications have no
/// flow control), so `deliver` drops what the local end does not take and
/// counts it in `droppedCount`.
final class NUSPort: @unchecked Sendable {
    /// Bytes the input buffer holds before the reader stops reading.
    static let inputCapacity = 64 * 1024

    /// What the user connects to: `stdio`, a pty path or `host:port`.
    let label: String

    /// Blocks until input is available; nil once the input has ended for good.
    private let readChunk: @Sendable () -> Data?
    /// Hands bytes from the device to the local end; returns how many it took.
    private let writeChunk: @Sendable (Data) -> Int
    private let closeAll: @Sendable () -> Void
    /// Input bytes the source holds that the reader has not read yet, when
    /// the source knows (fixed input); 0 otherwise.
    private let sourceRemaining: @Sendable () -> Int
    private let buffer: NUSInputBuffer
    private let started = Locked(false)
    private let drops = Locked(NUSDropTally())

    init(label: String,
         capacity: Int = NUSPort.inputCapacity,
         read: @escaping @Sendable () -> Data?,
         write: @escaping @Sendable (Data) -> Int,
         close: @escaping @Sendable () -> Void = {},
         remaining: @escaping @Sendable () -> Int = { 0 }) {
        self.label = label
        self.readChunk = read
        self.writeChunk = write
        self.closeAll = close
        self.sourceRemaining = remaining
        self.buffer = NUSInputBuffer(capacity: capacity)
    }

    /// The port's input, shared by every session. The first call starts
    /// the reader thread, so nothing is read before the first session.
    func input() -> NUSInputBuffer {
        if !started.swap(true) {
            let thread = Thread { [self] in readLoop() }
            thread.name = "blew.nus-port"
            thread.start()
        }
        return buffer
    }

    /// Input bytes not yet written to a device: those read and waiting,
    /// plus those a fixed source still holds. A stream source (stdin, a pty
    /// or TCP client) may hold more that blew has not read, so this is a
    /// lower bound.
    var unsentCount: Int { buffer.pendingCount + sourceRemaining() }

    /// Bytes from the device the local end did not take, in total.
    var droppedCount: Int { drops.value.total }

    /// Hand bytes from the device to the local end. Returns the bytes lost
    /// when this delivery starts a run of losses (the first loss after a
    /// complete delivery), so the caller reports each run once.
    func deliver(_ data: Data) -> Int? {
        let taken = writeChunk(data)
        return drops.withValue { $0.record(offered: data.count, delivered: taken) }
    }

    /// Drop the input read and not yet written; returns the bytes dropped.
    fileprivate func discardInput() -> Int {
        buffer.discard()
    }

    /// End the input and release the port's descriptors; the reader thread
    /// stops at its next read.
    func close() {
        buffer.close()
        closeAll()
    }

    private func readLoop() {
        while buffer.waitForRoom(), let data = readChunk() {
            buffer.append(data)
        }
        buffer.end()
    }
}

/// Counts bytes from the device that the local end did not take, and finds
/// the start of each run of losses so it is reported once.
struct NUSDropTally: Equatable {
    private(set) var total = 0
    private var dropping = false

    /// Record one delivery of `offered` bytes of which the local end took
    /// `delivered`. Returns the bytes lost when this delivery starts a run
    /// of losses; nil when nothing was lost or a run is already under way.
    mutating func record(offered: Int, delivered: Int) -> Int? {
        let lost = max(offered - max(delivered, 0), 0)
        guard lost > 0 else {
            dropping = false
            return nil
        }
        total += lost
        defer { dropping = true }
        return dropping ? nil : lost
    }
}

/// The front of an `NUSInputBuffer`, handed out by `next` and given back to
/// `consume` once written. It names the buffer contents it was taken from,
/// so consuming it after a `discard` removes nothing that came later.
struct NUSInputPiece: Sendable {
    let data: Data
    fileprivate let epoch: UInt64
}

/// The bytes a port has read and no session has written yet: a bounded
/// queue between the port's reader thread (the producer) and the session
/// that sends to the device (the consumer). The consumer looks at the
/// front with `next` and removes bytes with `consume` only after writing
/// them, so bytes whose write failed stay for the next session.
final class NUSInputBuffer: @unchecked Sendable {
    let capacity: Int

    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var count = 0
    private var ended = false
    private var closed = false
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var lastWaiter: UInt64 = 0
    /// Counts `discard` calls; a piece taken before one is stale.
    private var epoch: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
    }

    /// Bytes held, not yet consumed.
    var pendingCount: Int { condition.withLock { count } }

    // MARK: Producer

    /// Block while the buffer is full. False once the buffer is closed: the
    /// reader then stops.
    func waitForRoom() -> Bool {
        condition.withLock {
            while count >= capacity && !closed { condition.wait() }
            return !closed
        }
    }

    /// Add bytes read from the source.
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let woken: [CheckedContinuation<Void, Never>] = condition.withLock {
            guard !closed else { return [] }
            chunks.append(data)
            count += data.count
            return takeWaiters()
        }
        woken.forEach { $0.resume() }
    }

    /// The source has ended: `next` returns nil once the held bytes are consumed.
    func end() {
        let woken: [CheckedContinuation<Void, Never>] = condition.withLock {
            ended = true
            return takeWaiters()
        }
        woken.forEach { $0.resume() }
    }

    /// Drop every held byte (a TCP client left: what it typed must not reach
    /// the device on behalf of the next client). Returns the bytes dropped.
    @discardableResult
    func discard() -> Int {
        condition.withLock {
            let dropped = count
            chunks.removeAll()
            count = 0
            epoch &+= 1
            condition.broadcast()
            return dropped
        }
    }

    /// End the input and stop the reader.
    func close() {
        let woken: [CheckedContinuation<Void, Never>] = condition.withLock {
            closed = true
            ended = true
            condition.broadcast()
            return takeWaiters()
        }
        woken.forEach { $0.resume() }
    }

    // MARK: Consumer

    /// The first held bytes, at most `maxLength` of them and never more than
    /// one read's worth, without removing them. Waits while the buffer is
    /// empty; nil once the input has ended and every byte was consumed.
    /// Throws CancellationError when the task is cancelled.
    func next(maxLength: Int) async throws -> NUSInputPiece? {
        precondition(maxLength > 0, "maxLength must be positive")
        enum Front { case piece(NUSInputPiece), ended, empty }
        while true {
            try Task.checkCancellation()
            let front: Front = condition.withLock {
                if let head = chunks.first {
                    return .piece(NUSInputPiece(data: Data(head.prefix(maxLength)), epoch: epoch))
                }
                return ended ? .ended : .empty
            }
            switch front {
            case .piece(let piece): return piece
            case .ended: return nil
            case .empty: await waitForChange()
            }
        }
    }

    /// Remove a written piece from the front; nothing when the buffer was
    /// discarded since the piece was taken.
    func consume(_ piece: NUSInputPiece) {
        condition.withLock {
            guard piece.epoch == epoch else { return }
            var left = min(piece.data.count, count)
            count -= left
            while left > 0, let head = chunks.first {
                if head.count <= left {
                    chunks.removeFirst()
                    left -= head.count
                } else {
                    chunks[0] = Data(head.dropFirst(left))
                    left = 0
                }
            }
            condition.broadcast()
        }
    }

    /// Wait until bytes are added, the input ends, or the task is cancelled.
    /// Returns at once when one of those already holds; the caller rechecks.
    private func waitForChange() async {
        let id: UInt64 = condition.withLock {
            lastWaiter += 1
            return lastWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = condition.withLock {
                    if Task.isCancelled || !chunks.isEmpty || ended { return true }
                    waiters[id] = cont
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let cont = condition.withLock { waiters.removeValue(forKey: id) }
            cont?.resume()
        }
    }

    /// Remove every waiting consumer; the lock must be held. The caller
    /// resumes them after releasing it.
    private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
        defer { waiters.removeAll() }
        return Array(waiters.values)
    }
}

// MARK: - Fixed input and standard input/output

extension NUSPort {
    /// A port whose input is `data`, read in pieces of at most 4 KiB, after
    /// which the input ends. Used by `--send` and `--file`. `write` (the
    /// command's output) takes every byte it is given.
    static func fixed(_ data: Data, write: @escaping @Sendable (Data) -> Void) -> NUSPort {
        let bytes = Data(data)
        let offset = Locked(0)
        return NUSPort(
            label: "stdio",
            read: {
                offset.withValue { offset in
                    guard offset < bytes.count else { return nil }
                    let end = min(offset + 4096, bytes.count)
                    defer { offset = end }
                    return bytes.subdata(in: offset..<end)
                }
            },
            write: { write($0); return $0.count },
            remaining: { bytes.count - offset.value })
    }

    /// A port reading standard input until EOF. `write` (the command's
    /// output) takes every byte it is given.
    static func standardInput(write: @escaping @Sendable (Data) -> Void) -> NUSPort {
        NUSPort(label: "stdio", read: { readDescriptor(STDIN_FILENO) }, write: { write($0); return $0.count })
    }
}

// MARK: - Pseudo-terminal

extension NUSPort {
    /// A pseudo-terminal in raw mode whose slave path (`label`) terminal
    /// programs open as they would a serial port. The port keeps its own
    /// slave descriptor open, so programs may close and reopen the path
    /// while the bridge keeps running.
    static func pty() throws -> NUSPort {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NUSPortError("openpty failed: \(String(cString: strerror(errno)))")
        }
        var attrs = termios()
        tcgetattr(slave, &attrs)
        cfmakeraw(&attrs)
        tcsetattr(slave, TCSANOW, &attrs)
        let path = String(cString: ptsname(master))
        let (masterFD, slaveFD) = (master, slave)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let closed = Locked(false)
        // The descriptor lock keeps a write from reaching a descriptor
        // close just released and the system reused.
        let writable = Locked<Int32>(masterFD)
        return NUSPort(
            label: path,
            read: { pollRead(masterFD, until: closed) },
            write: { data in writable.withValue { fd in fd >= 0 ? writeNonBlocking(fd, data) : 0 } },
            close: {
                guard !closed.swap(true) else { return }
                writable.withValue { fd in fd = -1 }
                Darwin.close(masterFD)
                Darwin.close(slaveFD)
            })
    }
}

// MARK: - TCP listener

extension NUSPort {
    /// A TCP listener on `host:port` that bridges one client at a time; a
    /// new client is accepted after the current one disconnects. `port` 0
    /// picks a free port, which `label` reports. `onEvent` reports clients
    /// connecting and disconnecting.
    static func tcp(host: String, port: UInt16,
                    onEvent: @escaping @Sendable (String) -> Void) throws -> NUSPort {
        let listener = try listenSocket(host: host, port: port)
        let closed = Locked(false)
        let client = Locked<Int32>(-1)
        // Set once the port exists: drops what a departed client typed.
        let discardInput = Locked<(@Sendable () -> Int)?>(nil)

        let read: @Sendable () -> Data? = {
            while !closed.value {
                var fd = client.value
                if fd < 0 {
                    guard waitReadable(listener, until: closed) else { return nil }
                    var addr = sockaddr_storage()
                    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
                    fd = withUnsafeMutablePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listener, $0, &len) }
                    }
                    guard fd >= 0 else { continue }
                    var one: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    client.set(fd)
                    onEvent("client connected from \(describe(addr))")
                }
                if let data = pollRead(fd, until: closed, stopAtEOF: true) {
                    return data
                }
                client.withValue { current in
                    if current == fd { Darwin.close(fd); current = -1 }
                }
                if !closed.value {
                    let dropped = discardInput.value?() ?? 0
                    onEvent(dropped > 0 ? "client disconnected; \(dropped) bytes it sent were not written to the device"
                                        : "client disconnected")
                }
            }
            return nil
        }
        let port = NUSPort(
            label: "\(host):\(boundPort(listener))",
            read: read,
            // The client lock keeps a write from reaching a descriptor the
            // reader just closed and the system reused. With no client
            // connected, nothing is taken.
            write: { data in client.withValue { fd in fd >= 0 ? writeNonBlocking(fd, data) : 0 } },
            close: {
                guard !closed.swap(true) else { return }
                Darwin.close(listener)
                client.withValue { fd in if fd >= 0 { Darwin.close(fd); fd = -1 } }
            })
        discardInput.set { [weak port] in port?.discardInput() ?? 0 }
        return port
    }

    /// True when `host` names the loopback interface.
    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    private static func listenSocket(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let ai = info else {
            throw NUSPortError("cannot resolve '\(host)': \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(info) }
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { throw NUSPortError("socket failed: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0, listen(fd, 1) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw NUSPortError("cannot listen on \(host):\(port): \(message)")
        }
        return fd
    }

    private static func boundPort(_ fd: Int32) -> UInt16 {
        var addr = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return portOf(addr)
    }

    private static func portOf(_ addr: sockaddr_storage) -> UInt16 {
        var copy = addr
        return withUnsafePointer(to: &copy) { ptr in
            switch Int32(addr.ss_family) {
            case AF_INET:
                return ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            case AF_INET6:
                return ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            default:
                return 0
            }
        }
    }

    private static func describe(_ addr: sockaddr_storage) -> String {
        var copy = addr
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(addr.ss_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        let name = rc == 0 ? String(cString: host) : "?"
        return "\(name):\(portOf(addr))"
    }
}

/// A local endpoint of the bridge failed (pty, socket, listener).
struct NUSPortError: Error, LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

// MARK: - Descriptor helpers

/// Blocking read of up to 4 KiB; nil at EOF or on error.
private func readDescriptor(_ fd: Int32) -> Data? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 { return Data(buffer[0..<n]) }
        if n < 0 && errno == EINTR { continue }
        return nil
    }
}

/// Wait until `fd` is readable, checking `closed` four times a second.
/// False once `closed` is set.
private func waitReadable(_ fd: Int32, until closed: Locked<Bool>) -> Bool {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while !closed.value {
        if poll(&pfd, 1, 250) > 0 { return true }
    }
    return false
}

/// Read from a non-blocking descriptor, waiting with poll. Returns nil when
/// `closed` is set, or at EOF or error when `stopAtEOF` is true; otherwise
/// (a pty master, which reports EIO while no program has the slave open)
/// keeps waiting.
private func pollRead(_ fd: Int32, until closed: Locked<Bool>, stopAtEOF: Bool = false) -> Data? {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while waitReadable(fd, until: closed) {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 { return Data(buffer[0..<n]) }
        if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
        if stopAtEOF { return nil }
        usleep(50_000)
    }
    return nil
}

/// Write as much of `data` as a non-blocking descriptor takes, giving up on
/// the rest when the reader is not keeping up (EAGAIN) or has gone. Returns
/// the bytes written.
private func writeNonBlocking(_ fd: Int32, _ data: Data) -> Int {
    data.withUnsafeBytes { raw in
        guard var ptr = raw.baseAddress else { return 0 }
        var left = raw.count
        while left > 0 {
            let n = Darwin.write(fd, ptr, left)
            if n > 0 {
                ptr += n
                left -= n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return raw.count - left
    }
}

/// A value guarded by a lock, shared between threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func set(_ value: Value) { lock.withLock { stored = value } }

    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&stored) } }

    /// Replace the value and return the old one.
    func swap(_ value: Value) -> Value { withValue { old in let o = old; old = value; return o } }
}
