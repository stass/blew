import Foundation
import LineNoise

/// The signals blew handles. Every other signal keeps its default action.
enum HandledSignal: CaseIterable {
    /// SIGINT: Ctrl-C at a terminal whose line discipline is cooked (a
    /// running command), or `kill -INT`.
    case interrupt
    /// SIGTERM: `kill`, or a supervisor stopping blew.
    case terminate

    var number: Int32 {
        switch self {
        case .interrupt: return SIGINT
        case .terminate: return SIGTERM
        }
    }
}

/// Whether a command is running that a SIGINT can stop. A command runs
/// inside a span: a whole one-shot CLI command or `exec` script (opened by
/// `Blew.main`), a REPL command from the line read to the next read, an
/// MCP tool call, and each `CommandRouter.waitInterruptible` within them.
enum CommandPhase: Equatable {
    /// No span is open: at the interactive REPL prompt, while a piped REPL
    /// script waits for its next line, between MCP tool calls, or parsing a
    /// CLI command's arguments.
    case idle
    /// A span is open and its command stops when asked.
    case running
    /// A command was asked to stop and has not returned yet.
    case interrupting
}

/// What the process does when a handled signal arrives.
enum SignalResponse: Equatable {
    /// Ask the running command to stop. It cancels its work and returns
    /// with exit code 130, and the caller renders what it gathered.
    case interruptCommand
    /// Leave now through `ProcessSignals.exitProcess`, with this code.
    case exit(Int32)
}

/// The signal policy, a pure function of the signal and the phase.
///
/// - SIGTERM always exits 143 (128 + 15).
/// - SIGINT stops a running command, which then exits 130 the ordinary way
///   (CLI) or returns to the prompt (REPL).
/// - SIGINT with no running command, or a second one while the command is
///   still stopping, exits 130.
enum SignalPolicy {
    static func respond(to signal: HandledSignal, in phase: CommandPhase)
        -> (response: SignalResponse, next: CommandPhase)
    {
        switch (signal, phase) {
        case (.terminate, _):
            return (.exit(BlewExitCode.terminated.code), phase)
        case (.interrupt, .running):
            return (.interruptCommand, .interrupting)
        case (.interrupt, .idle), (.interrupt, .interrupting):
            return (.exit(BlewExitCode.interrupted.code), phase)
        }
    }
}

/// Receives SIGINT and SIGTERM for the whole process and acts on them.
///
/// The signals are ignored at the C level and delivered through
/// `DispatchSource` signal sources on a private serial queue, so the
/// handling runs as ordinary code on that queue, never inside a C signal
/// handler. The main thread may be blocked meanwhile (in a semaphore wait or
/// in `read` at the prompt); the queue does not need it.
final class ProcessSignals: @unchecked Sendable {
    static let shared = ProcessSignals()

    private let queue = DispatchQueue(label: "blew.signals")
    private let lock = NSLock()
    /// Open command spans; more than one when spans nest (a REPL command
    /// and its waits). MCP tool calls run one at a time (`ToolCallQueue`).
    private var openSpans = 0
    /// A SIGINT asked the open spans to stop; cleared when the last closes.
    private var interrupted = false
    private var phase: CommandPhase {
        openSpans == 0 ? .idle : (interrupted ? .interrupting : .running)
    }
    private var exitHook: (() -> Void)?
    private var sources: [DispatchSourceSignal] = []
    /// Who is ending the process. The first to claim the exit owns it: the
    /// main thread returning from its command (`beginOrdinaryExit`) or the
    /// signal queue (`exitProcess`).
    private var exitOwner = ExitOwner.none

    private enum ExitOwner { case none, ordinary, signal }

    /// Internal so tests can use an instance of their own; blew uses `shared`.
    init() {}

    /// Take over SIGINT and SIGTERM. Called once, at startup, before any
    /// command runs.
    func install() {
        lock.withLock {
            guard sources.isEmpty else { return }
            for handled in HandledSignal.allCases {
                let source = DispatchSource.makeSignalSource(signal: handled.number, queue: queue)
                source.setEventHandler { [unowned self] in
                    // Signals that arrive together are coalesced into one event.
                    for _ in 0..<max(1, source.data) { handle(handled) }
                }
                source.resume()
                sources.append(source)
                // Only now, so a signal before the source exists still
                // has its default action rather than being lost.
                signal(handled.number, SIG_IGN)
            }
        }
    }

