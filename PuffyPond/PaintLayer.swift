import SceneKit
import Metal
import simd

/// Mirrors `PaintStamp` in PaintShaders.metal.
private struct PaintStamp {
    var segment: SIMD4<Float>   // a.xy, b.xy (world)
    var color: SIMD4<Float>     // rgb, kind (0 = paint, 1 = erase)
    var brush: SIMD4<Float>     // radius, amount, dryness, seed
    var motion: SIMD4<Float>    // brush velocity (texels/s) xy, erase rate, push
    var shape: SIMD4<Float>     // nib angle, nib aspect, bristles, watery
    var extra: SIMD4<Float>     // palette knife, unused…
}

/// How one dab behaves: every brush animal paints with its own style.
struct BrushStyle {
    var amount: Float?          // paint laid per dab; nil = from motion (moving coats, holding still pools)
    var push: Float = 0.55      // how hard it drags the wet paint it passes through
    var bristles: Float = 1     // 0 = smooth blob, 1 = full bristle grooves
    var nibAngle: Float = 0     // flat-nib edge direction (radians, world)
    var nibAspect: Float = 1    // 1 = round brush, > 1 = flat nib: thick across the edge, thin along it
    var watery: Float = 0       // 0 = oil paint, 1 = runny watercolor wash that blooms outward
    var knife: Float = 0        // 1 = palette knife: a flat sheet with paint ridged up at its edges

    static let brush = BrushStyle()
}

/// Mirrors `PaintParams` in PaintShaders.metal.
private struct PaintParams {
    var frame: SIMD4<Float>     // left, top, world units per texel, dt
    var size: SIMD4<Float>      // width, height, stamp count, clear
    var tune: SIMD4<Float>      // dry rate, leveling, velocity damping, gravity
    var shade: SIMD4<Float>     // normal strength, cavity darkening, bristle relief, paint body
    var canvas: SIMD4<Float>    // weave thread pitch (texels), weave depth under thin paint
}

/// Real-looking wet paint on the canvas, simulated on the GPU with Metal.
/// - Every pixel holds pigment color, thickness, flow velocity and wetness.
/// - Brush dabs lay flat strokes with ragged edges, rims and bristle grooves, and drag the wet paint
///   they pass through, so strokes smear, swirl and blend like real fluid paint.
/// - Wet paint levels out, mixes colors, thick blobs sag into drips, then it dries and keeps its texture.
/// - It is drawn as one flat plane with a per-pixel normal map, so the light rakes across every ridge.
final class PaintLayer {
    let node = SCNNode()

    // Tuning
    private static let dryRate: Float = 0.9           // 1/s: how fast wet paint sets
    private static let leveling: Float = 2            // how quickly wet paint relaxes
    private static let damping: Float = 5             // 1/s: how fast smears stop moving
    private static let gravity: Float = 260           // texels/s² pull on thick wet paint
    private static let normalStrength: Float = 42
    private static let cavity: Float = 6
    private static let reliefHeight: Float = 0.12     // bristle texture depth
    private static let bodyHeight: Float = 0.35       // how much the paint's thickness itself shows
    private static let weaveDepth: Float = 0.012      // canvas weave showing through thin paint
    private static let maxStamps = 256

    private let width: Int
    private let height: Int
    private let worldPerTexel: Float
    private let topLeft: SIMD2<Float>
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let stepPipeline: MTLComputePipelineState?
    private let shadePipeline: MTLComputePipelineState?
    private var paint: [MTLTexture] = []
    private var flow: [MTLTexture] = []
    private var current = 0
    private var albedo: MTLTexture?
    private var normalMap: MTLTexture?
    private var roughness: MTLTexture?
    private var stamps: [PaintStamp] = []
    private var needsClear = true
    private var settleTime: Float = 0                 // keep simulating while paint may still move
    private let surface: SCNNode

    init(center: SIMD2<Float>, size: SIMD2<Float>, z: Float, pixelsAcross: Int = PaintLayer.defaultResolution) {
        width = pixelsAcross
        height = Int((Float(pixelsAcross) * size.y / size.x).rounded())
        worldPerTexel = size.x / Float(width)
        topLeft = SIMD2(center.x - size.x * 0.5, center.y + size.y * 0.5)

        let plane = SCNPlane(width: CGFloat(size.x), height: CGFloat(size.y))
        surface = SCNNode(geometry: plane)
        surface.simdPosition = SIMD3(center.x, center.y, z)
        surface.castsShadow = false
        node.addChildNode(surface)

        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        let library = device?.makeDefaultLibrary()
        stepPipeline = library?.makeFunction(name: "paintStep").flatMap { try? device?.makeComputePipelineState(function: $0) }
        shadePipeline = library?.makeFunction(name: "paintShade").flatMap { try? device?.makeComputePipelineState(function: $0) }
        guard let device, stepPipeline != nil, shadePipeline != nil else {
            surface.isHidden = true
            return
        }

        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        paint = (0..<2).compactMap { _ in texture(.rgba16Float) }
        flow = (0..<2).compactMap { _ in texture(.rgba16Float) }
        albedo = texture(.rgba8Unorm)
        normalMap = texture(.rgba8Unorm)
        roughness = texture(.rgba8Unorm)

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = albedo
        m.normal.contents = normalMap
        m.roughness.contents = roughness
        m.metalness.contents = NSNumber(value: 0.0)
        m.clearCoat.contents = NSNumber(value: 0.55)        // oil-paint sheen
        m.clearCoatRoughness.contents = NSNumber(value: 0.15)
        m.transparencyMode = .aOne
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        plane.materials = [m]
    }

