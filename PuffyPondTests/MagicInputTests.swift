import Testing
import CoreGraphics
@testable import PuffyPond

struct MagicInputTests {
    @Test func fishWithWatercolor() {
        let p = MagicPrompt.make(template: .fish, brushes: [.jellyfish, .jellyfish])
        #expect(p.positive == "a cute colorful fish, soft watercolor, children's book illustration, bright, whimsical, high quality")
    }

    @Test func noTemplateTwoBrushes() {
        #expect(MagicPrompt.make(template: nil, brushes: [.octopus, .frog]).positive
            == "a magical underwater pond scene, bold gouache brushwork, dotted pointillism, children's book illustration, bright, whimsical, high quality")
    }

    @Test func negativePromptIsFixed() {
        #expect(MagicPrompt.make(template: .duck, brushes: []).negative
            == "scary, dark, violent, blood, text, watermark, ugly, blurry, realistic photo")
    }

    @Test func blankCanvasHasNoScribble() {
        let blank = solidImage(gray: 0.9, 640, 384)
        #expect(ScribbleMap.make(painted: blank, blank: blank) == nil)
    }

    @Test func redLineBecomesWhiteScribble() throws {
        let blank = solidImage(gray: 0.9, 640, 384)
        let withLine = solidImage(gray: 0.9, 640, 384, redLineAtY: 192)
        let inputs = try #require(ScribbleMap.make(painted: withLine, blank: blank))
        #expect(pixel(inputs.scribble, 320, 192) == 255)   // line → white
        #expect(pixel(inputs.scribble, 320, 50) == 0)      // empty canvas → black
        #expect(inputs.start.width == 640 && inputs.start.height == 384)
        #expect(inputs.fingerprint.count == 16 * 10)
    }

    @Test func differenceOfIdenticalIsZero() {
        let f = [UInt8](repeating: 100, count: 160)
        #expect(ScribbleMap.difference(f, f) == 0)
    }

    @Test func differenceOfBlackAndWhiteIsOne() {
        let black = [UInt8](repeating: 0, count: 160)
        let white = [UInt8](repeating: 255, count: 160)
        #expect(ScribbleMap.difference(black, white) == 1)
    }
}
