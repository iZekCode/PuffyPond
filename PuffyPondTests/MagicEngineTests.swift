import Testing
import CoreGraphics
import Foundation
import StableDiffusion
@testable import PuffyPond

struct MagicEngineTests {
    private func inputs() -> MagicInputs {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        return MagicInputs(start: image, scribble: image, fingerprint: [])
    }

    @Test func generationFollowsTheGlobalConstraints() {
        let prompt = MagicPrompt.make(template: .fish, brushes: [.jellyfish])
        let config = MagicEngine.configuration(for: inputs(), prompt: prompt, seed: 7)
        #expect(config.stepCount == 4)
        #expect(config.guidanceScale == 1.5)
        #expect(config.strength == 0.65)
        #expect(config.seed == 7)
        #expect(config.disableSafety == false)
        #expect(config.prompt == prompt.positive)
        #expect(config.negativePrompt == prompt.negative)
        #expect(config.startingImage != nil)
        #expect(config.controlNetInputs.count == 1)
        #expect(config.mode == .imageToImage)
    }

    @Test func controlNetNameIsTheSingleModelInTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MagicEngineTests-\(UUID().uuidString)")
        let net = dir.appending(path: "controlnet")
        try FileManager.default.createDirectory(at: net.appending(path: "Scribble.mlmodelc"), withIntermediateDirectories: true)
        #expect(try MagicEngine.controlNetName(in: dir) == "Scribble")
    }

    @Test func missingControlNetThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MagicEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "controlnet"), withIntermediateDirectories: true)
        #expect(throws: MagicEngine.Failure.self) { try MagicEngine.controlNetName(in: dir) }
    }
}
