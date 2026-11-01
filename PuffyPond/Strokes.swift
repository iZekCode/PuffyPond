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

/// The path of one brush stroke: what the fish drew, in which color, with which brush animal.
/// (What you *see* is the PaintLayer; this tracks what's been drawn so far, for erasing.)
final class Stroke {
    let node = SCNNode()
    let color: SIMD3<Float>
    let radius: Float
    let surfaceZ: Float
    let brush: CritterKind
    private(set) var points: [StrokePoint] = []

    init(color: SIMD3<Float>, radius: Float, surfaceZ: Float, brush: CritterKind) {
        self.color = color
        self.radius = radius
        self.surfaceZ = surfaceZ
        self.brush = brush
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
