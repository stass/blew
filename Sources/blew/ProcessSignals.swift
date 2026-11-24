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
/// `Blew.main`), each command of a script or REPL session
/// (`CommandRouter.runScriptCommand`, so a REPL command is a span from the
/// line read to the next read), an MCP tool call, and each
/// `CommandRouter.waitInterruptible` within them.
enum CommandPhase: Equatable {
    /// No span is open: at the interactive REPL prompt, while a piped REPL
    /// script waits for its next line, between MCP tool calls, or parsing a
    /// CLI command's arguments.
    case idle
    /// A span is open and its command stops when asked.
    case running
    /// A command was asked to stop and has not returned yet.
    case interrupting
    /// The exit has begun (a signal's, or the main thread's ordinary exit),
    /// whether or not a span is still open.
    case exiting
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
/// - SIGINT with no running command, a second one while the command is
///   still stopping, or one once the exit has begun, exits 130.
///
/// Once the exit has begun, its owner's code is the one the process exits
/// with (`ProcessSignals.respond(to:)`), whatever the signal.
enum SignalPolicy {
    static func respond(to signal: HandledSignal, in phase: CommandPhase)
        -> (response: SignalResponse, next: CommandPhase)
    {
        switch (signal, phase) {
        case (.terminate, _):
            return (.exit(BlewExitCode.terminated.code), phase)
        case (.interrupt, .running):
            return (.interruptCommand, .interrupting)
        case (.interrupt, .idle), (.interrupt, .interrupting), (.interrupt, .exiting):
            return (.exit(BlewExitCode.interrupted.code), phase)
        }
    }

    /// The exit code of a command (a one-shot CLI command, or one command
    /// of a script) that returned `code`, given whether a stop was requested
    /// while it ran. A failure keeps its own code. A success becomes 130
    /// when a stop was requested: its last operation finished as the stop
    /// arrived, so its output stands, but the stop ends the script and
    /// nothing after it starts.
    static func exitCode(after code: Int32, stopRequested: Bool) -> Int32 {
        code == BlewExitCode.success.code && stopRequested ? BlewExitCode.interrupted.code : code
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
    /// Read with the lock held.
    private var phase: CommandPhase {
        if exitOwner != .none { return .exiting }
        return openSpans == 0 ? .idle : (interrupted ? .interrupting : .running)
    }
    private var exitHook: (() -> Void)?
    private var sources: [DispatchSourceSignal] = []
    /// Who is ending the process, and so with which code. The first to
    /// claim the exit owns it: the main thread returning from its command
    /// (`beginOrdinaryExit`), with the command's code, or the signal queue
    /// (`respond(to:)`), with the signal's.
    private var exitOwner = ExitOwner.none

    private enum ExitOwner: Equatable { case none, ordinary(code: Int32), signal(code: Int32) }

    /// How the signal queue ends the process (`respond(to:)`).
    struct SignalExit: Equatable {
        /// The code the process exits with.
        let code: Int32
        /// Whether the signal queue runs the exit cleanup: not when the
        /// main thread's ordinary exit is already running it.
        let runsCleanup: Bool
    }

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
    /// command instead of ending the process. Once the exit has begun (a
    /// signal's, or the main thread's while a `blew mcp` tool call is still
    /// in flight), no command starts: the caller waits for the exit instead.
    func commandStarted() {
        let exitBegun: Bool = lock.withLock {
            if exitOwner != .none { return true }
            if openSpans == 0 { interrupted = false }
            openSpans += 1
            return false
        }
        if exitBegun { waitForExit() }
    }

    /// The span that `commandStarted` opened has closed. Returns whether a
    /// stop was requested (`stopRequested`) as it closes; for the outermost
    /// span, whether one was requested while it was open. The answer is read
    /// under the same lock as the close, so a SIGINT that arrives after it
    /// finds the span closed and is not lost between the two.
    @discardableResult
    func commandFinished() -> Bool {
        lock.withLock {
            let stop = stopRequestedLocked
            openSpans -= 1
            if openSpans == 0 { interrupted = false }
            return stop
        }
    }

    /// Whether the running command is asked to stop: a SIGINT interrupted
    /// it, or the exit has begun (a signal's: SIGTERM, or a SIGINT outside
    /// a command; or the main thread's), whose cleanup the command must not
    /// run beside. A SIGINT's
    /// stop stays set until the outermost span closes, so a REPL command
    /// interrupted between two waits stops at the next one; an exit's stays
    /// set for good.
    var stopRequested: Bool {
        lock.withLock { stopRequestedLocked }
    }

    /// `stopRequested`, read with the lock held.
    private var stopRequestedLocked: Bool {
        interrupted || exitOwner != .none
    }

    // MARK: - Exit

    /// The main thread begins the process's ordinary exit with `code`, and
    /// then runs the exit cleanup (`exitOrdinarily` is the caller). From here
    /// on `code` is the process's exit code: a signal that arrives during
    /// the cleanup ends the process at once, with this code. When a signal
    /// has already begun the exit, this never returns, so the signal's
    /// cleanup finishes and its code is the one the process ends with.
    func beginOrdinaryExit(with code: Int32) {
        let signalOwnsTheExit: Bool = lock.withLock {
            if case .signal = exitOwner { return true }
            exitOwner = .ordinary(code: code)
            return false
        }
        if signalOwnsTheExit { waitForExit() }
    }

    /// Block the calling thread until the exit's owner ends the process.
    private func waitForExit() -> Never {
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
        if let exit = respond(to: signal) { exitProcess(exit) }
    }

    /// Decide what `signal` does and, when it ends the process, claim the
    /// exit, in one locked step: nil when it asked the running command to
    /// stop. Between a decision to exit and its claim, a command could
    /// finish without seeing the stop and claim an ordinary exit with its
    /// own code, or another command start.
    ///
    /// When the signal is the first to claim the exit, from here on no
    /// command starts, running commands are asked to stop, and the main
    /// thread does not exit on its own; the signal queue runs the cleanup
    /// and exits with the signal's code. When the main thread's ordinary
    /// exit began first, its code stands and its cleanup is not run twice.
    /// Internal so tests can take the step without exiting.
    func respond(to signal: HandledSignal) -> SignalExit? {
        lock.withLock {
            let decision = SignalPolicy.respond(to: signal, in: phase)
            if decision.next == .interrupting { interrupted = true }
            guard case .exit(let code) = decision.response else { return nil }
            switch exitOwner {
            case .none:
                exitOwner = .signal(code: code)
                return SignalExit(code: code, runsCleanup: true)
            case .ordinary(let ownerCode), .signal(let ownerCode):
                return SignalExit(code: ownerCode, runsCleanup: false)
            }
        }
    }

    /// Give the terminal back, run the exit hook, stop advertising and
    /// disconnect (unless the main thread's ordinary exit is already doing
    /// that), flush standard output and exit, as `respond(to:)` decided.
    /// Restoring the terminal keeps its lock, so from then on the REPL
    /// cannot enter raw mode again and reads no more input.
    ///
    /// The flush is skipped when another thread holds standard output (it
    /// may be blocked writing to a pipe nobody reads), and `_exit` ends the
    /// process without atexit handlers, so neither can keep a signalled
    /// blew from exiting. Output is line-buffered, so at most a partial
    /// line is lost.
    private func exitProcess(_ exit: SignalExit) -> Never {
        LineNoise.restoreTerminalForExit()
        let hook = lock.withLock { exitHook }
        hook?()
        if exit.runsCleanup { exitCleanup() }
        StandardOutput.flushUnlessLocked()
        _exit(exit.code)
    }
}
