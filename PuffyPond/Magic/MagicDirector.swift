import Foundation

/// Decides when Magic should re-imagine the canvas. A pure state machine: time comes in as an
/// argument, so it is easy to test and never touches the frame loop.
nonisolated struct MagicDirector {
    enum Action: Equatable { case none, generate(version: Int) }

    /// Seconds the canvas must sit still after the last change.
    static let idleDelay: Double = 0.45
    /// Fingerprint difference (0…1) that counts as "the picture changed".
    static let minChange: Float = 0.01

    /// Bumped by every change; a result is only shown if it was made for the current version.
    private(set) var canvasVersion = 0
    private(set) var isRunning = false

    private var lastChange: Double = 0
    private var dirty = false
    private var runningVersion: Int?
    private var runningFingerprint: [UInt8]?
    /// Fingerprint of the picture that is currently on show.
    private var shownFingerprint: [UInt8]?

    /// A stroke ended, or paint was erased or cleared.
    mutating func canvasChanged(at time: Double) {
        canvasVersion += 1
        lastChange = time
        dirty = true
    }

    mutating func tick(at time: Double, fingerprint: () -> [UInt8]?, thermal: ProcessInfo.ThermalState) -> Action {
        guard dirty, !isRunning, time - lastChange >= Self.idleDelay else { return .none }
        // Too hot: stay dirty and try again once it has cooled down.
        guard thermal != .serious, thermal != .critical else { return .none }

        guard let print = fingerprint() else {
            // Blank canvas (or only template dots): nothing to imagine.
            dirty = false
            shownFingerprint = nil
            return .none
        }
        if let shown = shownFingerprint, ScribbleMap.difference(shown, print) < Self.minChange {
            dirty = false
            return .none
        }
        dirty = false
        isRunning = true
        runningVersion = canvasVersion
        runningFingerprint = print
        return .generate(version: canvasVersion)
    }

    /// True when the result still matches the canvas and should be shown.
    mutating func finished(version: Int) -> Bool {
        guard version == runningVersion else { return false }   // cancelled, or an older run
        isRunning = false
        runningVersion = nil
        defer { runningFingerprint = nil }
        guard version == canvasVersion else { return false }
        shownFingerprint = runningFingerprint
        return true
    }

    /// App went to the background, or Magic was switched off: whatever is running is cancelled.
    mutating func pause() {
        isRunning = false
        runningVersion = nil
        runningFingerprint = nil
    }
}
