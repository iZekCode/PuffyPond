import Foundation
import Observation
import CoreGraphics
import QuartzCore

/// Glue between the easel and the model: tells the director what happened on the canvas, and when it
/// says go, photographs the canvas, runs the model and fades the result in.
@MainActor @Observable
final class MagicController {
    private(set) var isGenerating = false

    private var on = false
    /// Turning off cancels any run, hides the picture and frees the model's memory.
    var isOn: Bool {
        get { on }
        set { setOn(newValue) }
    }

    @ObservationIgnored private let overlay: MagicOverlay
    @ObservationIgnored private let store: MagicModelStore
    @ObservationIgnored private let photograph: (CGFloat) -> CGImage?
    @ObservationIgnored private let blank: () -> CGImage?
    @ObservationIgnored private let context: () -> (TemplateKind?, [CritterKind])
    @ObservationIgnored private let seed: () -> UInt32
    @ObservationIgnored private let thermal: () -> ProcessInfo.ThermalState
    @ObservationIgnored private let makeEngine: (URL) -> any MagicGenerating

    @ObservationIgnored private var director = MagicDirector()
    @ObservationIgnored private var engine: (any MagicGenerating)?
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var pendingInputs: MagicInputs?
    @ObservationIgnored private var lastTime: Double = 0
    /// A stroke is in progress: nothing is generated until it ends.
    @ObservationIgnored private var isPainting = false

    static let photoWidth: CGFloat = 640

    init(overlay: MagicOverlay, store: MagicModelStore,
         photograph: @escaping (CGFloat) -> CGImage?, blank: @escaping () -> CGImage?,
         context: @escaping () -> (TemplateKind?, [CritterKind]),
         seed: @escaping () -> UInt32 = { 0 },
         thermal: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         makeEngine: @escaping (URL) -> any MagicGenerating = { MagicEngine(resources: $0) }) {
        self.overlay = overlay
        self.store = store
        self.photograph = photograph
        self.blank = blank
        self.context = context
        self.seed = seed
        self.thermal = thermal
        self.makeEngine = makeEngine
    }

    // MARK: Events from the easel

    /// A stroke ended, or paint was erased. The picture on show no longer matches the canvas, so it steps aside.
    func canvasChanged(at time: Double) {
        guard on else { return }
        lastTime = time
        isPainting = false
        director.canvasChanged(at: time)
        if overlay.isShowing { overlay.hide(fade: 0.25) }
    }

    /// A new stroke started: the picture steps aside so the paint can be seen, and a run that finishes
    /// meanwhile is out of date.
    func strokeBegan(at time: Double) {
        guard on else { return }
        lastTime = time
        isPainting = true
        director.canvasChanged(at: time)
        overlay.hide(fade: 0.25)
    }

    func cleared() {
        overlay.hide()
        guard on else { return }
        isPainting = false
        director.canvasChanged(at: lastTime)
    }

    func tick(at time: Double) {
        guard on, !isPainting, case .ready(let resources) = store.state else { return }
        lastTime = time
        pendingInputs = nil
        let action = director.tick(at: time, fingerprint: { [self] in
            pendingInputs = makeInputs()
            return pendingInputs?.fingerprint
        }, thermal: thermal())
        guard case .generate(let version) = action, let inputs = pendingInputs else { return }
        pendingInputs = nil

        let (template, brushes) = context()
        let prompt = MagicPrompt.make(template: template, brushes: brushes)
        let engine = engine ?? makeEngine(resources)
        self.engine = engine
        let seed = seed()
        isGenerating = true
        generation = Task { [weak self] in
            var image: CGImage?
            do {
                image = try await engine.generate(inputs, prompt: prompt, seed: seed)
            } catch {
                image = nil                              // cancelled, or the model failed: just keep the paint
            }
            self?.generationEnded(version: version, image: image)
        }
    }

    /// The app is going to the background: stop thinking, but keep what is on show.
    func pause() {
        generation?.cancel()
        generation = nil
        director.pause()
        isGenerating = false
    }

    // MARK: Private

    private func setOn(_ newValue: Bool) {
        guard newValue != on else { return }
        on = newValue
        if newValue {
            isPainting = false
            director = MagicDirector()
            director.canvasChanged(at: lastTime)         // imagine whatever is already on the canvas
        } else {
            pause()
            overlay.hide()
            let old = engine
            engine = nil
            Task { await old?.unload() }
        }
    }

    private func generationEnded(version: Int, image: CGImage?) {
        let current = director.finished(version: version)
        isGenerating = director.isRunning
        if current, let image { overlay.show(image) }
    }

    private func makeInputs() -> MagicInputs? {
        guard let painted = photograph(Self.photoWidth), let blank = blank() else { return nil }
        return ScribbleMap.make(painted: painted, blank: blank)
    }
}
