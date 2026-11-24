import XCTest
@testable import blew

/// The table behind `sub -b`, `sub stop` and `sub status`.
final class BackgroundSubscriptionsTests: XCTestCase {
    /// A flag a subscription body polls, ignoring cancellation the way a
    /// task still unwinding does.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        func raise() { lock.withLock { set = true } }
        var isRaised: Bool { lock.withLock { set } }
    }

    private func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }

    /// `sub -b X` run again replaces the subscription; the replaced task
    /// ending later does not remove its replacement, so `sub status` still
    /// lists it and `sub stop X` still finds it.
    func testReplacedSubscriptionEndingLaterKeepsItsReplacement() {
        let subscriptions = BackgroundSubscriptions()
        let firstMayEnd = Flag(), firstEnded = Flag(), secondCancelled = Flag()
        subscriptions.start("FFF1") {
            while !firstMayEnd.isRaised { try? await Task.sleep(nanoseconds: 5_000_000) }
            firstEnded.raise()
        }
        subscriptions.start("FFF1") {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            secondCancelled.raise()
        }
        firstMayEnd.raise()
        XCTAssertTrue(eventually { firstEnded.isRaised })
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(subscriptions.characteristics, ["FFF1"], "the replaced subscription removed its replacement")
        XCTAssertTrue(subscriptions.stop("FFF1"))
        XCTAssertTrue(eventually { secondCancelled.isRaised }, "sub stop did not cancel the subscription")
        XCTAssertEqual(subscriptions.characteristics, [])
        XCTAssertFalse(subscriptions.stop("FFF1"))
    }

    /// A subscription that ends by itself (count reached, an error) leaves
    /// the table.
    func testSubscriptionThatEndsLeavesTheTable() {
        let subscriptions = BackgroundSubscriptions()
        subscriptions.start("2A37") {}
        XCTAssertTrue(eventually { subscriptions.characteristics.isEmpty })
        XCTAssertFalse(subscriptions.stopAll())
    }

    /// `sub stop` with no characteristic cancels every subscription.
    func testStopAllCancelsEverySubscription() {
        let subscriptions = BackgroundSubscriptions()
        let cancelled = [Flag(), Flag()]
        for (characteristic, flag) in zip(["2A37", "2A19"], cancelled) {
            subscriptions.start(characteristic) {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                flag.raise()
            }
        }
        XCTAssertEqual(subscriptions.characteristics, ["2A19", "2A37"])
        XCTAssertTrue(subscriptions.stopAll())
        XCTAssertTrue(eventually { cancelled.allSatisfy(\.isRaised) })
        XCTAssertEqual(subscriptions.characteristics, [])
    }
}
