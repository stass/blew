import XCTest
@testable import blew

final class SignalPolicyTests: XCTestCase {

    func testSIGINTAsksARunningCommandToStop() {
        let decision = SignalPolicy.respond(to: .interrupt, in: .running)
        XCTAssertEqual(decision.response, .interruptCommand)
        XCTAssertEqual(decision.next, .interrupting)
    }

    func testSIGINTWithNoRunningCommandExits130() {
        XCTAssertEqual(SignalPolicy.respond(to: .interrupt, in: .idle).response, .exit(130))
    }

    func testSecondSIGINTWhileStoppingExits130() {
        XCTAssertEqual(SignalPolicy.respond(to: .interrupt, in: .interrupting).response, .exit(130))
    }

    func testSIGTERMExits143InEveryPhase() {
        for phase in [CommandPhase.idle, .running, .interrupting] {
            XCTAssertEqual(SignalPolicy.respond(to: .terminate, in: phase).response, .exit(143), "\(phase)")
        }
    }
}
