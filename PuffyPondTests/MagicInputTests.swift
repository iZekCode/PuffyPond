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

// MARK: - Helpers

private func solidImage(gray: CGFloat, _ w: Int, _ h: Int, redLineAtY: Int? = nil) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if let y = redLineAtY {
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 40, y: y - 4, width: w - 80, height: 8))
    }
    return ctx.makeImage()!
}

/// Gray value (0…255) of one pixel, top-left origin.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
    var value: UInt8 = 0
    let ctx = CGContext(data: &value, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return value
}
