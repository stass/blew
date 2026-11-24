import XCTest
@testable import BLEManager

final class BLEEventQueueTests: XCTestCase {
    private let device = UUID()

    private func discovered(_ rssi: Int) -> BLEEvent {
        .didDiscover(peripheralId: device, name: nil, rssi: rssi, serviceUUIDs: [], manufacturerData: nil)
    }

    /// An `allowDuplicates` scan flood fills the queue: the next scan result
    /// is dropped and counted, but a didConnect and a write answer queued
    /// behind the flood still reach the processor, in order.
    func testQueueFullOfScanResultsStillDeliversLifecycleEvents() {
        let queue = BLEEventQueue()
        var accepted = 0
        for i in 0..<4096 where queue.enqueue(discovered(i)) { accepted += 1 }
        XCTAssertTrue(queue.enqueue(.didConnect(peripheralId: device)), "the didConnect was dropped")
        XCTAssertTrue(queue.enqueue(.didWriteValue(peripheralId: device, characteristicUUID: "TX", error: nil)))
        XCTAssertEqual(accepted, queue.scanResultLimit)
        XCTAssertEqual(queue.droppedScanResults, 4096 - accepted)

        var drained: [BLEEvent] = []
        while let event = queue.dequeue() { drained.append(event) }
        XCTAssertEqual(drained.count, accepted + 2)
        guard case .didConnect? = drained.dropLast().last, case .didWriteValue? = drained.last else {
            return XCTFail("the lifecycle events did not arrive after the scan results")
        }
        XCTAssertTrue(queue.enqueue(discovered(0)), "a scan result was dropped from a drained queue")
    }
}
