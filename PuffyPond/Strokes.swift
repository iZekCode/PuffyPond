import SceneKit
import simd

/// Builds an SCNGeometry from plain Float arrays (works the same on iOS and macOS).
enum MeshBuilder {
    static func geometry(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                         colors: [SIMD4<Float>]? = nil, indices: [UInt32]) -> SCNGeometry {
        let stride3 = MemoryLayout<SIMD3<Float>>.stride
        let positionData = positions.withUnsafeBytes { Data($0) }
        let normalData = normals.withUnsafeBytes { Data($0) }
        var sources = [
            SCNGeometrySource(data: positionData, semantic: .vertex, vectorCount: positions.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: stride3),
            SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: normals.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: stride3),
        ]
        if let colors {
            let colorData = colors.withUnsafeBytes { Data($0) }
            sources.append(SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                             usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
                                             dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride))
        }
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: indices.count / 3, bytesPerIndex: 4)
        return SCNGeometry(sources: sources, elements: [element])
    }
}

struct StrokePoint {
    var p: SIMD2<Float>
    var born: Double
}

/// The path of one brush stroke: what the fish drew, in which color.
/// (What you *see* is the PaintLayer; this is what gets inflated into a creature.)
final class Stroke {
    let node = SCNNode()
    let color: SIMD3<Float>
    let radius: Float
    let surfaceZ: Float
    private(set) var points: [StrokePoint] = []

    init(color: SIMD3<Float>, radius: Float, surfaceZ: Float) {
        self.color = color
        self.radius = radius
        self.surfaceZ = surfaceZ
    }

    var isEmpty: Bool { points.isEmpty }
    var lastPoint: SIMD2<Float>? { points.last?.p }

    func add(_ p: SIMD2<Float>, now: Double) {
        points.append(StrokePoint(p: p, born: now))
    }

    func replacePoints(_ newPoints: [StrokePoint]) {
        points = newPoints
    }

    func update(now: Double) {}
    func pulse(_ amount: Float) {}
}

/// Real-looking paint on the canvas: a height field of wet, glossy paint.
/// - Brush dabs leave flat-topped strokes with ragged edges, paint pushed up along the rims,
///   and bristle grooves running along the stroke.
/// - A still brush pools paint into a growing blob; a fast one goes "dry brush" and streaky.
/// - Wet paint flows a little: it levels, spreads, blends colors, and thick blobs sag into drips,
///   then it dries and keeps its texture.
final class PaintLayer {
    let node = SCNNode()
    var trembling = false

    static let maxHeight: Float = 0.05
    private static let tile = 32

    private let columns: Int       // vertices across
    private let rows: Int          // vertices down
    private let cell: Float
    private let origin: SIMD2<Float>
    private let baseZ: Float
    private var height: [Float]
    private var color: [SIMD3<Float>]
    private var wet: [Float]
    private let tilesX: Int
    private let tilesY: Int
    private var tileNodes: [SCNNode] = []
    private var dirtyTiles = Set<Int>()
    private var wetTiles = Set<Int>()
    private let material: SCNMaterial
    private var dissolve: Float?

    init(center: SIMD2<Float>, size: SIMD2<Float>, z: Float, cellsAcross: Int = 256) {
        cell = size.x / Float(cellsAcross)
        columns = cellsAcross + 1
        rows = Int((size.y / cell).rounded(.down)) + 1
        origin = center - SIMD2(Float(columns - 1), Float(rows - 1)) * cell * 0.5
        baseZ = z
        height = [Float](repeating: 0, count: columns * rows)
        color = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: columns * rows)
        wet = [Float](repeating: 0, count: columns * rows)
        tilesX = (columns - 2) / Self.tile + 1
        tilesY = (rows - 2) / Self.tile + 1

        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = Paint.platform(SIMD3(1, 1, 1))
        m.roughness.contents = NSNumber(value: 0.3)
        m.metalness.contents = NSNumber(value: 0.0)
        m.clearCoat.contents = NSNumber(value: 0.8)          // wet oil-paint sheen
        m.clearCoatRoughness.contents = NSNumber(value: 0.12)
        material = m

