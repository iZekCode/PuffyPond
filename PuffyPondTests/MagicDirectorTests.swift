import Testing
import Foundation
@testable import PuffyPond

struct MagicDirectorTests {
    private let same = [UInt8](repeating: 10, count: 160)
    private let other = [UInt8](repeating: 200, count: 160)

    private func tick(_ d: inout MagicDirector, at time: Double, fingerprint: [UInt8]? = [UInt8](repeating: 10, count: 160),
                      thermal: ProcessInfo.ThermalState = .nominal) -> MagicDirector.Action {
        d.tick(at: time, fingerprint: { fingerprint }, thermal: thermal)
    }

    @Test func waitsForIdle() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        #expect(tick(&d, at: 0.3) == .none)
        #expect(tick(&d, at: 0.5) == .generate(version: 1))
    }

    @Test func nothingToDoWithoutAChange() {
        var d = MagicDirector()
        #expect(tick(&d, at: 5) == .none)
    }

    @Test func fingerprintIsNotTakenBeforeIdle() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        var calls = 0
        _ = d.tick(at: 0.1, fingerprint: { calls += 1; return [1] }, thermal: .nominal)
        #expect(calls == 0)
    }

    @Test func neverTwoAtOnce() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        #expect(tick(&d, at: 0.5) == .generate(version: 1))
        d.canvasChanged(at: 0.6)
        #expect(tick(&d, at: 1.2) == .none)
        #expect(d.isRunning)
    }

    @Test func changeDuringRunGeneratesAgainAfterIt() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        _ = tick(&d, at: 0.5)
        d.canvasChanged(at: 0.6)
        let shown = d.finished(version: 1)
        #expect(shown == false)
        #expect(tick(&d, at: 1.2, fingerprint: other) == .generate(version: 2))
    }

    @Test func unchangedFingerprintSkips() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        #expect(tick(&d, at: 0.5) == .generate(version: 1))
        let shown = d.finished(version: 1)
        #expect(shown)
        d.canvasChanged(at: 1)
        #expect(tick(&d, at: 1.6) == .none)
    }

    @Test func changedFingerprintGenerates() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        _ = tick(&d, at: 0.5)
        _ = d.finished(version: 1)
        d.canvasChanged(at: 1)
        #expect(tick(&d, at: 1.6, fingerprint: other) == .generate(version: 2))
    }

    @Test func staleResultIsDropped() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        #expect(tick(&d, at: 0.5) == .generate(version: 1))
        d.canvasChanged(at: 0.7)
        let shown = d.finished(version: 1)
        #expect(shown == false)
        #expect(d.isRunning == false)
    }

    @Test func pauseCancelsRunning() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        #expect(tick(&d, at: 0.5) == .generate(version: 1))
        d.pause()
        #expect(d.isRunning == false)
        let shown = d.finished(version: 1)
        #expect(shown == false)
    }

    @Test func lateResultOfCancelledRunDoesNotStopTheNextRun() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        _ = tick(&d, at: 0.5)
        d.pause()
        d.canvasChanged(at: 1)
        #expect(tick(&d, at: 1.6, fingerprint: other) == .generate(version: 2))
        let shown = d.finished(version: 1)
        #expect(shown == false)
        #expect(d.isRunning)
    }

    @Test func seriousThermalStateSkips() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        #expect(tick(&d, at: 1, thermal: .serious) == .none)
        #expect(tick(&d, at: 1.1, thermal: .critical) == .none)
        // Still wanted once it cools down.
        #expect(tick(&d, at: 2, thermal: .fair) == .generate(version: 1))
    }

    @Test func nilFingerprintSkips() {
        var d = MagicDirector()
        d.canvasChanged(at: 0)
        #expect(tick(&d, at: 1, fingerprint: nil) == .none)
        #expect(d.isRunning == false)
    }
}
