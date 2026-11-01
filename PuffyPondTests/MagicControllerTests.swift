import Testing
import Foundation
import CoreGraphics
@testable import PuffyPond

/// Stands in for the diffusion model: records calls and can hold a generation until the test lets it finish.
actor FakeEngine: MagicGenerating {
    private(set) var generateCount = 0
    private(set) var unloadCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holds: Bool
    let result: CGImage?

    init(holds: Bool = false, result: CGImage? = solidImage(gray: 0.5, 640, 384)) {
        self.holds = holds
        self.result = result
    }

    func load() async throws {}
    func unload() { unloadCount += 1 }

    func generate(_ inputs: MagicInputs, prompt: MagicPrompt, seed: UInt32) async throws -> CGImage? {
        generateCount += 1
        if holds { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        return result
    }

    func release() { holds = false; gate?.resume(); gate = nil }
}

/// What the fake camera sees; tests change it between generations.
final class Photos {
    var current: CGImage
    init(_ image: CGImage) { current = image }
}

@MainActor
struct MagicControllerTests {
    private let blank = solidImage(gray: 0.9, 640, 384)
    private let painted = solidImage(gray: 0.9, 640, 384, redLineAtY: 192)
    private let paintedMore = solidImage(gray: 0.9, 640, 384, redLineAtY: 80)

    /// A controller wired to a fake engine and a model store that says "ready".
    private func make(engine: FakeEngine, photo: CGImage? = nil, modelReady: Bool = true,
                      photos: Photos? = nil) throws -> (MagicController, MagicOverlay) {
        let root = FileManager.default.temporaryDirectory.appending(path: "MagicControllerTests-\(UUID().uuidString)")
        if modelReady {
            let resources = root.appending(path: "v/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: resources.appending(path: "vocab.json"))
        }
        let store = MagicModelStore(root: root, version: "v", remote: URL(string: "file:///none")!, sha256: "")
        let overlay = MagicOverlay()
        let camera = photos ?? Photos(photo ?? painted)
        let blankShot = blank
        let controller = MagicController(overlay: overlay, store: store,
                                         photograph: { _ in camera.current }, blank: { blankShot },
                                         context: { (.fish, [.jellyfish]) },
                                         makeEngine: { _ in engine })
        return (controller, overlay)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func generatesAfterTheCanvasSitsStillAndShowsTheResult() async throws {
        let engine = FakeEngine()
        let (magic, overlay) = try make(engine: engine)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.2)
        #expect(await engine.generateCount == 0)          // not idle long enough
        magic.tick(at: 0.6)
        await waitUntil { overlay.isShowing }
        #expect(overlay.isShowing)
        #expect(await engine.generateCount == 1)
        #expect(magic.isGenerating == false)
    }

    @Test func staleResultIsNotShown() async throws {
        let engine = FakeEngine(holds: true)
        let (magic, overlay) = try make(engine: engine)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.6)
        await waitUntil { magic.isGenerating }
        magic.canvasChanged(at: 0.7)                        // erased while it was thinking
        await engine.release()
        await waitUntil { !magic.isGenerating }
        #expect(overlay.isShowing == false)
    }

    @Test func clearingHidesThePicture() async throws {
        let engine = FakeEngine()
        let (magic, overlay) = try make(engine: engine)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.6)
        await waitUntil { overlay.isShowing }
        magic.cleared()
        #expect(overlay.isShowing == false)
    }

    @Test func clearingWhileGeneratingDropsTheResult() async throws {
        let engine = FakeEngine(holds: true)
        let (magic, overlay) = try make(engine: engine)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.6)
        await waitUntil { magic.isGenerating }
        magic.cleared()
        await engine.release()
        await waitUntil { !magic.isGenerating }
        #expect(overlay.isShowing == false)
    }

    @Test func turningOffCancelsHidesAndUnloads() async throws {
        let engine = FakeEngine(holds: true)
        let (magic, overlay) = try make(engine: engine)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.6)
        await waitUntil { magic.isGenerating }
        magic.isOn = false
        #expect(magic.isGenerating == false)
        await engine.release()
        await waitUntil { await engine.unloadCount == 1 }
        #expect(overlay.isShowing == false)
        #expect(await engine.unloadCount == 1)
    }

    @Test func erasingHidesTheOutOfDatePicture() async throws {
        let engine = FakeEngine()
        let (magic, overlay) = try make(engine: engine)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.6)
        await waitUntil { overlay.isShowing }
        magic.canvasChanged(at: 1)
        #expect(overlay.isShowing == false)
    }

    @Test func pauseCancelsButKeepsThePicture() async throws {
        let engine = FakeEngine()
        let (magic, overlay) = try make(engine: engine)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.6)
        await waitUntil { overlay.isShowing }
        magic.pause()
        #expect(overlay.isShowing)
    }

    @Test func blankCanvasNeverGenerates() async throws {
        let engine = FakeEngine()
        let (magic, overlay) = try make(engine: engine, photo: blank)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.generateCount == 0)
        #expect(overlay.isShowing == false)
    }

    @Test func missingModelNeverGenerates() async throws {
        let engine = FakeEngine()
        let (magic, _) = try make(engine: engine, modelReady: false)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.generateCount == 0)
    }

    @Test func offMeansNothingHappens() async throws {
        let engine = FakeEngine()
        let (magic, _) = try make(engine: engine)
        magic.canvasChanged(at: 0)
        magic.tick(at: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.generateCount == 0)
    }

    @Test func startingANewStrokeHidesThePictureAndWaitsForTheStrokeToEnd() async throws {
        let engine = FakeEngine()
        let photos = Photos(painted)
        let (magic, overlay) = try make(engine: engine, photos: photos)
        magic.isOn = true
        magic.canvasChanged(at: 0)
        magic.tick(at: 0.6)
        await waitUntil { overlay.isShowing }

        photos.current = paintedMore
        magic.strokeBegan(at: 2)
        #expect(overlay.isShowing == false)
        magic.tick(at: 5)                                    // long stroke, still going
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.generateCount == 1)

        magic.canvasChanged(at: 5.1)                         // stroke ended
        magic.tick(at: 5.2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.generateCount == 1)            // idle delay not over yet
        magic.tick(at: 5.7)
        await waitUntil { overlay.isShowing }
        #expect(await engine.generateCount == 2)
    }
}
