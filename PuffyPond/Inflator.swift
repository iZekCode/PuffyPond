import Foundation
import simd

nonisolated struct InflateStroke: Sendable {
    var points: [SIMD2<Float>]
    var radius: Float
    var color: SIMD3<Float>
}

/// A drawing blown up into a closed balloon mesh, plus where its face goes.
nonisolated struct CreatureMesh: Sendable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var colors: [SIMD4<Float>]
    var indices: [UInt32]
    var center: SIMD2<Float>          // world position of the drawing's center
    var halfExtents: SIMD3<Float>
    var eyeCenters: [SIMD3<Float>]    // local to the mesh
    var eyeRadius: Float
    var mouth: SIMD3<Float>
    var mainColor: SIMD3<Float>
    var palette: [SIMD3<Float>]       // the distinct colors it was drawn with
}

/// Turns 2D strokes into a puffy 3D balloon:
/// 1. stamp the strokes into a grid (closed shapes get filled in),
/// 2. solve a Poisson equation ∇²u = −1 inside the shape,
/// 3. height = √(2u) — round cross-sections everywhere: blobs become balls, lines become sausages.
nonisolated enum Inflator {
    static let cellsAcross: Float = 64
    static let puff: Float = 1.25

    static func distinctColors(_ colors: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for c in colors where !result.contains(where: { simd_distance($0, c) < 0.05 }) {
            result.append(c)
        }
        return result
    }

    static func inflate(_ strokes: [InflateStroke]) -> CreatureMesh? {
        let all = strokes.flatMap { s in s.points.map { ($0, s.radius) } }
        guard !all.isEmpty else { return nil }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for (p, r) in all {
            lo = simd_min(lo, p - r * 1.2)
            hi = simd_max(hi, p + r * 1.2)
        }
        let size = hi - lo
        let longest = max(size.x, size.y)
        guard longest > 0.1 else { return nil }

        let cell = longest / cellsAcross
        let pad = 3
        let gw = Int((size.x / cell).rounded(.up)) + pad * 2
        let gh = Int((size.y / cell).rounded(.up)) + pad * 2
        let origin = lo - SIMD2(Float(pad), Float(pad)) * cell
        let center = (lo + hi) * 0.5
        let cellCount = gw * gh

        var mask = [UInt8](repeating: 0, count: cellCount)
        var colors = [SIMD3<Float>](repeating: .zero, count: cellCount)

        // 1. Stamp every stroke (later strokes paint over earlier ones).
        func stamp(_ p: SIMD2<Float>, _ r: Float, _ color: SIMD3<Float>) {
            let c = (p - origin) / cell
            let rr = r / cell
            let i0 = max(Int(c.x - rr - 1), 0), i1 = min(Int(c.x + rr + 1), gw - 1)
            let j0 = max(Int(c.y - rr - 1), 0), j1 = min(Int(c.y + rr + 1), gh - 1)
            guard i0 <= i1, j0 <= j1 else { return }
            for j in j0...j1 {
                for i in i0...i1 {
                    let d = SIMD2<Float>(Float(i) + 0.5, Float(j) + 0.5) - c
                    if simd_length_squared(d) <= rr * rr {
                        mask[j * gw + i] = 1
                        colors[j * gw + i] = color
                    }
                }
            }
        }
        for stroke in strokes where !stroke.points.isEmpty {
            let r = stroke.radius * 1.1
            stamp(stroke.points[0], r, stroke.color)
            for k in 1..<max(stroke.points.count, 1) {
                let a = stroke.points[k - 1], b = stroke.points[k]
                let steps = max(1, Int(simd_distance(a, b) / (cell * 0.5)))
                for s in 1...steps {
                    stamp(a + (b - a) * (Float(s) / Float(steps)), r, stroke.color)
                }
            }
        }

        // 2. Fill enclosed holes so a drawn outline becomes a solid body.
        var outside = [Bool](repeating: false, count: cellCount)
        var queue: [Int] = []
        queue.reserveCapacity(cellCount)
        for i in 0..<gw {
            for j in [0, gh - 1] where mask[j * gw + i] == 0 && !outside[j * gw + i] {
                outside[j * gw + i] = true
                queue.append(j * gw + i)
            }
        }
        for j in 0..<gh {
            for i in [0, gw - 1] where mask[j * gw + i] == 0 && !outside[j * gw + i] {
                outside[j * gw + i] = true
                queue.append(j * gw + i)
            }
        }
        var head = 0
        while head < queue.count {
            let idx = queue[head]; head += 1
            let i = idx % gw, j = idx / gw
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < gw, nj >= 0, nj < gh else { continue }
                let n = nj * gw + ni
                if mask[n] == 0 && !outside[n] {
                    outside[n] = true
                    queue.append(n)
                }
            }
        }
        // Holes take the color of the nearest painted cell.
        queue.removeAll(keepingCapacity: true)
        for idx in 0..<cellCount where mask[idx] == 1 { queue.append(idx) }
        head = 0
        while head < queue.count {
            let idx = queue[head]; head += 1
            let i = idx % gw, j = idx / gw
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ni = i + di, nj = j + dj
                guard ni >= 0, ni < gw, nj >= 0, nj < gh else { continue }
                let n = nj * gw + ni
                if mask[n] == 0 && !outside[n] {
                    mask[n] = 1
                    colors[n] = colors[idx] * 0.92 + SIMD3(0.08, 0.08, 0.08)
                    queue.append(n)
                }
            }
        }

        // 3. Poisson inflation, solved with successive over-relaxation.
        var u = [Float](repeating: 0, count: cellCount)
        u.withUnsafeMutableBufferPointer { ub in
            mask.withUnsafeBufferPointer { mb in
                let omega: Float = 1.9
                for _ in 0..<260 {
                    for j in 1..<(gh - 1) {
                        for i in 1..<(gw - 1) {
                            let idx = j * gw + i
                            if mb[idx] == 0 { continue }
                            let gs = (ub[idx - 1] + ub[idx + 1] + ub[idx - gw] + ub[idx + gw] + 1) * 0.25
                            ub[idx] += omega * (gs - ub[idx])
                        }
                    }
                }
            }
        }
        func cellHeight(_ idx: Int) -> Float { cell * sqrt(max(2 * u[idx], 0)) * puff }

        // 4. Mesh on the cell corners: front surface, back surface, joined at the rim.
        let cw = gw + 1, ch = gh + 1
        var cornerHeight = [Float](repeating: 0, count: cw * ch)
        var cornerColor = [SIMD3<Float>](repeating: .zero, count: cw * ch)
        var cornerUsed = [Bool](repeating: false, count: cw * ch)
        for cj in 0..<ch {
            for ci in 0..<cw {
                var inside = 0, total = 0
                var sumU: Float = 0
                var sumColor = SIMD3<Float>.zero
                for (di, dj) in [(-1, -1), (0, -1), (-1, 0), (0, 0)] {
                    let i = ci + di, j = cj + dj
                    total += 1
                    guard i >= 0, i < gw, j >= 0, j < gh, mask[j * gw + i] == 1 else { continue }
                    inside += 1
                    sumU += u[j * gw + i]
                    sumColor += colors[j * gw + i]
                }
                let idx = cj * cw + ci
                guard inside > 0 else { continue }
                cornerUsed[idx] = true
                cornerColor[idx] = sumColor / Float(inside)
                cornerHeight[idx] = inside == total ? cell * sqrt(max(2 * sumU / 4, 0)) * puff : 0
            }
        }

        // Smooth the stair-stepped outline.
        var xy = [SIMD2<Float>](repeating: .zero, count: cw * ch)
        for cj in 0..<ch {
            for ci in 0..<cw { xy[cj * cw + ci] = origin + SIMD2(Float(ci), Float(cj)) * cell }
        }
        for _ in 0..<4 {
            var next = xy
            for cj in 0..<ch {
                for ci in 0..<cw {
                    let idx = cj * cw + ci
                    guard cornerUsed[idx], cornerHeight[idx] == 0 else { continue }   // only the rim moves
                    var sum = SIMD2<Float>.zero
                    var count: Float = 0
                    for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let ni = ci + di, nj = cj + dj
                        guard ni >= 0, ni < cw, nj >= 0, nj < ch else { continue }
                        let n = nj * cw + ni
                        if cornerUsed[n] && cornerHeight[n] == 0 {
                            sum += xy[n]
                            count += 1
                        }
                    }
                    if count > 0 { next[idx] = xy[idx] * 0.5 + (sum / count) * 0.5 }
                }
            }
            xy = next
        }

        var frontIndex = [Int32](repeating: -1, count: cw * ch)
        var positions: [SIMD3<Float>] = []
        var vertexColors: [SIMD4<Float>] = []
        for idx in 0..<(cw * ch) where cornerUsed[idx] {
            frontIndex[idx] = Int32(positions.count)
            let p = xy[idx] - center
            positions.append(SIMD3(p.x, p.y, cornerHeight[idx]))
            let c = cornerColor[idx]
            vertexColors.append(SIMD4(c.x, c.y, c.z, 1))
        }
        let frontCount = positions.count
        for idx in 0..<(cw * ch) where cornerUsed[idx] {
            let p = xy[idx] - center
            positions.append(SIMD3(p.x, p.y, -cornerHeight[idx] * 0.8))
            let c = cornerColor[idx] * 0.85
            vertexColors.append(SIMD4(c.x, c.y, c.z, 1))
        }

        var indices: [UInt32] = []
        for j in 0..<gh {
            for i in 0..<gw where mask[j * gw + i] == 1 {
                let a = UInt32(frontIndex[j * cw + i])
                let b = UInt32(frontIndex[j * cw + i + 1])
                let c = UInt32(frontIndex[(j + 1) * cw + i + 1])
                let d = UInt32(frontIndex[(j + 1) * cw + i])
                let o = UInt32(frontCount)
                indices.append(contentsOf: [a, b, c, a, c, d])
                indices.append(contentsOf: [a + o, c + o, b + o, a + o, d + o, c + o])
            }
        }
        guard !indices.isEmpty else { return nil }

        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
            let n = simd_cross(positions[ib] - positions[ia], positions[ic] - positions[ia])
            normals[ia] += n
            normals[ib] += n
            normals[ic] += n
        }
        normals = normals.map { simd_length($0) > 1e-9 ? simd_normalize($0) : SIMD3(0, 0, 1) }

        // 5. Face: on the plumpest spot, nudged toward the top.
        var maxU: Float = 0
        for idx in 0..<cellCount where mask[idx] == 1 { maxU = max(maxU, u[idx]) }
        var best = 0
        var bestScore: Float = -1
        for j in 0..<gh {
            for i in 0..<gw where mask[j * gw + i] == 1 {
                let y = origin.y + (Float(j) + 0.5) * cell
                let lift = 1 + 0.35 * (y - center.y) / max(size.y * 0.5, 0.01)
                let score = u[j * gw + i] * lift
                if score > bestScore { bestScore = score; best = j * gw + i }
            }
        }
        let faceCell = SIMD2<Float>(Float(best % gw) + 0.5, Float(best / gw) + 0.5)
        let face = origin + faceCell * cell - center
        let bodyRadius = cell * sqrt(2 * maxU) * puff
        let eyeRadius = min(max(bodyRadius * 0.42, 0.065), 0.2)

        func heightAt(_ local: SIMD2<Float>) -> Float {
            let g = (local + center - origin) / cell
            let i = min(max(Int(g.x), 0), gw - 1), j = min(max(Int(g.y), 0), gh - 1)
            return mask[j * gw + i] == 1 ? cellHeight(j * gw + i) : 0
        }
        var eyes: [SIMD3<Float>] = []
        for side: Float in [-1, 1] {
            let p = face + SIMD2(side * eyeRadius * 1.05, eyeRadius * 0.35)
            eyes.append(SIMD3(p.x, p.y, max(heightAt(p), eyeRadius * 0.5) + eyeRadius * 0.15))
        }
        let mouthXY = face + SIMD2(0, -eyeRadius * 1.25)
        let mouth = SIMD3(mouthXY.x, mouthXY.y, max(heightAt(mouthXY), 0.02) + 0.005)

        var colorSum = SIMD3<Float>.zero
        var colorCount: Float = 0
        for idx in 0..<cellCount where mask[idx] == 1 {
            colorSum += colors[idx]
            colorCount += 1
        }
        let mainColor = colorSum / max(colorCount, 1)
        let maxHeight = cell * sqrt(2 * maxU) * puff

        return CreatureMesh(positions: positions, normals: normals, colors: vertexColors, indices: indices,
                            center: center,
                            halfExtents: SIMD3(size.x * 0.5, size.y * 0.5, maxHeight),
                            eyeCenters: eyes, eyeRadius: eyeRadius, mouth: mouth, mainColor: mainColor,
                            palette: distinctColors(strokes.map(\.color)))
    }
}