    static var defaultResolution: Int {
        #if os(macOS)
        return 2048
        #else
        return 1536
        #endif
    }

    // MARK: Painting

    /// One brush dab along the segment a → b (applied on the next `update`).
    func stamp(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, color paint: SIMD3<Float>,
               speed: Float, seed: Float, style: BrushStyle = .brush) {
        guard stamps.count < Self.maxStamps else { return }
        let len = simd_distance(a, b)
        // Moving lays a full coat; holding still slowly pools paint.
        let moving = smoothStep(0.002, 0.02, len)
        let amount = style.amount ?? 0.03 + (0.3 - 0.03) * moving
        let dry = smoothStep(1.6, 4.5, speed) * style.bristles   // fast = dry, streaky brush
        let drag = texelVelocity(b - a)
        stamps.append(PaintStamp(segment: SIMD4(a.x, a.y, b.x, b.y),
                                 color: SIMD4(paint.x, paint.y, paint.z, 0),
                                 brush: SIMD4(radius, amount, dry, seed),
                                 motion: SIMD4(drag.x, drag.y, 0, style.push),
                                 shape: SIMD4(style.nibAngle, style.nibAspect, style.bristles, style.watery),
                                 extra: SIMD4(style.knife, 0, 0, 0)))
        settleTime = max(settleTime, 5 + style.watery * 3)
    }

    /// Starfish scrubbing: paint gets smeared thin and wiped away.
    func erase(at center: SIMD2<Float>, radius: Float, dt: Float) {
        guard stamps.count < Self.maxStamps else { return }
        stamps.append(PaintStamp(segment: SIMD4(center.x, center.y, center.x, center.y),
                                 color: SIMD4(0, 0, 0, 1),
                                 brush: SIMD4(radius, 0, 0, 0),
                                 motion: SIMD4(0, 0, min(1, dt * 10), 0),
                                 shape: SIMD4(0, 1, 0, 0), extra: .zero))
        settleTime = max(settleTime, 5)
    }

    func clear() {
        needsClear = true
        stamps.removeAll()
    }

    /// Per-frame world displacement → texels/s for the brush drag (texture y runs downward).
    private var lastDT: Float = 1.0 / 60
    private func texelVelocity(_ d: SIMD2<Float>) -> SIMD2<Float> {
        var v = SIMD2(d.x, -d.y) / worldPerTexel / max(lastDT, 1.0 / 240)
        let speed = simd_length(v)
        if speed > 900 { v *= 900 / speed }
        return v
    }

    // MARK: Per frame

    func update(dt: Float) {
        lastDT = dt
        simulate(dt: dt)
    }

    private func simulate(dt: Float) {
        guard needsClear || !stamps.isEmpty || settleTime > 0 else { return }
        settleTime -= dt
        guard let commandQueue, let stepPipeline, let shadePipeline, paint.count == 2, flow.count == 2,
              let albedo, let normalMap, let roughness,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else { return }

        var params = PaintParams(
            frame: SIMD4(topLeft.x, topLeft.y, worldPerTexel, dt),
            size: SIMD4(Float(width), Float(height), Float(stamps.count), needsClear ? 1 : 0),
            tune: SIMD4(Self.dryRate, Self.leveling, Self.damping, Self.gravity),
            shade: SIMD4(Self.normalStrength, Self.cavity, Self.reliefHeight, Self.bodyHeight),
            canvas: SIMD4(Studio.weaveTileSize / Float(Studio.threadsPerTile) / worldPerTexel, Self.weaveDepth, 0, 0))
        // A non-empty buffer even with no stamps, so the binding is always valid.
        let stampData = stamps.isEmpty
            ? [PaintStamp(segment: .zero, color: .zero, brush: .zero, motion: .zero, shape: .zero, extra: .zero)]
            : stamps
        guard let stampBuffer = stampData.withUnsafeBytes({ device?.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        else { encoder.endEncoding(); return }

        let groupSize = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        let next = 1 - current

        encoder.setComputePipelineState(stepPipeline)
        encoder.setTexture(paint[current], index: 0)
        encoder.setTexture(flow[current], index: 1)
        encoder.setTexture(paint[next], index: 2)
        encoder.setTexture(flow[next], index: 3)
        encoder.setBytes(&params, length: MemoryLayout<PaintParams>.stride, index: 0)
        encoder.setBuffer(stampBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)

        encoder.setComputePipelineState(shadePipeline)
        encoder.setTexture(paint[next], index: 0)
        encoder.setTexture(flow[next], index: 1)
        encoder.setTexture(albedo, index: 2)
        encoder.setTexture(normalMap, index: 3)
        encoder.setTexture(roughness, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<PaintParams>.stride, index: 0)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)

        encoder.endEncoding()
        buffer.commit()
        current = next
        stamps.removeAll(keepingCapacity: true)
        needsClear = false
    }
}