    // MARK: - Interruptible waits

    /// A command span opens. A SIGINT while any span is open stops the
    /// command instead of ending the process. Once a signal has begun the
    /// exit, no command starts: the caller waits for the exit instead.
    func commandStarted() {
        let exitBegun: Bool = lock.withLock {
            if exitOwner == .signal { return true }
            if openSpans == 0 { interrupted = false }
            openSpans += 1
            return false
        }
        if exitBegun { waitForSignalExit() }
    }

    /// The span that `commandStarted` opened has closed. Returns whether a
    /// stop is requested as it closes; for the outermost span, whether a
    /// SIGINT asked the command to stop while it was open. The answer is
    /// read under the same lock as the close, so a SIGINT that arrives after
    /// it finds the span closed and is not lost between the two.
    @discardableResult
    func commandFinished() -> Bool {
        lock.withLock {
            let wasInterrupted = interrupted
            openSpans -= 1
            if openSpans == 0 { interrupted = false }
            return wasInterrupted
        }
    }

    /// Whether a SIGINT has asked the running command to stop. It stays
    /// set until the outermost span closes, so a REPL command interrupted
    /// between two waits stops at the next one.
    var interruptRequested: Bool {
        lock.withLock { interrupted }
    }

    // MARK: - Exit

    /// The main thread is about to end the process the ordinary way.
    /// Returns true to the first caller, which then runs the exit cleanup,
    /// and false to later ones. When a signal has already begun the exit,
    /// it never returns, so the signal's cleanup finishes and its exit code
    /// is the one the process ends with.
    func beginOrdinaryExit() -> Bool {
        let before: ExitOwner = lock.withLock {
            let before = exitOwner
            if before == .none { exitOwner = .ordinary }
            return before
        }
        switch before {
        case .none: return true
        case .ordinary: return false
        case .signal: waitForSignalExit()
        }
    }

    /// The signal queue begins the exit. From here on no command starts
    /// and the main thread does not exit on its own. Returns whether the
    /// signal queue runs the exit cleanup: not when the main thread already
    /// began its ordinary exit, which runs it. Internal for tests;
    /// `exitProcess` is the caller.
    func beginSignalExit() -> Bool {
        lock.withLock {
            let ownsCleanup = exitOwner == .none
            exitOwner = .signal
            return ownsCleanup
        }
    }

    /// Block the calling thread until the signal queue's `_exit` ends the
    /// process.
    private func waitForSignalExit() -> Never {
        while true { sleep(60) }
    }

    /// Work that must happen before the process exits on a signal, such as
    /// saving the REPL history; nil removes it. It runs on the signal queue
    /// while the main thread may still be running.
    func setExitHook(_ hook: (() -> Void)?) {
        lock.withLock { exitHook = hook }
    }

    /// Act on one delivered signal. Internal so tests can deliver a signal
    /// without raising it.
    func handle(_ signal: HandledSignal) {
        let response: SignalResponse = lock.withLock {
            let decision = SignalPolicy.respond(to: signal, in: phase)
            if decision.next == .interrupting { interrupted = true }
            return decision.response
        }
        if case .exit(let code) = response {
            exitProcess(code)
        }
    }

    /// Claim the exit, give the terminal back, run the exit hook, stop
    /// advertising and disconnect (unless the main thread's ordinary exit
    /// is already doing that), flush standard output and exit. Restoring the terminal
    /// keeps its lock, so from then on the REPL cannot enter raw mode again
    /// and reads no more input.
    ///
    /// The flush is skipped when another thread holds standard output (it
    /// may be blocked writing to a pipe nobody reads), and `_exit` ends the
    /// process without atexit handlers, so neither can keep a signalled
    /// blew from exiting. Output is line-buffered, so at most a partial
    /// line is lost.
    private func exitProcess(_ code: Int32) -> Never {
        let ownsCleanup = beginSignalExit()
        LineNoise.restoreTerminalForExit()
        let hook = lock.withLock { exitHook }
        hook?()
        if ownsCleanup { exitCleanup() }
        StandardOutput.flushUnlessLocked()
        _exit(code)
    }
}
