import SceneKit
import simd

/// The brush animals. Each one paints in its own way.
enum CritterKind: Int, CaseIterable, Equatable {
    case octopus, snail, pufferfish, seahorse, jellyfish, frog

    var name: String {
        switch self {
        case .octopus: return "Octopus"
        case .snail: return "Snail"
        case .pufferfish: return "Puffer"
        case .seahorse: return "Seahorse"
        case .jellyfish: return "Jelly"
        case .frog: return "Frog"
        }
    }

    /// What kind of brush it is.
    var brush: String {
        switch self {
        case .octopus: return "bundle brush"
        case .snail: return "palette knife"
        case .pufferfish: return "splatter"
        case .seahorse: return "calligraphy nib"
        case .jellyfish: return "watercolor"
        case .frog: return "dot prints"
        }
    }

    var symbol: String {
        switch self {
        case .octopus: return "scribble.variable"
        case .snail: return "rectangle.portrait.fill"
        case .pufferfish: return "sparkle"
        case .seahorse: return "pencil.tip"
        case .jellyfish: return "drop.halffull"
        case .frog: return "circle.grid.cross.fill"
        }
    }

    /// Its own color while it waits in a critter bubble.
    var signatureColor: SIMD3<Float> {
        switch self {
        case .octopus: return Paint.colors[0]
        case .snail: return Paint.colors[2]
        case .pufferfish: return Paint.colors[3]
        case .seahorse: return Paint.colors[1]
        case .jellyfish: return Paint.colors[5]
        case .frog: return Paint.colors[4]
        }
    }

    func make(color: SIMD3<Float>, at start: SIMD3<Float>) -> Critter {
        switch self {
        case .octopus: return Octopus(color: color, at: start)
        case .snail: return Snail(color: color, at: start)
        case .pufferfish: return Pufferfish(color: color, at: start)
        case .seahorse: return Seahorse(color: color, at: start)
        case .jellyfish: return Jellyfish(color: color, at: start)
        case .frog: return Frog(color: color, at: start)
        }
    }
}

/// One paint dab a critter lays this frame.
struct BrushDab {
    var from: SIMD2<Float>
    var to: SIMD2<Float>
    var radius: Float
    var speed: Float
    var style: BrushStyle = .brush
}

/// A hand's brush animal: shared body rig (follow spring, lean, squash, presence), face and moods.
/// Subclasses build their bodies, add their own secondary motion in `animate`, and decide how they
/// paint in `dabs` (while pinching) and `released` (when the pinch lets go).
class Critter {
    let kind: CritterKind
    let root = SCNNode()
    let bodyNode = SCNNode()       // position + appear/disappear scale
    let leanNode = SCNNode()       // tilts toward the motion
    let squashNode = SCNNode()
    let bodyMaterial: SCNMaterial
    let accentMaterial: SCNMaterial

    private(set) var color: SIMD3<Float>
    private(set) var displayedColor: SIMD3<Float>
    /// While rubbing a paint pot, the body previews the new color.
    var colorPreview: (color: SIMD3<Float>, amount: Float)?
    var position: Spring3
    /// Overall size (the little ones sitting in the critter pots are smaller).
    var sizeScale: Float = 1
    var lean = SIMD3<Float>.zero
    var squash = Spring3(SIMD3(1, 1, 1))
    private(set) var presence = Spring1(0)
    private(set) var clock: Float = 0
    /// Where the eyes drift on their own, on top of following the motion (gallery visitors look up).
    var gazeBias = SIMD2<Float>.zero
    /// Turn sideways toward the swim direction (profile animals) instead of facing the camera.
    var turnsToMotion = false
    private var yaw: Float = -0.35
    private var blinkStart: Float = -10
    private var nextBlink: Float = 2

    private(set) var mood: Mood = .calm
    private var reaction: (mood: Mood, until: Float)?
    private(set) var face = Face.target(for: .calm)
    private var eyes: [Toybox.Eye] = []
    private var browSigns: [Float] = []
    private var brows: [SCNNode] = []
    private var cheekNodes: [SCNNode] = []
    private var mouthNode: SCNNode?
    private var ink: SCNParticleSystem?

    var speed: Float { simd_length(position.velocity) }
    /// The displayed size right now (presence × size), for rigs that build world-space meshes.
    var currentScale: Float { max(presence.value, 0.001) * sizeScale }

