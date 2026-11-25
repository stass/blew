import Foundation

/// A display on stderr that a timer redraws in place until `stop()` erases
/// it: the scan spinner and `scan -w`. The owner supplies what to draw and
/// how to erase it; this type owns when.
///
/// The timer, the count of lines on screen and the stopped flag belong to a
/// private serial queue, and every redraw runs on it. `stop()` cancels the
/// timer and erases inside `queue.sync`, so it waits out a redraw in
/// progress, erases exactly the lines that redraw left on screen, and no
/// redraw runs after it. A display is used once: `start()` after `stop()`
/// draws nothing, and a second `stop()` erases nothing.
///
/// `draw` and `erase` run on the private queue, one at a time; the owner's
/// state they alone touch needs no lock of its own. They must not call
/// back into the display: `start()` and `stop()` wait on the queue.
final class LiveDisplay {
    private let queue = DispatchQueue(label: "blew.live-display", qos: .userInteractive)
    private let interval: DispatchTimeInterval
    /// Draws one frame over the `replacing` lines the previous frame left
    /// on screen and returns the number of lines this frame leaves.
    private let draw: (_ replacing: Int) -> Int
    /// Erases the `drawn` lines the last frame left on screen.
    private let erase: (_ drawn: Int) -> Void

    // Read and written only on `queue`.
    private var timer: DispatchSourceTimer?
    private var linesOnScreen = 0
    private var stopped = false

    init(interval: DispatchTimeInterval, draw: @escaping (_ replacing: Int) -> Int,
         erase: @escaping (_ drawn: Int) -> Void) {
        self.interval = interval
        self.draw = draw
        self.erase = erase
    }

    /// Starts the redraws: the first at once, then one per `interval`.
    func start() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard !stopped, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops the redraws and erases the last frame. Returns once it is
    /// erased; no frame is drawn after. It waits for a redraw in progress,
    /// one blocked on a stalled stderr included.
    func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            erase(linesOnScreen)
            linesOnScreen = 0
        }
    }

    private func tick() {
        guard !stopped else { return }
        linesOnScreen = draw(linesOnScreen)
    }
}
