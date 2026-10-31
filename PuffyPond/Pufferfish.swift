import SceneKit
import simd

/// Splatter: while you pinch, the pufferfish swells up (spikes bristling, trembling) and dribbles a few
/// drops. Let go and it bursts: a blob plus a spray of dots and streaks — bigger the longer you held.
final class Pufferfish: Critter {
    private let ballNode = SCNNode()
    private let tailPivot = SCNNode()
    private var spikes: [(node: SCNNode, dir: SIMD3<Float>, jiggle: Spring1)] = []
    private var charge: Float = 0
    private var inflate = Spring1(0)
    private var dribbleTimer: Float = 0
    private var dribbles: [BrushDab] = []

    init(color: SIMD3<Float>, at start: SIMD3<Float>) {
        super.init(kind: .pufferfish, color: color, at: start, accentLift: 0.3)
        squashNode.addChildNode(ballNode)
        ballNode.addChildNode(Toybox.node(SCNSphere(radius: 0.15), bodyMaterial))
        // Pale belly.
        ballNode.addChildNode(Toybox.node(SCNSphere(radius: 0.12), accentMaterial,
                                          at: SIMD3(0, -0.05, 0.05), scale: SIMD3(1.05, 0.8, 1)))

        // Spikes all over (Fibonacci sphere), each on its own little spring.
        let spikeMaterial = accentMaterial
        let count = 26
        for k in 0..<count {
            let y = 1 - (Float(k) + 0.5) / Float(count) * 2
            let r = sqrt(max(0, 1 - y * y))
            let a = Float(k) * 2.39996
            let dir = SIMD3(cos(a) * r, y, sin(a) * r)
            guard dir.z > -0.6 else { continue }    // the back is never seen
            let cone = SCNCone(topRadius: 0, bottomRadius: 0.018, height: 0.05)
            let spike = Toybox.node(cone, spikeMaterial)
            let holder = SCNNode()
            holder.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: dir)
            holder.simdPosition = dir * 0.145
            spike.simdPosition = SIMD3(0, 0.022, 0)
            holder.addChildNode(spike)
            ballNode.addChildNode(holder)
            spikes.append((holder, dir, Spring1(1)))
        }

        tailPivot.simdPosition = SIMD3(-0.15, 0, 0)
        tailPivot.addChildNode(Toybox.node(SCNSphere(radius: 0.07), accentMaterial,
                                           at: SIMD3(-0.05, 0, 0), scale: SIMD3(0.6, 1.2, 0.3)))
        ballNode.addChildNode(tailPivot)
        for side: Float in [-1, 1] {
            ballNode.addChildNode(Toybox.node(SCNSphere(radius: 0.04), accentMaterial,
                                              at: SIMD3(0.02, -0.03, side * 0.14), scale: SIMD3(1.3, 0.6, 0.35)))
        }
        addFace(eyes: [EyeSpot(position: SIMD3(-0.055, 0.045, 0.125), yaw: -0.3, browSign: -1),
                       EyeSpot(position: SIMD3(0.055, 0.045, 0.125), yaw: 0.3, browSign: 1)],
                eyeRadius: 0.052, mouth: SIMD3(0, -0.04, 0.148), mouthRadius: 0.02,
                cheeks: [SIMD3(-0.09, -0.02, 0.12), SIMD3(0.09, -0.02, 0.12)], parent: ballNode)
    }

    override var blowsInk: Bool { false }

    override func flare(_ amount: Float) {
        for i in spikes.indices { spikes[i].jiggle.velocity += Float.random(in: 4...9) * amount }
    }

    override func animate(dt: Float, painting: Bool, beatPulse: Float, scale: Float, hidden: Bool) {
        if painting {
            charge = min(1, charge + dt / 1.6)
        } else {
            charge = max(0, charge - dt * 2)
        }
        inflate.step(to: charge, stiffness: 120, damping: 10, dt: dt)
        let swell = 1 + inflate.value * 0.55
        let tremble = inflate.value > 0.6 ? (inflate.value - 0.6) * 0.06 * sin(clock * 60) : 0
        ballNode.simdScale = SIMD3(repeating: swell + tremble)
        tailPivot.simdEulerAngles = SIMD3(0, sin(clock * (8 + inflate.value * 20)) * 0.4, 0)
        for i in spikes.indices {
            // Spikes stand up as it inflates, and boing on every beat.
            spikes[i].jiggle.velocity += beatPulse * 0.6
            spikes[i].jiggle.step(to: 0.7 + inflate.value * 0.9, stiffness: 220, damping: 7, dt: dt)
            spikes[i].node.simdScale = SIMD3(1, max(spikes[i].jiggle.value, 0.05), 1)
        }

        // A few drops leak out while it puffs up.
        dribbles.removeAll(keepingCapacity: true)
        guard painting, !hidden else { return }
        dribbleTimer -= dt
        if dribbleTimer <= 0 {
            dribbleTimer = Float.random(in: 0.08...0.18)
            let p = position.value
            let q = SIMD2(p.x, p.y) + SIMD2(Float.random(in: -0.08...0.08), Float.random(in: -0.12 ... -0.02))
            dribbles.append(BrushDab(from: q, to: q, radius: Float.random(in: 0.012...0.03), speed: 0,
                                     style: BrushStyle(amount: 0.35, push: 0.2, bristles: 0)))
        }
    }

    override func dabs(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, speed: Float) -> [BrushDab] {
        dribbles
    }

    override func released() -> [BrushDab] {
        let power = charge
        guard power > 0.05 else { return [] }
        let p = position.value
        let center = SIMD2(p.x, p.y)
        let blob = BrushStyle(amount: 0.5, push: 0.3, bristles: 0)
        var result = [BrushDab(from: center, to: center, radius: 0.085 * (0.9 + power * 1.1), speed: 0, style: blob)]
        let count = Int(12 + 40 * power)
        for _ in 0..<count {
            let angle = Float.random(in: 0..<(2 * .pi))
            let dir = SIMD2(cos(angle), sin(angle))
            let reach = 0.1 + pow(Float.random(in: 0...1), 1.5) * (0.35 + 0.9 * power)
            let size = Float.random(in: 0.006...0.035) * (0.7 + power * 0.6)
            if Float.random(in: 0...1) < 0.35 {
                // Streaky flung drops, pointing away from the burst.
                result.append(BrushDab(from: center + dir * reach * 0.75, to: center + dir * reach,
                                       radius: max(size * 0.8, 0.012), speed: 0, style: blob))
            } else {
                let q = center + dir * reach
                result.append(BrushDab(from: q, to: q, radius: size, speed: 0, style: blob))
            }
        }
        charge = 0
        squash.velocity += SIMD3(6, -6, 6)
        flare(1.5)
        react(.happy, for: 0.8)
        return result
    }
}
