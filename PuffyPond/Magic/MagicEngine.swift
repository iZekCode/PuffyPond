import Foundation
import CoreML
import CoreGraphics
import StableDiffusion

/// Runs the on-device diffusion pipeline. All model work happens inside this actor, off the main actor.
actor MagicEngine {
    enum Failure: LocalizedError {
        case controlNetMissing
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .controlNetMissing: return "The scribble ControlNet model is missing"
            case .notLoaded: return "The Magic model isn't loaded"
            }
        }
    }

    private let resources: URL
    private var pipeline: StableDiffusionPipeline?

    init(resources: URL) {
        self.resources = resources
    }

    var isLoaded: Bool { pipeline != nil }

    func load() async throws {
        guard pipeline == nil else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        let loaded = try StableDiffusionPipeline(resourcesAt: resources,
                                                 controlNet: [try Self.controlNetName(in: resources)],
                                                 configuration: config,
                                                 disableSafety: false,
                                                 reduceMemory: true)
        try loaded.loadResources()
        pipeline = loaded
    }

    /// Nil means the safety checker blocked the picture. Cancelling the calling task throws `CancellationError`.
    func generate(_ inputs: MagicInputs, prompt: MagicPrompt, seed: UInt32) async throws -> CGImage? {
        if pipeline == nil { try await load() }
        guard let pipeline else { throw Failure.notLoaded }
        let config = Self.configuration(for: inputs, prompt: prompt, seed: seed)
        let images = try pipeline.generateImages(configuration: config) { _ in !Task.isCancelled }
        try Task.checkCancellation()                     // the package returns no images when stopped early
        return images.first ?? nil
    }

    func unload() {
        pipeline?.unloadResources()
        pipeline = nil
    }

    // MARK: Pure helpers

    nonisolated static func configuration(for inputs: MagicInputs, prompt: MagicPrompt,
                                          seed: UInt32) -> StableDiffusionPipeline.Configuration {
        var config = StableDiffusionPipeline.Configuration(prompt: prompt.positive)
        config.negativePrompt = prompt.negative
        config.startingImage = inputs.start
        config.strength = 0.65
        config.stepCount = 4
        config.guidanceScale = 1.5
        config.controlNetInputs = [inputs.scribble]
        config.seed = seed
        config.disableSafety = false                     // a kids app: the safety checker stays on
        config.schedulerType = .dpmSolverMultistepScheduler
        return config
    }

    /// The converter chooses the ControlNet's file name, so use whichever single model is in `controlnet/`.
    nonisolated static func controlNetName(in resources: URL) throws -> String {
        let folder = resources.appending(path: "controlnet")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".mlmodelc") }
        guard names.count == 1, let name = names.first else { throw Failure.controlNetMissing }
        return String(name.dropLast(".mlmodelc".count))
    }
}
