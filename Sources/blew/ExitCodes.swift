import ArgumentParser
import Foundation
import BLEManager

struct BlewExitCode: Error, CustomStringConvertible {
    let code: Int32

    init(_ code: Int32) {
        self.code = code
    }

    static let success = BlewExitCode(0)
    static let notFound = BlewExitCode(2)
    static let bluetoothUnavailable = BlewExitCode(3)
    static let timeout = BlewExitCode(4)
    static let operationFailed = BlewExitCode(5)
    static let invalidArguments = BlewExitCode(6)
    /// Stopped by SIGINT (Ctrl-C): 128 + 2.
    static let interrupted = BlewExitCode(130)
    /// Stopped by SIGTERM: 128 + 15.
    static let terminated = BlewExitCode(143)

    var description: String { "exit code \(code)" }
}

extension BlewExitCode: CustomNSError {
    var errorCode: Int { Int(code) }
    static var errorDomain: String { "blew" }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: description]
    }
}

extension BlewExitCode {
    /// The documented exit code for a command that failed with `error`, by
    /// the error's type: a BLEError's own code, 6 for an argument blew cannot
    /// use, and 5 (operation failed) for any other error.
    init(for error: Error) {
        switch error {
        case let code as BlewExitCode: self = code
        case let error as BLEError: self.init(error.exitCode)
        case is InvalidArgument: self = .invalidArguments
        default: self = .operationFailed
        }
    }
}

extension CommandResult {
    /// Record that the command failed with `error`: its message, and the
    /// exit code `BlewExitCode(for:)` gives it.
    mutating func fail(_ error: Error) {
        errors.append(error.localizedDescription)
        exitCode = BlewExitCode(for: error).code
    }

    /// The result of a command that failed with `error` before it started.
    init(failing error: Error) {
        self.init()
        fail(error)
    }
}
