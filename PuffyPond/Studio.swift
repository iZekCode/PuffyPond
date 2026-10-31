import SceneKit
import CoreGraphics
import simd

/// A real-looking painter's studio around the canvas: an out-of-focus room lit by a window,
/// primed linen with a woven surface, and a wooden easel with grain. All textures are generated.
enum Studio {
    // MARK: Noise

    private static func hash(_ x: Int, _ y: Int, _ seed: Int = 0) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 982_451_653)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65_535
    }

    /// Smooth value noise in 0…1 that tiles every `period` cells.
    private static func noise(_ x: Float, _ y: Float, period: Int = 1 << 20, seed: Int = 0) -> Float {
        let i = Int(x.rounded(.down)), j = Int(y.rounded(.down))
        let fx = x - Float(i), fy = y - Float(j)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        func h(_ a: Int, _ b: Int) -> Float {
            hash(((a % period) + period) % period, ((b % period) + period) % period, seed)
        }
        let a = h(i, j), b = h(i + 1, j), c = h(i, j + 1), d = h(i + 1, j + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    /// An RGBA bitmap filled pixel by pixel (values 0…1).
    private static func bitmap(width: Int, height: Int, _ pixel: (Int, Int) -> SIMD4<Float>) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = simd_clamp(pixel(x, y), SIMD4(repeating: 0), SIMD4(repeating: 1)) * 255
                let k = (y * width + x) * 4
                bytes[k] = UInt8(c.x)
                bytes[k + 1] = UInt8(c.y)
                bytes[k + 2] = UInt8(c.z)
                bytes[k + 3] = UInt8(c.w)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A tangent-space normal map from a tiling height function.
    private static func normalMap(size: Int, strength: Float, height: (Int, Int) -> Float) -> CGImage? {
        var h = [Float](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size { h[y * size + x] = height(x, y) } }
        func at(_ x: Int, _ y: Int) -> Float { h[((y + size) % size) * size + (x + size) % size] }
        return bitmap(width: size, height: size) { x, y in
            let n = simd_normalize(SIMD3((at(x - 1, y) - at(x + 1, y)) * strength,
                                         (at(x, y + 1) - at(x, y - 1)) * strength, 1))
            return SIMD4(n * 0.5 + 0.5, 1)
        }
    }

    // MARK: Primed linen

    static let weaveTile = 512
    static let threadsPerTile = 32
    /// World size of one weave tile (the paint shader draws the same weave under thin paint).
    static let weaveTileSize: Float = 0.4

    /// Height of the woven threads (0…1): warp and weft passing over and under each other.
    private static func weave(_ x: Int, _ y: Int) -> Float {
        let p = weaveTile / threadsPerTile
        let i = x / p, j = y / p
        let u = Float(x % p) / Float(p), v = Float(y % p) / Float(p)
        // Threads wobble a little in thickness, like real linen.
        let slub = 0.85 + 0.3 * noise(Float(x) / 9, Float(j) * 3.1, period: weaveTile / 9 + 1, seed: 3)
        let warp = sin(.pi * u) * slub
        let weft = sin(.pi * v) * (0.85 + 0.3 * noise(Float(i) * 3.1, Float(y) / 9, seed: 5))
        let fiber = 0.08 * noise(Float(x) * 0.7, Float(y) * 0.7, period: weaveTile * 7 / 10, seed: 9)
        let warpOnTop = (i + j) % 2 == 0
        let top = warpOnTop ? warp * (0.75 + 0.25 * sin(.pi * v)) : weft * (0.75 + 0.25 * sin(.pi * u))
        let under = (warpOnTop ? weft : warp) * 0.55
        return max(top, under) + fiber
    }

    /// Primed linen: warm off-white with the weave catching the light.
    static func canvasMaterial(repeats: SIMD2<Float>) -> SCNMaterial {
        let size = weaveTile
        let albedo = bitmap(width: size, height: size) { x, y in
            let h = weave(x, y)
            let tone = 0.9 + 0.07 * h + 0.03 * noise(Float(x) / 40, Float(y) / 40, period: size / 40 + 1, seed: 11)
            return SIMD4(SIMD3<Float>(0.84, 0.83, 0.8) * tone, 1)
        }
        let normals = normalMap(size: size, strength: 2.4, height: weave)
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = Toybox.platformImage(albedo)
        m.normal.contents = Toybox.platformImage(normals)
        m.roughness.contents = NSNumber(value: 0.92)
        m.metalness.contents = NSNumber(value: 0.0)
        for p in [m.diffuse, m.normal] {
            p.wrapS = .repeat
            p.wrapT = .repeat
            p.contentsTransform = SCNMatrix4(simd_float4x4(diagonal: SIMD4(repeats.x, repeats.y, 1, 1)))
            p.mipFilter = .linear
        }
        return m
    }

    // MARK: Wood

    /// Oak-like wood with long, slightly wavy grain running along the beam.
    static func woodMaterial(grainAlongV: Bool) -> SCNMaterial {
        let size = 256
        func grain(_ x: Int, _ y: Int) -> Float {
            let warp = noise(Float(x) / 22, Float(y) / 60, period: 256, seed: 21) * 9
            let rings = sin((Float(x) + warp) * 0.42) * 0.5 + 0.5
            let fine = noise(Float(x) * 0.9, Float(y) / 18, period: 256, seed: 23)
            return rings * 0.7 + fine * 0.3
        }
        let albedo = bitmap(width: size, height: size) { x, y in
            let g = grainAlongV ? grain(x, y) : grain(y, x)
            let light = SIMD3<Float>(0.62, 0.46, 0.31), dark = SIMD3<Float>(0.38, 0.25, 0.15)
            return SIMD4(dark + (light - dark) * g * g, 1)
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = Toybox.platformImage(albedo)
        m.normal.contents = Toybox.platformImage(normalMap(size: size, strength: 0.8) { x, y in
            grainAlongV ? grain(x, y) : grain(y, x)
        })
        m.roughness.contents = NSNumber(value: 0.55)
        m.metalness.contents = NSNumber(value: 0.0)
        m.clearCoat.contents = NSNumber(value: 0.25)        // a thin coat of varnish
        m.clearCoatRoughness.contents = NSNumber(value: 0.35)
        for p in [m.diffuse, m.normal] {
            p.wrapS = .repeat
            p.wrapT = .repeat
            p.contentsTransform = grainAlongV ? SCNMatrix4MakeScale(1, 4, 1) : SCNMatrix4MakeScale(4, 1, 1)
        }
        return m
    }

    // MARK: The room

    private static func softBlob(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, color: SIMD4<Float>,
                                 scaleY: CGFloat = 1) {
        let space = CGColorSpaceCreateDeviceRGB()
        let inner = CGColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: CGFloat(color.w))
        guard let g = CGGradient(colorsSpace: space, colors: [inner, inner.copy(alpha: 0) ?? inner] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1, y: scaleY)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    /// The room behind the easel, as if shot with a shallow depth of field: a warm wall with soft window
    /// light from the left, a wooden floor and a leafy plant on the right — everything out of focus.
    static func backdrop() -> PlatformImage? {
        let w = 1600, h = 1000
        return Toybox.platformImage(Toybox.image(width: w, height: h) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            // Wall: brighter near the window, a touch darker toward the right corner.
            let wall = [CGColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1),
                        CGColor(red: 0.86, green: 0.83, blue: 0.78, alpha: 1),
                        CGColor(red: 0.78, green: 0.75, blue: 0.70, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: wall, locations: [0, 0.6, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: CGFloat(w), y: 0), options: [])
            }
            // Window light pooled on the wall (left), built from stacked soft glows.
            softBlob(ctx, at: CGPoint(x: 260, y: 640), radius: 520, color: SIMD4(1, 0.98, 0.93, 0.75), scaleY: 1.1)
            softBlob(ctx, at: CGPoint(x: 220, y: 700), radius: 260, color: SIMD4(1, 1, 0.97, 0.9), scaleY: 1.5)
            // Faint window-frame shadows in the light.
            ctx.setFillColor(CGColor(red: 0.6, green: 0.58, blue: 0.55, alpha: 0.06))
            ctx.fill(CGRect(x: 215, y: 380, width: 34, height: 560))
            ctx.fill(CGRect(x: 40, y: 640, width: 420, height: 30))
            // Wooden floor along the bottom, blurred.
            let floor = [CGColor(red: 0.55, green: 0.42, blue: 0.31, alpha: 0),
                         CGColor(red: 0.55, green: 0.42, blue: 0.31, alpha: 0.85),
                         CGColor(red: 0.45, green: 0.33, blue: 0.24, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: floor, locations: [0, 0.35, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 260), end: CGPoint(x: 0, y: 0), options: [])
            }
            // A potted plant at the right, deep out of focus.
            softBlob(ctx, at: CGPoint(x: 1390, y: 170), radius: 120, color: SIMD4(0.72, 0.42, 0.3, 0.9), scaleY: 0.9)
            let leaves: [(CGFloat, CGFloat, CGFloat, Float)] = [
                (1330, 430, 150, 0.34), (1450, 520, 170, 0.28), (1520, 380, 140, 0.38), (1380, 620, 130, 0.42),
                (1260, 560, 110, 0.36), (1560, 640, 150, 0.3), (1460, 300, 120, 0.4), (1300, 300, 100, 0.33),
            ]
            for (x, y, r, g) in leaves {
                softBlob(ctx, at: CGPoint(x: x, y: y), radius: r, color: SIMD4(0.22, g + 0.18, 0.2, 0.75), scaleY: 1.25)
            }
            softBlob(ctx, at: CGPoint(x: 1420, y: 520), radius: 90, color: SIMD4(0.55, 0.75, 0.45, 0.5))
            // Gentle corner shading (lens vignette in the photo).
            softBlob(ctx, at: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2), radius: 900,
                     color: SIMD4(1, 1, 1, 0.12), scaleY: 0.7)
        })
    }

    /// Light coming into the room: a bright window on one side, warm walls, a darker wooden floor.
    static func environment() -> PlatformImage? {
        Toybox.platformImage(Toybox.image(width: 512, height: 256) { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let colors = [CGColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1),
                          CGColor(red: 0.85, green: 0.81, blue: 0.75, alpha: 1),
                          CGColor(red: 0.42, green: 0.32, blue: 0.24, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 256), end: CGPoint(x: 0, y: 0), options: [])
            }
            softBlob(ctx, at: CGPoint(x: 150, y: 165), radius: 70, color: SIMD4(1, 1, 0.97, 1), scaleY: 1.3)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.98, alpha: 1))
            ctx.fill(CGRect(x: 120, y: 130, width: 60, height: 70))
        })
    }
}