    init(kind: CritterKind, color: SIMD3<Float>, at start: SIMD3<Float>, accentLift: Float = 0.1) {
        self.kind = kind
        self.color = color
        displayedColor = color
        position = Spring3(start)
        bodyMaterial = Toybox.balloon(color, wobble: 0.004, speed: 6)
        accentMaterial = Toybox.balloon(color, wobble: 0.003, speed: 8)
        self.accentLift = accentLift
        root.addChildNode(bodyNode)
        bodyNode.addChildNode(leanNode)
        leanNode.addChildNode(squashNode)
        bodyNode.simdPosition = start
        bodyNode.simdScale = SIMD3(repeating: 0.001)
    }

    private let accentLift: Float

    // MARK: Face

    struct EyeSpot {
        var position: SIMD3<Float>
        var yaw: Float          // which way the eye looks (0 = toward the camera)
        var browSign: Float     // mirrors the brow tilt for left/right eyes
    }

    /// Googly eyes with brows, blushing cheeks and pouty lips (with an ink nozzle).
    func addFace(eyes spots: [EyeSpot], eyeRadius: Float, mouth: SIMD3<Float>, mouthYaw: Float = 0,
                 mouthRadius: Float, cheeks: [SIMD3<Float>], parent: SCNNode? = nil) {
        let host = parent ?? squashNode
        let browMaterial = Toybox.balloon(SIMD3(0.15, 0.1, 0.12), wobble: 0, roughness: 0.4)
        for spot in spots {
            let facing = SCNNode()
            facing.simdPosition = spot.position
            facing.simdEulerAngles = SIMD3(0, spot.yaw, 0)
            host.addChildNode(facing)
            let eye = Toybox.eye(radius: eyeRadius)
            facing.addChildNode(eye.root)
            eyes.append(eye)
            let brow = Toybox.node(SCNCapsule(capRadius: CGFloat(eyeRadius * 0.18), height: CGFloat(eyeRadius * 1.1)),
                                   browMaterial)
            facing.addChildNode(brow)
            brows.append(brow)
            browSigns.append(spot.browSign)
        }
        let blush = Toybox.blush()
        for p in cheeks {
            let cheek = SCNNode(geometry: SCNSphere(radius: CGFloat(eyeRadius * 0.5)))
            cheek.geometry?.materials = [blush]
            cheek.simdScale = SIMD3(1.3, 0.75, 0.3)
            cheek.simdPosition = p
            host.addChildNode(cheek)
            cheekNodes.append(cheek)
        }
        let lips = Toybox.lips(radius: mouthRadius, color: SIMD3(1.0, 0.45, 0.55))
        lips.simdPosition = mouth
        lips.simdEulerAngles = SIMD3(0, mouthYaw, 0)
        host.addChildNode(lips)
        mouthNode = lips
        let particles = Effects.inkBubbles()
        let nozzle = SCNNode()
        nozzle.simdPosition = SIMD3(0, 0, 0.03)
        nozzle.addParticleSystem(particles)
        lips.addChildNode(nozzle)
        ink = particles
    }

    // MARK: Reactions

    func setColor(_ newColor: SIMD3<Float>) {
        color = newColor
        squash.velocity += SIMD3(3, -3, 0)   // shiver of delight
        flare(0.6)
    }

    /// Big gulp when it starts a new line.
    func gulp() {
        squash.velocity += SIMD3(-3, 4, 0)
        flare(1)
        react(.excited, for: 0.45)
    }

    /// A short-lived emotion that overrides the current activity mood.
    func react(_ mood: Mood, for seconds: Float) {
        reaction = (mood, clock + seconds)
        if mood == .surprised { flare(0.8) }
    }

    /// Secondary-motion kick (tentacles splay, spikes boing…).
    func flare(_ amount: Float) {}

    // MARK: Per frame

