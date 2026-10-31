import SceneKit
import simd

/// Watercolor: a see-through jellyfish. Its bell pulses on the beat and every pulse drops a runny
/// wash that blooms outward; its long trailing tentacles drip thin watery lines.
final class Jellyfish: Critter {
    private let bellNode = SCNNode()
    private let tentacles: TentacleBundle
    private let arms: TentacleBundle
    private var lastBody: SIMD3<Float>
    private var pulse = Spring1(0)
    private var lastBeat: Float = 0
    private var pulsed = false

    init(color: SIMD3<Float>, at start: SIMD3<Float>) {
        lastBody = start
        var long = TentacleBundle.Shape()
        long.segments = 13
        long.segmentLength = 0.04
        long.rootRadius = 0.011
        long.tipRadius = 0.003
        long.startAngle = 0.12
        long.curl = 0.25
        long.sway = 0.35
        long.stiffness = 0.025      // very floppy: they stream behind
        long.drag = 0.985
        long.gravity = 0.4
        long.ripple = 0.3
        let count = 8
        let ringRoots = (0..<count).map { k -> (local: SIMD3<Float>, outward: SIMD3<Float>) in
            let a = (Float(k) + 0.5) / Float(count) * 2 * .pi
            return (SIMD3(cos(a) * 0.13, -0.04, sin(a) * 0.09), SIMD3(cos(a), 0, sin(a) * 0.5))
        }
        tentacles = TentacleBundle(shape: long, roots: ringRoots, start: start)

        var frilly = TentacleBundle.Shape()
        frilly.segments = 8
        frilly.segmentLength = 0.03
        frilly.rootRadius = 0.026
        frilly.tipRadius = 0.006
        frilly.startAngle = 0.05
        frilly.curl = 0.6
        frilly.sway = 0.4
        frilly.stiffness = 0.05
        frilly.ripple = 0.5
        let armRoots = (0..<4).map { k -> (local: SIMD3<Float>, outward: SIMD3<Float>) in
            let a = Float(k) / 4 * 2 * .pi + 0.4
            return (SIMD3(cos(a) * 0.035, -0.05, sin(a) * 0.03), SIMD3(cos(a), 0, sin(a) * 0.5))
        }
        arms = TentacleBundle(shape: frilly, roots: armRoots, start: start)
        super.init(kind: .jellyfish, color: color, at: start, accentLift: 0.45)

        for m in [bodyMaterial, accentMaterial] {
            m.transparency = 0.72
            m.transparencyMode = .dualLayer
            m.emission.contents = Paint.platform(SIMD3(0.12, 0.12, 0.12))
        }
        tentacles.material = accentMaterial
        arms.material = bodyMaterial
        root.addChildNode(tentacles.node)
        root.addChildNode(arms.node)

        // Bell: a squashed dome with a frilly rim.
        squashNode.addChildNode(bellNode)
        bellNode.addChildNode(Toybox.node(SCNSphere(radius: 0.17), bodyMaterial,
                                          at: SIMD3(0, 0.03, 0), scale: SIMD3(1, 0.78, 0.8)))
        let rim = Toybox.node(SCNTorus(ringRadius: 0.15, pipeRadius: 0.03), accentMaterial,
                              at: SIMD3(0, -0.04, 0), scale: SIMD3(1, 0.7, 0.75))
        bellNode.addChildNode(rim)
        addFace(eyes: [EyeSpot(position: SIMD3(-0.058, 0.04, 0.125), yaw: -0.25, browSign: -1),
                       EyeSpot(position: SIMD3(0.058, 0.04, 0.125), yaw: 0.25, browSign: 1)],
                eyeRadius: 0.05, mouth: SIMD3(0, -0.02, 0.135), mouthRadius: 0.017,
                cheeks: [SIMD3(-0.1, 0.0, 0.11), SIMD3(0.1, 0.0, 0.11)], parent: bellNode)
    }

    override var blowsInk: Bool { false }
    override var followStiffness: Float { 60 }
    override var followDamping: Float { 11 }
    override var bob: Float { sin(clock * 1.6) * 0.035 }

    override func flare(_ amount: Float) {
        let m = leanNode.simdWorldTransform
        tentacles.flare(amount, body: m)
        arms.flare(amount, body: m)
        pulse.velocity += 6 * amount
    }

    override func animate(dt: Float, painting: Bool, beatPulse: Float, scale: Float, hidden: Bool) {
        // Bell contracts on every beat (and the tentacles get a little kick).
        pulsed = beatPulse > lastBeat + 0.3
        lastBeat = beatPulse
        if pulsed {
            pulse.velocity += 7
            tentacles.flare(0.4, body: leanNode.simdWorldTransform)
        }
        pulse.step(to: 0, stiffness: 140, damping: 8, dt: dt)
        let p = pulse.value * 0.12
        bellNode.simdScale = SIMD3(1 - p, 1 + p * 0.8, 1 - p)

        let body = bodyNode.simdPosition
        let teleported = simd_distance(body, lastBody) > 0.8
        lastBody = body
        let m = leanNode.simdWorldTransform
        tentacles.simulate(dt: dt, body: m, scale: scale, clock: clock, beatPulse: 0, snap: teleported)
        arms.simulate(dt: dt, body: m, scale: scale, clock: clock, beatPulse: 0, snap: teleported)
        tentacles.collectTips(dt: dt, painting: painting && !hidden)
        tentacles.rebuild(scale: scale, clock: clock, hidden: hidden)
        arms.rebuild(scale: scale, clock: clock, hidden: hidden)
    }

    override func dabs(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, speed: Float) -> [BrushDab] {
        // A soft continuous wash along the path…
        var result = [BrushDab(from: a, to: b, radius: radius * 1.3, speed: speed,
                               style: BrushStyle(amount: 0.1, push: 0.2, bristles: 0, watery: 0.8))]
        // …a big blooming wash on every pulse…
        if pulsed {
            result.append(BrushDab(from: b, to: b, radius: radius * 2.4, speed: 0,
                                   style: BrushStyle(amount: 0.14, push: 0, bristles: 0, watery: 1)))
        }
        // …and thin drips from every other tentacle.
        for (k, tip) in tentacles.tipStrokes.enumerated() where k % 2 == 0 {
            result.append(BrushDab(from: tip.from, to: tip.to, radius: radius * 0.14, speed: tip.speed,
                                   style: BrushStyle(amount: 0.2, push: 0.3, bristles: 0, watery: 0.5)))
        }
        return result
    }
}
