import SceneKit
import simd

/// Palette knife: a slow, heavy snail that lays wide, flat sheets of paint with ridged edges and
/// shoves the wet paint it slides through. Its shell and eye stalks lag and wobble behind it.
final class Snail: Critter {
    private let shellPivot = SCNNode()
    private var shellLag = Spring3(.zero)
    private var stalks: [(pivot: SCNNode, lag: Spring3)] = []
    private var lastVelocity = SIMD3<Float>.zero

    init(color: SIMD3<Float>, at start: SIMD3<Float>) {
        super.init(kind: .snail, color: color, at: start, accentLift: 0.35)

        // Soft foot along the bottom, rising into a head on the front.
        let foot = Toybox.node(SCNCapsule(capRadius: 0.07, height: 0.42), accentMaterial,
                               at: SIMD3(0, -0.09, 0), scale: SIMD3(1, 1, 1.15))
        foot.simdEulerAngles = SIMD3(0, 0, Float.pi / 2)
        squashNode.addChildNode(foot)
        squashNode.addChildNode(Toybox.node(SCNSphere(radius: 0.1), accentMaterial,
                                            at: SIMD3(0.15, -0.02, 0.02), scale: SIMD3(1, 1.1, 1)))

        // Spiral shell: a big ball with coiled rings, on a pivot so it can wobble.
        shellPivot.simdPosition = SIMD3(-0.04, -0.04, -0.02)
        squashNode.addChildNode(shellPivot)
        shellPivot.addChildNode(Toybox.node(SCNSphere(radius: 0.15), bodyMaterial,
                                            at: SIMD3(0, 0.12, 0), scale: SIMD3(1, 1, 0.8)))
        let coil = Toybox.balloon(SIMD3(1, 1, 1), wobble: 0, roughness: 0.3)
        coil.diffuse.contents = Paint.platform(SIMD3(1, 0.97, 0.9))
        for (k, r) in [0.115, 0.075, 0.038].enumerated() {
            let ring = Toybox.node(SCNTorus(ringRadius: CGFloat(r), pipeRadius: CGFloat(0.013 - Double(k) * 0.003)), coil,
                                   at: SIMD3(Float(k) * 0.012, 0.12 + Float(k) * 0.008, 0.115))
            ring.simdEulerAngles = SIMD3(Float.pi / 2, 0, 0)
            shellPivot.addChildNode(ring)
        }

        // Eye stalks with googly eyes on top.
        for side: Float in [-1, 1] {
            let pivot = SCNNode()
            pivot.simdPosition = SIMD3(0.16 + side * 0.035, 0.05, 0.05)
            squashNode.addChildNode(pivot)
            pivot.addChildNode(Toybox.node(SCNCapsule(capRadius: 0.014, height: 0.14), accentMaterial,
                                           at: SIMD3(0, 0.06, 0)))
            stalks.append((pivot, Spring3(.zero)))
        }
        let eyeHost = SCNNode()
        squashNode.addChildNode(eyeHost)
        addFace(eyes: [EyeSpot(position: SIMD3(0, 0.15, 0.01), yaw: -0.1, browSign: -1),
                       EyeSpot(position: SIMD3(0, 0.15, 0.01), yaw: 0.1, browSign: 1)],
                eyeRadius: 0.045, mouth: SIMD3(0.17, -0.05, 0.1), mouthRadius: 0.018,
                cheeks: [SIMD3(0.1, -0.03, 0.1), SIMD3(0.23, -0.03, 0.08)], parent: eyeHost)
        // Move each eye (with its brow) onto the top of its stalk.
        for (i, facing) in eyeHost.childNodes.prefix(2).enumerated() {
            facing.removeFromParentNode()
            facing.simdPosition = SIMD3(0, 0.15, 0.01)
            stalks[i].pivot.addChildNode(facing)
        }
        turnsToMotion = true
    }

    // Slow and heavy: it oozes after your hand.
    override var followStiffness: Float { 38 }
    override var followDamping: Float { 12 }
    override var leanAmount: Float { 0.4 }
    override var bob: Float { sin(clock * 1.3) * 0.01 }

    override func flare(_ amount: Float) {
        shellLag.velocity += SIMD3(0, 3, 0) * amount
        for i in stalks.indices { stalks[i].lag.velocity += SIMD3(Float(i) * 2 - 1, 2, 0) * amount }
    }

    override func animate(dt: Float, painting: Bool, beatPulse: Float, scale: Float, hidden: Bool) {
        // The shell and stalks get flung by changes in speed, then spring back.
        let accel = (position.velocity - lastVelocity) / max(dt, 1e-4)
        lastVelocity = position.velocity
        shellLag.velocity -= accel * dt * 0.6
        shellLag.step(to: SIMD3(0, beatPulse * 0.02, 0), stiffness: 90, damping: 6, dt: dt)
        shellPivot.simdEulerAngles = SIMD3(shellLag.value.y * 0.8, 0, -shellLag.value.x * 1.4)
        for i in stalks.indices {
            stalks[i].lag.velocity -= accel * dt * 1.2
            stalks[i].lag.step(to: SIMD3(sin(clock * 2 + Float(i)) * 0.08, 0, 0), stiffness: 60, damping: 4, dt: dt)
            let l = stalks[i].lag.value
            stalks[i].pivot.simdEulerAngles = SIMD3(l.y * 1.2, 0, -l.x * 2.2 + (Float(i) * 2 - 1) * -0.15)
        }
    }

    override var blowsInk: Bool { false }

    override func dabs(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, speed: Float) -> [BrushDab] {
        // The blade lies across the direction of travel: a wide sheet, crisp ridged edges.
        let d = b - a
        let angle = simd_length(d) > 1e-5 ? atan2(d.y, d.x) + Float.pi / 2 : Float.pi / 2
        var style = BrushStyle(push: 0.95, bristles: 0.1, nibAngle: angle, nibAspect: 1.6, knife: 1)
        style.amount = 0.02 + 0.2 * smoothStep(0.002, 0.02, simd_length(d))
        return [BrushDab(from: a, to: b, radius: radius * 1.9, speed: speed, style: style)]
    }
}