        for _ in 0..<(tilesX * tilesY) {
            let n = SCNNode()
            n.castsShadow = false
            node.addChildNode(n)
            tileNodes.append(n)
        }
    }

    // MARK: Noise

    private static func hash(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65_535 * 2 - 1
    }

    /// Smooth value noise in -1…1.
    private static func noise(_ p: SIMD2<Float>) -> Float {
        let i = Int(p.x.rounded(.down)), j = Int(p.y.rounded(.down))
        let f = p - SIMD2(Float(i), Float(j))
        let u = f * f * (3 - 2 * f)
        let a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1)
        return (a + (b - a) * u.x) + ((c + (d - c) * u.x) - (a + (b - a) * u.x)) * u.y
    }

    // MARK: Painting

    private func vertexRange(_ lo: SIMD2<Float>, _ hi: SIMD2<Float>) -> (ClosedRange<Int>, ClosedRange<Int>)? {
        let i0 = max(Int(((lo.x - origin.x) / cell).rounded(.down)), 0)
        let i1 = min(Int(((hi.x - origin.x) / cell).rounded(.up)), columns - 1)
        let j0 = max(Int(((lo.y - origin.y) / cell).rounded(.down)), 0)
        let j1 = min(Int(((hi.y - origin.y) / cell).rounded(.up)), rows - 1)
        guard i0 <= i1, j0 <= j1 else { return nil }
        return (i0...i1, j0...j1)
    }

    /// One brush dab along the segment a → b.
    func stamp(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, color paint: SIMD3<Float>,
               speed: Float, seed: Float) {
        let seg = b - a
        let len = simd_length(seg)
        let dir = len > 1e-5 ? seg / len : SIMD2<Float>(1, 0)
        let across = SIMD2<Float>(-dir.y, dir.x)
        let reach = radius * 1.4
        guard let range = vertexRange(simd_min(a, b) - reach, simd_max(a, b) + reach) else { return }
        let (iRange, jRange) = range

        // Moving lays a full coat; holding still slowly pools paint.
        let moving = smoothStep(0.002, 0.02, len)
        let amount = 0.0015 + (0.016 - 0.0015) * moving
        let dry = smoothStep(1.6, 4.5, speed)          // fast = dry, streaky brush
        let seedOffset = SIMD2<Float>(seed * 3.1, seed * 7.3)

        for j in jRange {
            for i in iRange {
                let p = origin + SIMD2(Float(i), Float(j)) * cell
                let t = len > 1e-5 ? min(max(simd_dot(p - a, seg) / (len * len), 0), 1) : 0
                let dist = simd_distance(p, a + seg * t)
                let ragged = Self.noise(p * 9 + seedOffset) * 0.7 + Self.noise(p * 23 + seedOffset) * 0.3
                let rr = radius * (1 + 0.22 * ragged)
                let x = dist / rr
                guard x < 1.15 else { continue }

                // Flat-ish top, with paint pushed up into a rim at the edges.
                var profile: Float = x < 1 ? sqrt(1 - x * x) : 0
                let rim = (x - 0.9) / 0.13
                profile += 0.35 * exp(-rim * rim)

                // Bristle grooves running along the stroke.
                let u = simd_dot(p, across)
                let bristle = 0.72 + 0.28 * (0.6 * sin(u * 90 + seed) + 0.4 * sin(u * 41 + seed * 1.7))
                let streak = max(0, bristle - dry * 0.5) / (1 - dry * 0.5)
                let deposit = amount * profile * streak
                guard deposit > 1e-6 else { continue }

                let k = j * columns + i
                let old = height[k]
                let add = deposit * max(0, 1 - old / Self.maxHeight)
                // Wet-on-wet: new paint blends into what's there.
                let blend: Float = old < 1e-4 ? 1 : min(1, add / (old * 0.5 + add) + 0.12)
                let tinted = paint * (0.96 + 0.04 * ragged)
                color[k] += (tinted - color[k]) * blend
                height[k] = old + add
                wet[k] = 1
            }
        }
        markRegion(iRange, jRange, wet: true)
    }

    /// Starfish scrubbing: paint gets smeared thin and wiped away.
    func erase(at center: SIMD2<Float>, radius: Float, dt: Float) {
        guard let range = vertexRange(center - radius, center + radius) else { return }
        let (iRange, jRange) = range
        let rate = min(1, dt * 10)
        for j in jRange {
            for i in iRange {
                let p = origin + SIMD2(Float(i), Float(j)) * cell
                let d = simd_distance(p, center)
                guard d < radius else { continue }
                let k = j * columns + i
                guard height[k] > 0 else { continue }
                let f = 1 - smoothStep(radius * 0.55, radius, d)
                height[k] *= 1 - f * rate
                if height[k] < 0.0004 { height[k] = 0 }
                wet[k] = max(wet[k], 0.6 * f)
            }
        }
        markRegion(iRange, jRange, wet: true)
    }

    func clear() {
        for k in height.indices {
            height[k] = 0
            wet[k] = 0
        }
        for n in tileNodes { n.geometry = nil }
        dirtyTiles.removeAll()
        wetTiles.removeAll()
    }

    /// Fade the paint away (it has become a creature).
    func dissolveAway() {
        dissolve = 1
    }

    private func markRegion(_ iRange: ClosedRange<Int>, _ jRange: ClosedRange<Int>, wet isWet: Bool) {
        let tx0 = max((iRange.lowerBound - 1) / Self.tile, 0)
        let tx1 = min((iRange.upperBound + 1) / Self.tile, tilesX - 1)
        let ty0 = max((jRange.lowerBound - 1) / Self.tile, 0)
        let ty1 = min((jRange.upperBound + 1) / Self.tile, tilesY - 1)
        guard tx0 <= tx1, ty0 <= ty1 else { return }
        for ty in ty0...ty1 {
            for tx in tx0...tx1 {
                dirtyTiles.insert(ty * tilesX + tx)
                if isWet { wetTiles.insert(ty * tilesX + tx) }
            }
        }
    }

    // MARK: Per frame

    func update(dt: Float) {
        flow(dt: dt)

        for t in dirtyTiles { rebuild(tile: t) }
        dirtyTiles.removeAll(keepingCapacity: true)

        if let d = dissolve {
            let next = d - dt * 4
            if next <= 0 {
                clear()
                node.opacity = 1
                dissolve = nil
            } else {
                node.opacity = CGFloat(next)
                dissolve = next
            }
        }
        node.simdPosition = trembling
            ? SIMD3(Float.random(in: -0.012...0.012), Float.random(in: -0.01...0.01), 0)
            : .zero
    }

    /// Wet paint levels out, spreads a touch, mixes at the borders and sags into drips; then dries.
    private func flow(dt: Float) {
        guard !wetTiles.isEmpty else { return }
        let dryFactor = exp(-dt / 0.9)
        var stillWet = Set<Int>()
        for t in wetTiles {
            let tx = t % tilesX, ty = t / tilesX
            let i0 = tx * Self.tile, i1 = min(i0 + Self.tile, columns - 2)
            let j0 = max(ty * Self.tile, 1), j1 = min(ty * Self.tile + Self.tile, rows - 2)
            guard i0 <= i1, j0 <= j1 else { continue }
            var anyWet = false
            for j in j0...j1 {
                for i in i0...i1 {
                    let k = j * columns + i
                    let w = wet[k]
                    guard w > 0.02 else { continue }
                    anyWet = true
                    // Level with the right and upper neighbours (and pull them along with us).
                    for side in 0..<2 {
                        let n = side == 0 ? k + 1 : k + columns
                        let wmax = max(w, wet[n])
                        let flux = (height[k] - height[n]) * 0.05 * wmax
                        if flux > 0 && height[n] < 1e-4 { color[n] = color[k] }
                        if flux < 0 && height[k] < 1e-4 { color[k] = color[n] }
                        height[k] -= flux
                        height[n] += flux
                        if wet[n] < w * 0.5 { wet[n] = w * 0.5 }
                    }
                    // Thick wet paint creeps downward into little drips.
                    let below = k - columns
                    let excess = height[k] - 0.03
                    if excess > 0 && w > 0.3 {
                        let move = excess * 0.04 * w
                        height[k] -= move
                        if height[below] < 1e-4 { color[below] = color[k] }
                        height[below] += move
                        wet[below] = max(wet[below], w * 0.9)
                    }
                    wet[k] = w * dryFactor
                }
            }
            if anyWet {
                stillWet.insert(t)
                markRegion(i0...i1, j0...j1, wet: false)
            }
        }
        wetTiles = stillWet
    }

    private func rebuild(tile t: Int) {
        let tx = t % tilesX, ty = t / tilesX
        let i0 = tx * Self.tile, i1 = min(i0 + Self.tile, columns - 1)
        let j0 = ty * Self.tile, j1 = min(j0 + Self.tile, rows - 1)
        guard i0 < i1, j0 < j1 else { return }
        let localW = i1 - i0 + 1

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(localW * (j1 - j0 + 1))

        for j in j0...j1 {
            for i in i0...i1 {
                let k = j * columns + i
                let hL = height[j * columns + max(i - 1, 0)]
                let hR = height[j * columns + min(i + 1, columns - 1)]
                let hD = height[max(j - 1, 0) * columns + i]
                let hU = height[min(j + 1, rows - 1) * columns + i]
                let n = simd_normalize(SIMD3<Float>((hL - hR) / (2 * cell), (hD - hU) / (2 * cell), 1))
                let p = origin + SIMD2(Float(i), Float(j)) * cell
                positions.append(SIMD3(p.x, p.y, baseZ + height[k]))
                normals.append(n)
                let c = color[k]
                colors.append(SIMD4(c.x, c.y, c.z, 1))
            }
        }
        for j in j0..<j1 {
            for i in i0..<i1 {
                let k = j * columns + i
                guard height[k] > 1e-4 || height[k + 1] > 1e-4
                        || height[k + columns] > 1e-4 || height[k + columns + 1] > 1e-4 else { continue }
                let a = UInt32((j - j0) * localW + (i - i0))
                let b = a + 1
                let d = a + UInt32(localW)
                let c = d + 1
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }
        let tileNode = tileNodes[t]
        guard !indices.isEmpty else {
            tileNode.geometry = nil
            return
        }
        let geometry = MeshBuilder.geometry(positions: positions, normals: normals, colors: colors, indices: indices)
        geometry.materials = [material]
        tileNode.geometry = geometry
    }
}
