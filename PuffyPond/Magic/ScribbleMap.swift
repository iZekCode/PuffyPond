import CoreGraphics
import Foundation

/// What the diffusion model sees: the painted canvas (img2img start) and a white-on-black map of
/// where paint is (ControlNet scribble). `fingerprint` is a tiny thumbnail of that map, used to tell
/// whether the canvas really changed.
nonisolated struct MagicInputs {
    let start: CGImage
    let scribble: CGImage
    let fingerprint: [UInt8]
}

nonisolated enum ScribbleMap {
    static let fingerprintSize = (width: 16, height: 10)
    /// Per-channel difference (0…1) between the painted and the blank canvas that counts as paint.
    static let threshold: Float = 0.12

    /// Nil when no pixel of `painted` differs from `blank`. The weave and lighting are identical in
    /// both photos, so they cancel out and only paint is left.
    static func make(painted: CGImage, blank: CGImage,
                     size: CGSize = CGSize(width: 640, height: 384)) -> MagicInputs? {
        let w = Int(size.width), h = Int(size.height)
        guard let paintedPixels = rgba(painted, w, h), let blankPixels = rgba(blank, w, h) else { return nil }

        let limit = Int(threshold * 255)
        var mask = [UInt8](repeating: 0, count: w * h)
        var any = false
        for i in 0..<(w * h) {
            var delta = 0
            for c in 0..<3 {
                delta = max(delta, abs(Int(paintedPixels[i * 4 + c]) - Int(blankPixels[i * 4 + c])))
            }
            if delta > limit {
                mask[i] = 255
                any = true
            }
        }
        guard any else { return nil }

        let dilated = dilate(mask, w, h)
        guard let scribble = grayImage(dilated, w, h),
              let start = image(from: paintedPixels, w, h) else { return nil }
        return MagicInputs(start: start, scribble: scribble, fingerprint: thumbnail(dilated, w, h))
    }

    /// Mean absolute difference of two fingerprints, from 0 (same) to 1 (black vs white).
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Float(total) / Float(a.count * 255)
    }

    // MARK: Pixels

    private static func rgba(_ source: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func image(from pixels: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private static func grayImage(_ pixels: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    /// Grows white areas by one pixel in every direction.
    private static func dilate(_ mask: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        var out = mask
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] == 255 {
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) { out[ny * w + nx] = 255 }
                }
            }
        }
        return out
    }

    /// Box-averaged `fingerprintSize` thumbnail.
    private static func thumbnail(_ mask: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let (tw, th) = fingerprintSize
        var out = [UInt8](repeating: 0, count: tw * th)
        for ty in 0..<th {
            for tx in 0..<tw {
                let x0 = tx * w / tw, x1 = (tx + 1) * w / tw
                let y0 = ty * h / th, y1 = (ty + 1) * h / th
                var sum = 0
                for y in y0..<y1 { for x in x0..<x1 { sum += Int(mask[y * w + x]) } }
                out[ty * tw + tx] = UInt8(sum / ((x1 - x0) * (y1 - y0)))
            }
        }
        return out
    }
}
