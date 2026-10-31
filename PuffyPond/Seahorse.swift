import SceneKit
import simd

/// Calligraphy nib: the seahorse's snout is a flat pen held at 45°, so lines swell thick and thin
/// with the direction you move. Its curly tail is a springy chain that coils and uncoils.
final class Seahorse: Critter {
    private let tail: TentacleBundle
    private let finPivot = SCNNode()
    private var lastBody: SIMD3<Float>
    /// The classic broad-nib angle.
    private static let nibAngle: Float = .pi / 4

    init(color: SIMD3<Float>, at start: SIMD3<Float>) {
        lastBody = start
        var shape = TentacleBundle.Shape()
        shape.segments = 10
        shape.segmentLength = 0.028
        shape.rootRadius = 0.045
        shape.tipRadius = 0.01
        shape.startAngle = 0.1
        shape.curl = 4.2           // a tight curl at the end
        shape.sway = 0.15
        shape.stiffness = 0.11
        shape.ripple = 0.05
        tail = TentacleBundle(shape: shape, roots: [(SIMD3(-0.02, -0.17, 0), SIMD3(-1, 0, 0.2))], start: start)
        super.init(kind: .seahorse, color: color, at: start, accentLift: 0.25)
        tail.material = bodyMaterial
        root.addChildNode(tail.node)

        // Belly and chest: a stack of rounded rings, bulging forward.
        for k in 0..<4 {
            let t = Float(k) / 3
            let ring = Toybox.node(SCNSphere(radius: CGFloat(0.075 - t * 0.02)), k % 2 == 0 ? bodyMaterial : accentMaterial,
                                   at: SIMD3(0.025 * sin(t * 3), 0.02 - t * 0.14, 0), scale: SIMD3(1, 0.75, 0.9))
            squashNode.addChildNode(ring)
        }
        // Head with a long snout (the pen nib) and a crest.
        let head = Toybox.node(SCNSphere(radius: 0.07), bodyMaterial, at: SIMD3(0.02, 0.12, 0), scale: SIMD3(1.05, 1, 0.9))
        squashNode.addChildNode(head)
        let snout = Toybox.node(SCNCapsule(capRadius: 0.024, height: 0.13), accentMaterial, at: SIMD3(0.1, 0.09, 0))
        snout.simdEulerAngles = SIMD3(0, 0, Float.pi / 2 + 0.35)
        squashNode.addChildNode(snout)
        let crest = Toybox.node(SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.06), accentMaterial,
                                at: SIMD3(-0.01, 0.2, 0))
        squashNode.addChildNode(crest)

        finPivot.simdPosition = SIMD3(-0.06, 0, 0)
        finPivot.addChildNode(Toybox.node(SCNSphere(radius: 0.05), accentMaterial,
                                          at: SIMD3(-0.03, 0, 0), scale: SIMD3(0.8, 1.1, 0.25)))
        squashNode.addChildNode(finPivot)

        addFace(eyes: [EyeSpot(position: SIMD3(0.04, 0.14, 0.05), yaw: 0.35, browSign: 1),
                       EyeSpot(position: SIMD3(0.04, 0.14, -0.05), yaw: Float.pi - 0.35, browSign: -1)],
                eyeRadius: 0.04, mouth: SIMD3(0.165, 0.065, 0), mouthYaw: Float.pi / 2, mouthRadius: 0.014,
                cheeks: [SIMD3(0.05, 0.09, 0.06)])
        turnsToMotion = true
    }

    override var leanAmount: Float { 0.6 }
    override var bob: Float { sin(clock * 1.8) * 0.03 }

    override func flare(_ amount: Float) {
        tail.flare(amount, body: leanNode.simdWorldTransform)
    }

    override func animate(dt: Float, painting: Bool, beatPulse: Float, scale: Float, hidden: Bool) {
        finPivot.simdEulerAngles = SIMD3(0, sin(clock * (14 + speed * 6)) * 0.6, 0)
        let body = bodyNode.simdPosition
        let teleported = simd_distance(body, lastBody) > 0.8
        lastBody = body
        tail.simulate(dt: dt, body: leanNode.simdWorldTransform, scale: scale, clock: clock,
                      beatPulse: beatPulse, snap: teleported)
        tail.rebuild(scale: scale, clock: clock, hidden: hidden)
    }

    override func dabs(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, speed: Float) -> [BrushDab] {
        let style = BrushStyle(push: 0.35, bristles: 0.35, nibAngle: Self.nibAngle, nibAspect: 5)
        return [BrushDab(from: a, to: b, radius: radius * 1.3, speed: speed, style: style)]
    }
}
