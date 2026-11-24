import Foundation
import CoreBluetooth

public enum BLEError: Error, Sendable {
    // Central errors
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

    // Peripheral errors
    case peripheralUnavailable(String)
    case advertisingFailed(String)
    case serviceRegistrationFailed(String)

    public var exitCode: Int32 {
        switch self {
        case .bluetoothUnavailable, .peripheralUnavailable: return 3
        case .deviceNotFound: return 2
        case .timeout: return 4
        case .notConnected, .connectionFailed, .serviceNotFound,
             .characteristicNotFound, .readFailed, .writeFailed,
             .subscribeFailed, .operationFailed,
             .advertisingFailed, .serviceRegistrationFailed: return 5
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
        case .peripheralUnavailable(let msg): return "Peripheral unavailable: \(msg)"
        case .advertisingFailed(let msg): return "Advertising failed: \(msg)"
        case .serviceRegistrationFailed(let msg): return "Service registration failed: \(msg)"
        }
    }

    /// Why the central cannot be used while CoreBluetooth reports `state`
    /// (any state but poweredOn).
    static func unavailable(_ state: CBManagerState) -> BLEError {
        switch state {
        case .poweredOff: return .bluetoothUnavailable("Bluetooth is powered off")
        case .unauthorized: return .bluetoothUnavailable("Bluetooth access unauthorized")
        case .unsupported: return .bluetoothUnavailable("Bluetooth is not supported")
        case .resetting: return .bluetoothUnavailable("Bluetooth is resetting")
        default: return .bluetoothUnavailable("Bluetooth state: \(state.rawValue)")
        }
    }
}
