import Foundation

/// The CoreBluetooth callback that answers a GATT request of the central,
/// and the key its requests queue under in `PendingCallbacks`. CoreBluetooth
/// answers a peripheral's requests in the order they were made, one callback
/// each, with no request identifier.
enum CentralCallback: Hashable, Sendable {
    /// `didDiscoverServices`, answering `discoverServices`.
    case services
    /// `didDiscoverCharacteristicsFor` the service.
    case characteristics(service: String)
    /// `didDiscoverDescriptorsFor` the characteristic.
    case descriptors(characteristic: String)
    /// `didUpdateValueFor` the characteristic, answering `readValue`. The
    /// same callback carries notifications, which answer no request.
    case value(characteristic: String)
    /// `didWriteValueFor` the characteristic, answering a write with response.
    case write(characteristic: String)
}

/// A GATT request of the central with the wait for its answer. The callback
/// that answers it follows from the request, so a wait cannot be queued
/// under the wrong callback.
enum CentralRequest: Sendable {
    case discoverServices(CheckedContinuation<[String], Error>)
    case discoverCharacteristics(service: String, CheckedContinuation<[BLEEvent.DiscoveredCharacteristic], Error>)
    case discoverDescriptors(characteristic: String, CheckedContinuation<[String], Error>)
    case read(characteristic: String, CheckedContinuation<Data, Error>)
    case write(characteristic: String, CheckedContinuation<Void, Error>)

    var answeredBy: CentralCallback {
        switch self {
        case .discoverServices: return .services
        case .discoverCharacteristics(let service, _): return .characteristics(service: service)
        case .discoverDescriptors(let characteristic, _): return .descriptors(characteristic: characteristic)
        case .read(let characteristic, _): return .value(characteristic: characteristic)
        case .write(let characteristic, _): return .write(characteristic: characteristic)
        }
    }

    func fail(_ error: Error) {
        switch self {
        case .discoverServices(let cont): cont.resume(throwing: error)
        case .discoverCharacteristics(_, let cont): cont.resume(throwing: error)
        case .discoverDescriptors(_, let cont): cont.resume(throwing: error)
        case .read(_, let cont): cont.resume(throwing: error)
        case .write(_, let cont): cont.resume(throwing: error)
        }
    }
}

/// What waits in the processor's `PendingCallbacks`: a GATT request, or a
/// write without response waiting until the peripheral can take it. The
/// latter is never queued as issued: on every
/// `isReadyToSendWriteWithoutResponse` the waiting writes run their `poll`,
/// oldest first, and a poll sends its write when the peripheral has room.
/// Notifications are not requests here; `NotificationSubscriptions` owns
/// them.
enum CentralWaiter: Sendable {
    case request(CentralRequest)
    case readyToWrite(CheckedContinuation<Void, Error>, poll: @Sendable () -> Void)

    func fail(_ error: Error) {
        switch self {
        case .request(let request): request.fail(error)
        case .readyToWrite(let cont, _): cont.resume(throwing: error)
        }
    }
}
