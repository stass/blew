import Foundation
import XCTest
@testable import blew

/// `LiveDisplay`: the timer-driven redraw behind the scan spinner and
/// `scan -w`. A `stop()` that races a redraw erases exactly the lines that
/// redraw put on screen, and nothing is drawn after it.
final class LiveDisplayTests: XCTestCase {

    /// What the display did, in order, as the test's terminal saw it.
    private final class Screen: @unchecked Sendable {
        enum Event: Equatable { case drawBegan(replacing: Int), drawEnded(lines: Int), erased(Int) }
        private let lock = NSLock()
        private var _events: [Event] = []
        var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
        func record(_ event: Event) { lock.lock(); _events.append(event); lock.unlock() }
    }

    /// Ctrl-C while a frame is being written: `stop()` waits for that frame,
    /// erases its lines, and no frame follows the erase.
    func testStopDuringADrawErasesThatDrawsLinesAndNothingIsDrawnAfter() {
        let screen = Screen()
        let inDraw = DispatchSemaphore(value: 0)
        let finishDraw = DispatchSemaphore(value: 0)
        var firstDraw = true // touched only by `draw`, which runs one at a time
        let display = LiveDisplay(interval: .milliseconds(1), draw: { replacing in
            screen.record(.drawBegan(replacing: replacing))
            if firstDraw {
                firstDraw = false
                inDraw.signal()
                finishDraw.wait()
            }
            screen.record(.drawEnded(lines: 3))
            return 3
        }, erase: { screen.record(.erased($0)) })

        display.start()
        XCTAssertEqual(inDraw.wait(timeout: .now() + 5), .success)

        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            display.stop()
            stopped.signal()
        }
        // `stop()` must not finish while the frame is half written.
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.1), .timedOut)
        finishDraw.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)

        // Give a timer that was not stopped time to draw again.
        Thread.sleep(forTimeInterval: 0.05)
        // The timer may fit in another whole frame before `stop()` gets the
        // queue; the erase still comes last, once, and covers the last frame.
        let events = screen.events
        XCTAssertEqual(events.filter { if case .erased = $0 { return true }; return false }.count, 1)
        let lastDrawn = events.last { if case .drawEnded = $0 { return true }; return false }
        guard case .drawEnded(let lines)? = lastDrawn else { return XCTFail("no frame drawn: \(events)") }
        XCTAssertEqual(events.last, .erased(lines))
        for (index, event) in events.dropLast().enumerated() {
            guard case .drawBegan = event else { continue }
            XCTAssertEqual(events[index + 1], .drawEnded(lines: 3), "a frame half drawn at the erase: \(events)")
        }
    }

    /// Each redraw replaces the lines of the one before it; `stop()` erases
    /// the last one's, once, however often it is called.
    func testRedrawsReplaceTheLastFrameAndAStopTwiceErasesOnce() {
        let screen = Screen()
        let drewTwice = DispatchSemaphore(value: 0)
        var lines = 0 // touched only by `draw`
        let display = LiveDisplay(interval: .milliseconds(1), draw: { replacing in
            screen.record(.drawBegan(replacing: replacing))
            lines += 1
            if lines == 2 { drewTwice.signal() }
            return lines
        }, erase: { screen.record(.erased($0)) })

        display.start()
        XCTAssertEqual(drewTwice.wait(timeout: .now() + 5), .success)
        display.stop()
        display.stop()

        let events = screen.events
        let begins = events.compactMap { if case .drawBegan(let r) = $0 { return r }; return nil }
        XCTAssertEqual(begins, Array(0..<begins.count), "each redraw replaces the lines of the one before")
        XCTAssertEqual(events.last, .erased(begins.count))
        XCTAssertEqual(events.filter { if case .erased = $0 { return true }; return false }.count, 1)
    }

    /// A display stopped before its first frame erases nothing and never draws.
    func testStopBeforeStartNeverDraws() {
        let screen = Screen()
        let display = LiveDisplay(interval: .milliseconds(1), draw: { replacing in
            screen.record(.drawBegan(replacing: replacing))
            return 1
        }, erase: { screen.record(.erased($0)) })
        display.stop()
        display.start()
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(screen.events, [.erased(0)])
    }
}
