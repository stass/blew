import Foundation

/// The local end of a NUS bridge: where bytes for the device come from and
/// where bytes from the device go. Bytes pass unchanged in both directions.
///
/// A port reads on one background thread for its whole life and hands what
/// it reads to the input stream of the current session. Each session (one
/// BLE connection) takes a fresh stream with `input()`, so a port outlives
/// reconnects. Bytes read while no session is listening are dropped, as on
/// a serial line whose far end is down.
final class NUSPort: @unchecked Sendable {
    /// What the user connects to: `stdio`, a pty path or `host:port`.
    let label: String
    /// Bytes from the device.
    let write: @Sendable (Data) -> Void

    /// Blocks until input is available; nil once the input has ended for good.
    private let readChunk: @Sendable () -> Data?
    private let closeAll: @Sendable () -> Void

    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var generation = 0
    private var started = false
    private var ended = false

    init(label: String,
         read: @escaping @Sendable () -> Data?,
         write: @escaping @Sendable (Data) -> Void,
         close: @escaping @Sendable () -> Void = {}) {
        self.label = label
        self.readChunk = read
        self.write = write
        self.closeAll = close
    }

    /// The input stream for the next session. It finishes when the input
    /// ends for good; a stream taken after that is already finished.
    func input() -> AsyncStream<Data> {
        let (stream, cont) = AsyncStream<Data>.makeStream()
        let gen: Int = lock.withLock {
            continuation?.finish()
            generation += 1
            if ended {
                cont.finish()
                continuation = nil
            } else {
                continuation = cont
            }
            if !started {
                started = true
                let thread = Thread { [self] in readLoop() }
                thread.name = "blew.nus-port"
                thread.start()
            }
            return generation
        }
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            lock.withLock {
                if self.generation == gen { self.continuation = nil }
            }
        }
        return stream
    }

    /// Release the port's descriptors; the reader thread then stops.
    func close() {
        closeAll()
    }

    private func readLoop() {
        while let data = readChunk() {
            lock.withLock { _ = continuation?.yield(data) }
        }
        lock.withLock {
            ended = true
            continuation?.finish()
            continuation = nil
        }
    }
}

// MARK: - Fixed input and standard input/output

extension NUSPort {
    /// A port whose input is `data`, sent once, after which the input ends.
    /// Used by `--send` and `--file`.
    static func fixed(_ data: Data, write: @escaping @Sendable (Data) -> Void) -> NUSPort {
        let pending = Locked<Data?>(data.isEmpty ? nil : data)
        return NUSPort(label: "stdio", read: { pending.take() }, write: write)
    }

    /// A port reading standard input until EOF.
    static func standardInput(write: @escaping @Sendable (Data) -> Void) -> NUSPort {
        NUSPort(label: "stdio", read: { readDescriptor(STDIN_FILENO) }, write: write)
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
        return NUSPort(
            label: path,
            read: { pollRead(masterFD, until: closed) },
            write: { data in writeNonBlocking(masterFD, data) },
            close: {
                guard !closed.swap(true) else { return }
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
                if !closed.value { onEvent("client disconnected") }
            }
            return nil
        }
        return NUSPort(
            label: "\(host):\(boundPort(listener))",
            read: read,
            // The client lock keeps a write from reaching a descriptor the
            // reader just closed and the system reused.
            write: { data in client.withValue { fd in if fd >= 0 { writeNonBlocking(fd, data) } } },
            close: {
                guard !closed.swap(true) else { return }
                Darwin.close(listener)
                client.withValue { fd in if fd >= 0 { Darwin.close(fd); fd = -1 } }
            })
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

struct NUSPortError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
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

/// Write all of `data` to a non-blocking descriptor, giving up on the rest
/// when the reader is not keeping up (EAGAIN) or has gone.
private func writeNonBlocking(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard var ptr = raw.baseAddress else { return }
        var left = raw.count
        while left > 0 {
            let n = Darwin.write(fd, ptr, left)
            if n > 0 {
                ptr += n
                left -= n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }
}

/// A value guarded by a lock, shared between a port's reader thread and the
/// threads that write to or close it.
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

extension Locked {
    /// Return the value and leave nil behind.
    func take<T>() -> T? where Value == T? { swap(nil) }
}
