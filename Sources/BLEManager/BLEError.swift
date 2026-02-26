import Foundation

public enum BLEError: Error, Sendable {
    case bluetoothUnavailable(String)
    case notConnected
    case deviceNotFound(String)
    case connectionFailed(String)
    case timeout
    case serviceNotFound(String)
    case characteristicNotFound(String)
    case readFailed(String)
    case writeFailed(String)
    case subscribeFailed(String)
    case operationFailed(String)

    public var exitCode: Int32 {
        switch self {
        case .bluetoothUnavailable: return 3
        case .deviceNotFound: return 2
        case .timeout: return 4
        case .notConnected, .connectionFailed, .serviceNotFound,
             .characteristicNotFound, .readFailed, .writeFailed,
             .subscribeFailed, .operationFailed: return 5
        }
    }

    public var localizedDescription: String {
        switch self {
        case .bluetoothUnavailable(let msg): return "Bluetooth unavailable: \(msg)"
        case .notConnected: return "Not connected to any device"
        case .deviceNotFound(let id): return "Device not found: \(id)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .timeout: return "Operation timed out"
        case .serviceNotFound(let uuid): return "Service not found: \(uuid)"
        case .characteristicNotFound(let uuid): return "Characteristic not found: \(uuid)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .subscribeFailed(let msg): return "Subscribe failed: \(msg)"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
        }
    }
}
