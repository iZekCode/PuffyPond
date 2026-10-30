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

/// A puffy balloon tube laid down by a fish. Each bead of it inflates with a springy overshoot.
final class Stroke {
    let node = SCNNode()
    let color: SIMD3<Float>
    let radius: Float
    let surfaceZ: Float
    private(set) var points: [StrokePoint] = []
    private let material: SCNMaterial
    private var needsRebuild = true
    private var lastGrowth: Double = 0

    static let inflateTime: Double = 0.45
    static let segments = 14

    init(color: SIMD3<Float>, radius: Float, surfaceZ: Float) {
        self.color = color
        self.radius = radius
        self.surfaceZ = surfaceZ
        material = Toybox.balloon(color, wobble: 0.006, speed: 4)
        node.castsShadow = true
    }

    var isEmpty: Bool { points.isEmpty }
    var lastPoint: SIMD2<Float>? { points.last?.p }

    func add(_ p: SIMD2<Float>, now: Double) {
        points.append(StrokePoint(p: p, born: now))
        lastGrowth = now
        needsRebuild = true
    }

    func replacePoints(_ newPoints: [StrokePoint]) {
        points = newPoints
        needsRebuild = true
    }

    /// Wobble harder on the beat.
    func pulse(_ amount: Float) {
        Toybox.setWobble(material, 0.006 + amount * 0.01)
    }

    private static func inflate(_ t: Double) -> Float {
        let x = Float(min(max(t / inflateTime, 0), 1))
        // easeOutBack: puffs past full size, then settles.
        let c1: Float = 2.2
        let c3 = c1 + 1
        let u = x - 1
        return 0.2 + 0.8 * (1 + c3 * u * u * u + c1 * u * u)
    }

    /// Rebuilds the mesh while any bead is still inflating (or after edits).
    func update(now: Double) {
        let inflating = now - lastGrowth < Self.inflateTime + 0.05
        guard needsRebuild || inflating else { return }
        needsRebuild = false
        guard !points.isEmpty else {
            node.geometry = nil
            return
        }
        let radii = points.map { radius * Self.inflate(now - $0.born) }
        let geometry = Self.tube(points.map(\.p), radii: radii, z: surfaceZ)
        geometry.materials = [material]
        node.geometry = geometry
    }

    /// Swept circle along the polyline with hemispherical caps.
    static func tube(_ path: [SIMD2<Float>], radii: [Float], z: Float) -> SCNGeometry {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let segs = segments
        let n = path.count

        func tangent(_ i: Int) -> SIMD2<Float> {
            let a = path[max(i - 1, 0)]
            let b = path[min(i + 1, n - 1)]
            let d = b - a
            let l = simd_length(d)
            return l > 1e-5 ? d / l : SIMD2(1, 0)
        }

        func addRing(center: SIMD2<Float>, along t: SIMD2<Float>, radius r: Float, phi: Float, sign: Float) {
            let side = SIMD2<Float>(-t.y, t.x)
            let c = cos(phi), s = sin(phi)
            let center3 = SIMD3<Float>(center.x, center.y, z)
            for k in 0...segs {
                let theta = Float(k) / Float(segs) * 2 * Float.pi
                let radial = SIMD3<Float>(side.x * cos(theta), side.y * cos(theta), sin(theta))
                let dir = radial * c + SIMD3<Float>(t.x, t.y, 0) * (s * sign)
                positions.append(center3 + dir * r)
                normals.append(dir)
            }
        }

        let capRings = 5
        var rings = 0
        // Start cap (pole → equator), body rings, end cap (equator → pole).
        let t0 = tangent(0)
        for j in stride(from: capRings, through: 1, by: -1) {
            let phi = Float(j) / Float(capRings) * Float.pi / 2
            addRing(center: path[0], along: t0, radius: radii[0], phi: phi, sign: -1)
            rings += 1
        }
        for i in 0..<n {
            addRing(center: path[i], along: tangent(i), radius: radii[i], phi: 0, sign: 1)
            rings += 1
        }
        let t1 = tangent(n - 1)
        for j in 1...capRings {
            let phi = Float(j) / Float(capRings) * Float.pi / 2
            addRing(center: path[n - 1], along: t1, radius: radii[n - 1], phi: phi, sign: 1)
            rings += 1
        }

        let ringSize = segs + 1
        for r in 0..<(rings - 1) {
            for k in 0..<segs {
                let a = UInt32(r * ringSize + k)
                let b = UInt32(r * ringSize + k + 1)
                let c = UInt32((r + 1) * ringSize + k)
                let d = UInt32((r + 1) * ringSize + k + 1)
                indices.append(contentsOf: [a, b, c, b, d, c])  // counter-clockwise from outside
            }
        }
        return MeshBuilder.geometry(positions: positions, normals: normals, indices: indices)
    }
}
