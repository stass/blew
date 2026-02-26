import ArgumentParser
import Foundation

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

    var description: String { "exit code \(code)" }
}

extension BlewExitCode: CustomNSError {
    var errorCode: Int { Int(code) }
    static var errorDomain: String { "blew" }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: description]
    }
}