    func update(dt: Float, target: SIMD3<Float>, visible: Bool, painting: Bool, beatPulse: Float) {
        clock += dt
        presence.step(to: visible ? 1 : 0, stiffness: 160, damping: 14, dt: dt)
        move(dt: dt, target: target, painting: painting)
        let v = position.velocity

        let leanGoal = SIMD3(max(-0.45, min(0.45, -v.y * 0.1)),
                             max(-0.35, min(0.35, v.x * 0.1)),
                             max(-0.5, min(0.5, -v.x * 0.13))) * leanAmount
        lean += (leanGoal - lean) * min(1, dt * 8)
        if turnsToMotion, abs(v.x) > 0.25 {
            let goal: Float = v.x > 0 ? -0.35 : -Float.pi + 0.35
            yaw += (goal - yaw) * min(1, dt * 7)
        }

        if let r = reaction, clock > r.until { reaction = nil }
        let activityMood: Mood = painting ? (speed > 1.8 ? .excited : .blowing) : .calm
        mood = reaction?.mood ?? activityMood
        face = Face.mix(face, Face.target(for: mood), min(1, dt * 12))

        let stretch = 1 + smoothStep(0.05, 3, speed) * 0.1
        let beat = beatPulse * 0.07
        let puff = face.cheeks * (0.08 + 0.04 * sin(clock * 16))
        squash.step(to: SIMD3(1 / stretch + beat + puff * 0.5, stretch - beat * 0.8, 1 + puff),
                    stiffness: 220, damping: 9, dt: dt)

        var shown = color
        if let preview = colorPreview { shown = mix(color, preview.color, preview.amount) }
        displayedColor += (shown - displayedColor) * min(1, dt * 10)
        bodyMaterial.diffuse.contents = Paint.platform(displayedColor)
        accentMaterial.diffuse.contents = Paint.platform(displayedColor * (1 - accentLift) + SIMD3(repeating: accentLift))

        if clock - blinkStart > nextBlink {
            blinkStart = clock
            nextBlink = Float.random(in: 2...5)
        }
        let lid = Toybox.blinkScale(clock - blinkStart) * (1 - face.squint * 0.8)
        let gaze = SIMD2(max(-0.8, min(0.8, v.x * 0.3)) * (turnsToMotion ? 0 : 1) + (turnsToMotion ? 0.6 : 0),
                         max(-0.8, min(0.8, v.y * 0.3)) + (mood == .surprised ? 0.4 : 0)) + gazeBias
        for (i, eye) in eyes.enumerated() {
            eye.root.simdScale = SIMD3(face.eyeScale, lid * face.eyeScale, 1)
            eye.pupil.isHidden = face.squint > 0.6
            Toybox.look(eye, toward: gaze)
            let r = eye.radius
            brows[i].simdPosition = SIMD3(0, r * (1.25 + face.browLift * 0.35) * face.eyeScale, r * 0.45)
            brows[i].simdEulerAngles = SIMD3(0, 0, Float.pi / 2 + browSigns[i] * face.browTilt)
        }
        for cheek in cheekNodes { cheek.opacity = CGFloat(face.blush) }
        if let mouthNode {
            let chomp = painting ? 0.15 * sin(clock * 14) : 0
            let m = face.mouth + chomp
            mouthNode.simdScale = SIMD3(m, m, 1)
        }
        ink?.birthRate = painting && blowsInk ? 45 + CGFloat(speed) * 25 : 0
        ink?.particleColor = Paint.platform(displayedColor)

        let scale = currentScale * (painting ? 1.08 : 1)
        bodyNode.simdPosition = position.value + SIMD3(0, bob, 0)
        bodyNode.simdScale = SIMD3(repeating: scale)
        leanNode.simdEulerAngles = lean + SIMD3(0, turnsToMotion ? yaw : 0, 0)
        squashNode.simdScale = squash.value
        let hidden = presence.value < 0.01 && !visible
        root.isHidden = hidden
        animate(dt: dt, painting: painting, beatPulse: beatPulse, scale: scale, hidden: hidden)
    }

    // MARK: Overridable behavior

    var followStiffness: Float { 95 }
    var followDamping: Float { 19.5 }
    var leanAmount: Float { 1 }
    var blowsInk: Bool { true }
    var bob: Float { sin(clock * 2.2) * 0.02 }

    /// How the critter travels toward the hand (a spring by default; the frog hops).
    func move(dt: Float, target: SIMD3<Float>, painting: Bool) {
        position.step(to: target, stiffness: followStiffness, damping: followDamping, dt: dt)
    }

    /// Secondary motion, after the body transforms are set for this frame.
    func animate(dt: Float, painting: Bool, beatPulse: Float, scale: Float, hidden: Bool) {}

    /// Paint for this frame's brush segment a → b (the critter's own path across the canvas).
    func dabs(from a: SIMD2<Float>, to b: SIMD2<Float>, radius: Float, speed: Float) -> [BrushDab] {
        [BrushDab(from: a, to: b, radius: radius, speed: speed)]
    }

    /// Paint laid when the pinch lets go.
    func released() -> [BrushDab] { [] }
}
