import SceneKit
import simd

/// Dot prints: the frog doesn't glide, it hops after your hand. Every landing while pinching stamps
/// a round print with four toe dots, so lines become rhythmic trails of prints.
final class Frog: Critter {
    private var hop: (from: SIMD3<Float>, to: SIMD3<Float>, t: Float, duration: Float)?
    private var restTimer: Float = 0
    private var legs: [SCNNode] = []
    private var prints: [BrushDab] = []
    private var landedPainting = false
    private var hopDirection = SIMD2<Float>(1, 0)

    init(color: SIMD3<Float>, at start: SIMD3<Float>) {
        super.init(kind: .frog, color: color, at: start, accentLift: 0.4)
        // Wide squat body with a pale belly.
        squashNode.addChildNode(Toybox.node(SCNSphere(radius: 0.15), bodyMaterial,
                                            at: SIMD3(0, -0.02, 0), scale: SIMD3(1.3, 0.85, 0.95)))
        squashNode.addChildNode(Toybox.node(SCNSphere(radius: 0.11), accentMaterial,
                                            at: SIMD3(0, -0.06, 0.07), scale: SIMD3(1.3, 0.75, 0.8)))
        // Eye bumps on top of the head.
        for side: Float in [-1, 1] {
            squashNode.addChildNode(Toybox.node(SCNSphere(radius: 0.065), bodyMaterial,
                                                at: SIMD3(side * 0.085, 0.1, 0.03)))
        }
        // Folded back legs (they kick out during a hop) and little front feet.
        for side: Float in [-1, 1] {
            let hip = SCNNode()
            hip.simdPosition = SIMD3(side * 0.15, -0.08, -0.02)
            hip.addChildNode(Toybox.node(SCNSphere(radius: 0.06), bodyMaterial,
                                         at: SIMD3(side * 0.03, -0.02, 0), scale: SIMD3(1.3, 0.8, 1)))
            hip.addChildNode(Toybox.node(SCNSphere(radius: 0.035), accentMaterial,
                                         at: SIMD3(side * 0.07, -0.07, 0.04), scale: SIMD3(1.6, 0.5, 1.2)))
            squashNode.addChildNode(hip)
            legs.append(hip)
            squashNode.addChildNode(Toybox.node(SCNSphere(radius: 0.03), accentMaterial,
                                                at: SIMD3(side * 0.07, -0.13, 0.1), scale: SIMD3(1.4, 0.5, 1.2)))
        }
        addFace(eyes: [EyeSpot(position: SIMD3(-0.085, 0.12, 0.075), yaw: -0.3, browSign: -1),
                       EyeSpot(position: SIMD3(0.085, 0.12, 0.075), yaw: 0.3, browSign: 1)],
                eyeRadius: 0.05, mouth: SIMD3(0, -0.01, 0.14), mouthRadius: 0.024,
                cheeks: [SIMD3(-0.12, 0.0, 0.11), SIMD3(0.12, 0.0, 0.11)])
    }

    override var blowsInk: Bool { false }
    override var leanAmount: Float { 0.35 }
    override var bob: Float { hop == nil ? sin(clock * 3) * 0.006 : 0 }

    /// Sit, then leap toward the hand in an arc; land with a squash.
    override func move(dt: Float, target: SIMD3<Float>, painting: Bool) {
        if var h = hop {
            h.t += dt / h.duration
            let t = min(h.t, 1)
            let arc = sin(t * .pi) * (0.1 + simd_distance(h.from, h.to) * 0.3)
            let previous = position.value
            position.value = h.from + (h.to - h.from) * t + SIMD3(0, arc, arc * 0.6)
            position.velocity = (position.value - previous) / max(dt, 1e-4)
            if h.t >= 1 {
                hop = nil
                position.velocity = .zero
                restTimer = painting ? 0.05 : 0.12
                squash.velocity += SIMD3(5, -7, 5)
                landedPainting = painting
            } else {
                hop = h
            }
            return
        }
        position.velocity = .zero
        restTimer -= dt
        let gap = target - position.value
        let distance = simd_length(SIMD2(gap.x, gap.y))
        guard restTimer <= 0, distance > 0.1 else { return }
        let length = min(distance, painting ? 0.32 : 0.6)
        let step = gap * (length / max(simd_length(gap), 1e-5))
        hopDirection = simd_normalize(SIMD2(step.x, step.y) + SIMD2(1e-5, 0))
        hop = (position.value, position.value + step, 0, 0.2 + length * 0.25)
        squash.velocity += SIMD3(-4, 6, -4)     // crouch-and-spring
    }

    override func animate(dt: Float, painting: Bool, beatPulse: Float, scale: Float, hidden: Bool) {
        let kick: Float = hop.map { sin(min($0.t, 1) * .pi) } ?? 0
        for (i, leg) in legs.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            leg.simdEulerAngles = SIMD3(kick * 0.9, 0, side * kick * 0.8)
        }
        prints.removeAll(keepingCapacity: true)
        guard landedPainting, !hidden else { return }
        landedPainting = false
        // Landing print: a round pad plus four toe dots fanned out ahead.
        let p = position.value
        let center = SIMD2(p.x, p.y)
        let pad = BrushStyle(amount: 0.45, push: 0.25, bristles: 0.2)
        prints.append(BrushDab(from: center, to: center, radius: 0.085 * 1.05, speed: 0, style: pad))
        let heading = atan2(hopDirection.y, hopDirection.x)
        for k in 0..<4 {
            let a = heading + (Float(k) - 1.5) * 0.45
            let q = center + SIMD2(cos(a), sin(a)) * 0.085 * 1.75
            prints.append(BrushDab(from: q, to: q, radius: 0.085 * 0.32, speed: 0, style: pad))
        }
    }

    override func dabs(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, speed: Float) -> [BrushDab] {
        prints
    }
}
