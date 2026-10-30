import SceneKit
import simd

// MARK: - Springs (everything bouncy is a spring)

struct Spring3 {
    var value: SIMD3<Float>
    var velocity: SIMD3<Float> = .zero

    init(_ value: SIMD3<Float>) { self.value = value }

    mutating func step(to target: SIMD3<Float>, stiffness: Float, damping: Float, dt: Float) {
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 120.0)
            let a = (target - value) * stiffness - velocity * damping
            velocity += a * h
            value += velocity * h
            remaining -= h
        }
    }
}

struct Spring1 {
    var value: Float
    var velocity: Float = 0

    init(_ value: Float) { self.value = value }

    mutating func step(to target: Float, stiffness: Float, damping: Float, dt: Float) {
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, 1.0 / 120.0)
            let a = (target - value) * stiffness - velocity * damping
            velocity += a * h
            value += velocity * h
            remaining -= h
        }
    }
}

func smoothStep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

// MARK: - Little Fish (the brush)

/// How a fish feels right now. Each mood drives eyes, brows, mouth, cheeks and blush.
enum Mood: Equatable {
    case calm       // swimming along
    case blowing    // concentrating, cheeks puffed, pushing out ink
    case excited    // drawing fast: big sparkly eyes, brows up, wide mouth
    case surprised  // picked a color / bumped a creature: huge eyes, round "O"
    case happy      // finished a line / a creature was born: closed smiling eyes, blush
}

private struct Face {
    var eyeScale: Float
    var squint: Float      // 1 = happy closed eyes
    var browLift: Float
    var browTilt: Float    // + angry/determined, - worried
    var mouth: Float       // mouth opening
    var cheeks: Float      // puffed cheeks
    var blush: Float

    static func target(for mood: Mood) -> Face {
        switch mood {
        case .calm: return Face(eyeScale: 1, squint: 0, browLift: 0, browTilt: 0, mouth: 0.9, cheeks: 0, blush: 0.15)
        case .blowing: return Face(eyeScale: 1.08, squint: 0, browLift: -0.4, browTilt: 0.45, mouth: 1.5, cheeks: 1, blush: 0.45)
        case .excited: return Face(eyeScale: 1.28, squint: 0, browLift: 0.8, browTilt: -0.15, mouth: 1.7, cheeks: 0.4, blush: 0.7)
        case .surprised: return Face(eyeScale: 1.45, squint: 0, browLift: 1.2, browTilt: -0.3, mouth: 2.0, cheeks: 0, blush: 0.3)
        case .happy: return Face(eyeScale: 1, squint: 1, browLift: 0.5, browTilt: -0.2, mouth: 1.1, cheeks: 0.2, blush: 0.9)
        }
    }

    static func mix(_ a: Face, _ b: Face, _ t: Float) -> Face {
        Face(eyeScale: a.eyeScale + (b.eyeScale - a.eyeScale) * t,
             squint: a.squint + (b.squint - a.squint) * t,
             browLift: a.browLift + (b.browLift - a.browLift) * t,
             browTilt: a.browTilt + (b.browTilt - a.browTilt) * t,
             mouth: a.mouth + (b.mouth - a.mouth) * t,
             cheeks: a.cheeks + (b.cheeks - a.cheeks) * t,
             blush: a.blush + (b.blush - a.blush) * t)
    }
}

final class Fish {
    let root = SCNNode()
    private let yawNode = SCNNode()
    private let pitchNode = SCNNode()
    private let squashNode = SCNNode()
    private let tailPivot = SCNNode()
    private let bodyNode: SCNNode
    private let bodyMaterial: SCNMaterial
    private let finMaterial: SCNMaterial
    private let eyes: [Toybox.Eye]
    private var brows: [SCNNode] = []
    private var cheekNodes: [SCNNode] = []
    private let mouthNode: SCNNode
    private let ink: SCNParticleSystem

    private(set) var color: SIMD3<Float>
    private var displayedColor: SIMD3<Float>
    /// While rubbing a paint pot, the body previews the new color.
    var colorPreview: (color: SIMD3<Float>, amount: Float)?
    var position: Spring3
    private var yaw: Float = -0.35
    private var pitch: Float = 0
    private var tailPhase: Float = 0
    private var squash = Spring3(SIMD3(1, 1, 1))
    private var presence = Spring1(0)
    private var blinkStart: Float = -10
    private var nextBlink: Float = 2
    private var clock: Float = 0

    private(set) var mood: Mood = .calm
    private var reaction: (mood: Mood, until: Float)?
    private var face = Face.target(for: .calm)

    var speed: Float { simd_length(position.velocity) }

    init(color: SIMD3<Float>, at start: SIMD3<Float>) {
        self.color = color
        displayedColor = color
        position = Spring3(start)
        bodyMaterial = Toybox.balloon(color, wobble: 0.004, speed: 6)
        finMaterial = Toybox.balloon(color * 0.85 + SIMD3(0.15, 0.15, 0.15), wobble: 0.004, speed: 7)

        root.addChildNode(yawNode)
        yawNode.addChildNode(pitchNode)
        pitchNode.addChildNode(squashNode)

        bodyNode = Toybox.node(SCNSphere(radius: 0.16), bodyMaterial, scale: SIMD3(1.3, 1.0, 0.88))
        squashNode.addChildNode(bodyNode)

        tailPivot.simdPosition = SIMD3(-0.18, 0, 0)
        let tail = Toybox.node(SCNSphere(radius: 0.1), finMaterial,
                               at: SIMD3(-0.07, 0, 0), scale: SIMD3(0.6, 1.2, 0.3))
        tailPivot.addChildNode(tail)
        squashNode.addChildNode(tailPivot)

        let dorsal = Toybox.node(SCNSphere(radius: 0.06), finMaterial,
                                 at: SIMD3(-0.03, 0.15, 0), scale: SIMD3(1.3, 0.8, 0.28))
        squashNode.addChildNode(dorsal)
        for side: Float in [-1, 1] {
            let fin = Toybox.node(SCNSphere(radius: 0.045), finMaterial,
                                  at: SIMD3(0.0, -0.08, side * 0.13), scale: SIMD3(1.3, 0.6, 0.4))
            squashNode.addChildNode(fin)
        }

        let browMaterial = Toybox.balloon(SIMD3(0.15, 0.1, 0.12), wobble: 0, roughness: 0.4)
        let blush = Toybox.blush()
        var eyes: [Toybox.Eye] = []
        for side: Float in [-1, 1] {
            // Each eye looks out of its own side (and a little forward).
            let facing = SCNNode()
            facing.simdPosition = SIMD3(0.09, 0.05, side * 0.12)
            facing.simdEulerAngles = SIMD3(0, side > 0 ? 0.35 : Float.pi - 0.35, 0)
            squashNode.addChildNode(facing)

            let eye = Toybox.eye(radius: 0.068)
            facing.addChildNode(eye.root)
            eyes.append(eye)

            let brow = Toybox.node(SCNCapsule(capRadius: 0.012, height: 0.075), browMaterial)
            facing.addChildNode(brow)
            brows.append(brow)

            let cheek = SCNNode(geometry: SCNSphere(radius: 0.032))
            cheek.geometry?.materials = [blush]
            cheek.simdScale = SIMD3(1.3, 0.75, 0.3)
            cheek.simdPosition = SIMD3(0.07, -0.035, side * 0.135)
            squashNode.addChildNode(cheek)
            cheekNodes.append(cheek)
        }
        self.eyes = eyes

        mouthNode = Toybox.lips(radius: 0.03, color: SIMD3(1.0, 0.45, 0.55))
        mouthNode.simdPosition = SIMD3(0.205, -0.025, 0)
        mouthNode.simdEulerAngles = SIMD3(0, Float.pi / 2, 0)
        squashNode.addChildNode(mouthNode)

        // Ink bubbles puffing out of the mouth while drawing.
        ink = Effects.inkBubbles()
        let nozzle = SCNNode()
        nozzle.simdPosition = SIMD3(0, 0, 0.03)
        nozzle.addParticleSystem(ink)
        mouthNode.addChildNode(nozzle)

        root.simdPosition = start
        root.simdScale = SIMD3(repeating: 0.001)
    }

    func setColor(_ newColor: SIMD3<Float>) {
        color = newColor
        squash.velocity += SIMD3(3, -3, 0)   // shiver of delight
    }

    /// Big gulp when it starts blowing a new balloon line.
    func gulp() {
        squash.velocity += SIMD3(-3, 4, 0)
        react(.excited, for: 0.45)
    }

    /// A short-lived emotion that overrides the current activity mood.
    func react(_ mood: Mood, for seconds: Float) {
        reaction = (mood, clock + seconds)
    }

    func update(dt: Float, target: SIMD3<Float>, visible: Bool, painting: Bool, beatPulse: Float) {
        clock += dt
        presence.step(to: visible ? 1 : 0, stiffness: 160, damping: 14, dt: dt)
        position.step(to: target, stiffness: 95, damping: 19.5, dt: dt)
        let v = position.velocity

        // Face the way it swims; passes through "looking at you" while turning around.
        if abs(v.x) > 0.25 {
            let goal: Float = v.x > 0 ? -0.35 : -Float.pi + 0.35
            yaw += (goal - yaw) * min(1, dt * 7)
        }
        let pitchGoal = max(-0.6, min(0.6, v.y * 0.25))
        pitch += (pitchGoal - pitch) * min(1, dt * 8)

        let swim = smoothStep(0.05, 3, speed)
        tailPhase += dt * (5 + swim * 12 + (painting ? 6 : 0))
        tailPivot.simdEulerAngles = SIMD3(0, sin(tailPhase) * (0.35 + swim * 0.3), 0)

        // Mood: activity first, short reactions on top.
        if let r = reaction, clock > r.until { reaction = nil }
        let activityMood: Mood = painting ? (speed > 1.8 ? .excited : .blowing) : .calm
        mood = reaction?.mood ?? activityMood
        face = Face.mix(face, Face.target(for: mood), min(1, dt * 12))

        // Body: swim stretch, beat bounce, puffed cheeks while blowing ink.
        let stretch = 1 + swim * 0.12
        let beat = beatPulse * 0.07
        let puff = face.cheeks * (0.08 + 0.04 * sin(clock * 16))
        squash.step(to: SIMD3(stretch + beat, 1 / stretch - beat * 0.8 + puff * 0.5, 1 + puff),
                    stiffness: 220, damping: 9, dt: dt)

        var shown = color
        if let preview = colorPreview { shown = mix(color, preview.color, preview.amount) }
        displayedColor += (shown - displayedColor) * min(1, dt * 10)
        bodyMaterial.diffuse.contents = Paint.platform(displayedColor)
        finMaterial.diffuse.contents = Paint.platform(displayedColor * 0.85 + SIMD3(0.15, 0.15, 0.15))

        // Eyes: blink, widen, or close into happy arcs.
        if clock - blinkStart > nextBlink {
            blinkStart = clock
            nextBlink = Float.random(in: 2...5)
        }
        let lid = Toybox.blinkScale(clock - blinkStart) * (1 - face.squint * 0.8)
        for (i, eye) in eyes.enumerated() {
            eye.root.simdScale = SIMD3(face.eyeScale, lid * face.eyeScale, 1)
            eye.pupil.isHidden = face.squint > 0.6
            Toybox.look(eye, toward: SIMD2(0.6, pitch + (mood == .surprised ? 0.5 : 0)))
            let r = eye.radius
            brows[i].simdPosition = SIMD3(0, r * (1.25 + face.browLift * 0.35) * face.eyeScale, r * 0.45)
            brows[i].simdEulerAngles = SIMD3(0, 0, Float.pi / 2 + face.browTilt)
        }
        for cheek in cheekNodes { cheek.opacity = CGFloat(face.blush) }

        // Mouth: pout → big round "O" while pushing ink out.
        let chomp = painting ? 0.15 * sin(clock * 14) : 0
        let m = face.mouth + chomp
        mouthNode.simdScale = SIMD3(m, m, 1)

        ink.birthRate = painting ? 45 + CGFloat(speed) * 25 : 0
        ink.particleColor = Paint.platform(displayedColor)

        root.simdPosition = position.value + SIMD3(0, sin(clock * 2.2) * 0.02, 0)
        yawNode.simdEulerAngles = SIMD3(0, yaw, 0)
        pitchNode.simdEulerAngles = SIMD3(0, 0, pitch)
        squashNode.simdScale = squash.value
        root.simdScale = SIMD3(repeating: max(presence.value, 0.001) * (painting ? 1.08 : 1))
        root.isHidden = presence.value < 0.01 && !visible
    }
}

// MARK: - Starfish (the eraser)

final class Starfish {
    let root = SCNNode()
    private let spinNode = SCNNode()
    private let squashNode = SCNNode()
    private let eyes: [Toybox.Eye]
    private var arms: [SCNNode] = []
    var position: Spring3
    private var spin: Float = 0
    private var presence = Spring1(0)
    private var squash = Spring3(SIMD3(1, 1, 1))
    private var clock: Float = 0
    private var blinkStart: Float = -10
    private var surprised: Float = 0

    var speed: Float { simd_length(position.velocity) }
    static let eraseRadius: Float = 0.26

    init(at start: SIMD3<Float>) {
        position = Spring3(start)
        let pink = SIMD3<Float>(1.0, 0.45, 0.48)
        let material = Toybox.balloon(pink, wobble: 0.005, speed: 5)
        let dotMaterial = Toybox.balloon(SIMD3(1.0, 0.82, 0.7), wobble: 0, roughness: 0.4)

        root.addChildNode(squashNode)
        squashNode.addChildNode(spinNode)

        let center = Toybox.node(SCNSphere(radius: 0.12), material, scale: SIMD3(1, 1, 0.55))
        spinNode.addChildNode(center)
        for k in 0..<5 {
            let angle = Float(k) * 2 * Float.pi / 5 + Float.pi / 2
            let dir = SIMD2<Float>(cos(angle), sin(angle))
            let arm = SCNNode()
            arm.simdPosition = SIMD3(dir.x * 0.15, dir.y * 0.15, 0)
            arm.simdEulerAngles = SIMD3(0, 0, angle - Float.pi / 2)
            let capsule = Toybox.node(SCNCapsule(capRadius: 0.065, height: 0.3), material, scale: SIMD3(1, 1, 0.55))
            arm.addChildNode(capsule)
            for d in 0..<2 {
                let dotNode = Toybox.node(SCNSphere(radius: 0.017), dotMaterial,
                                          at: SIMD3(0, -0.02 + Float(d) * 0.08, 0.034))
                arm.addChildNode(dotNode)
            }
            spinNode.addChildNode(arm)
            arms.append(arm)
        }

        // The face stays upright while the arms spin.
        var eyes: [Toybox.Eye] = []
        for side: Float in [-1, 1] {
            let eye = Toybox.eye(radius: 0.055)
            eye.root.simdPosition = SIMD3(side * 0.05, 0.025, 0.07)
            squashNode.addChildNode(eye.root)
            eyes.append(eye)
        }
        self.eyes = eyes
        let mouth = Toybox.lips(radius: 0.018, color: SIMD3(0.75, 0.15, 0.3))
        mouth.simdPosition = SIMD3(0, -0.05, 0.075)
        squashNode.addChildNode(mouth)

        root.simdPosition = start
        root.simdScale = SIMD3(repeating: 0.001)
        root.isHidden = true
    }

    /// Jumps into the hand at the fish's spot.
    func appear(at point: SIMD3<Float>) {
        position = Spring3(point)
        squash.velocity += SIMD3(4, -4, 0)
    }

    func scrubbed() {
        surprised = 0.35
    }

    func update(dt: Float, target: SIMD3<Float>, visible: Bool, beatPulse: Float) {
        clock += dt
        presence.step(to: visible ? 1 : 0, stiffness: 170, damping: 13, dt: dt)
        position.step(to: target, stiffness: 110, damping: 20, dt: dt)
        spin += dt * (0.8 + speed * 5)
        spinNode.simdEulerAngles = SIMD3(0, 0, -spin)
        for (k, arm) in arms.enumerated() {
            let flap = sin(clock * 9 + Float(k)) * 0.12 * smoothStep(0.1, 2, speed)
            arm.simdScale = SIMD3(1, 1 + flap, 1)
        }
        let beat = beatPulse * 0.08
        squash.step(to: SIMD3(1 + beat, 1 - beat, 1), stiffness: 240, damping: 10, dt: dt)
        surprised = max(0, surprised - dt)

        if clock - blinkStart > 3.5 { blinkStart = clock }
        let lid = surprised > 0 ? 1.25 : Toybox.blinkScale(clock - blinkStart)
        let v = position.velocity
        for eye in eyes {
            eye.root.simdScale = SIMD3(surprised > 0 ? 1.2 : 1, lid, 1)
            Toybox.look(eye, toward: SIMD2(v.x, v.y) * 0.4)
        }

        root.simdPosition = position.value
        squashNode.simdScale = squash.value
        root.simdScale = SIMD3(repeating: max(presence.value, 0.001))
        root.isHidden = presence.value < 0.01 && !visible
    }
}

// MARK: - Paint pots (dip a fish in to pick up a color)

final class PaintPot {
    let root = SCNNode()
    let colorIndex: Int
    let color: SIMD3<Float>
    static let radius: Float = 0.2
    private let body = SCNNode()
    private let blob: SCNNode
    private let blobMaterial: SCNMaterial
    private let progressRing: SCNNode
    private let halo: SCNNode
    private var squash = Spring3(SIMD3(1, 1, 1))
    private var lift = Spring1(0)
    private var ringScale = Spring1(0)
    private var clock: Float = 0

    init(colorIndex: Int, at position: SIMD3<Float>) {
        self.colorIndex = colorIndex
        color = Paint.colors[colorIndex]
        root.simdPosition = position
        root.addChildNode(body)

        let jarMaterial = Toybox.balloon(SIMD3(0.97, 0.97, 1.0), wobble: 0, roughness: 0.15)
        let jar = Toybox.node(SCNCylinder(radius: 0.17, height: 0.16), jarMaterial, at: SIMD3(0, -0.06, 0))
        body.addChildNode(jar)
        let rim = Toybox.node(SCNTorus(ringRadius: 0.17, pipeRadius: 0.025), jarMaterial, at: SIMD3(0, 0.02, 0))
        body.addChildNode(rim)

        // A wobbly dome of paint bulging out of the jar.
        blobMaterial = Toybox.balloon(color, wobble: 0.01, speed: 5, roughness: 0.18)
        blob = Toybox.node(SCNSphere(radius: 0.16), blobMaterial, at: SIMD3(0, 0.03, 0), scale: SIMD3(1, 0.62, 1))
        body.addChildNode(blob)
        let drip = Toybox.node(SCNSphere(radius: 0.035), blobMaterial, at: SIMD3(0.09, -0.04, 0.15),
                               scale: SIMD3(0.8, 1.4, 0.6))
        body.addChildNode(drip)

        // Fills up while you rub a fish in the pot.
        let ringMaterial = SCNMaterial()
        ringMaterial.lightingModel = .constant
        ringMaterial.diffuse.contents = Paint.platform(color)
        progressRing = SCNNode(geometry: SCNTorus(ringRadius: 0.27, pipeRadius: 0.022))
        progressRing.geometry?.materials = [ringMaterial]
        progressRing.simdEulerAngles = SIMD3(Float.pi / 2, 0, 0)
        progressRing.simdScale = SIMD3(repeating: 0.001)
        root.addChildNode(progressRing)

        // Shows which pot is a fish's current color.
        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = Paint.platform(SIMD3(1, 1, 1))
        halo = SCNNode(geometry: SCNTorus(ringRadius: 0.21, pipeRadius: 0.014))
        halo.geometry?.materials = [haloMaterial]
        halo.simdPosition = SIMD3(0, -0.15, 0)
        root.addChildNode(halo)
    }

    func bounce(_ strength: Float = 1) {
        squash.velocity += SIMD3(3, -5, 3) * strength
    }

    /// - Parameters:
    ///   - rubProgress: 0…1 while a fish is being dipped here.
    ///   - selectedCount: how many fish currently wear this color.
    func update(dt: Float, beatPulse: Float, rubProgress: Float, selectedCount: Int) {
        clock += dt
        let jiggle = rubProgress > 0 ? sin(clock * 30) * 0.05 * rubProgress : 0
        squash.step(to: SIMD3(1 + beatPulse * 0.05 + jiggle, 1 - beatPulse * 0.07 - jiggle, 1 + jiggle),
                    stiffness: 260, damping: 9, dt: dt)
        lift.step(to: selectedCount > 0 ? 0.08 : 0, stiffness: 120, damping: 12, dt: dt)
        ringScale.step(to: rubProgress > 0 ? 0.35 + rubProgress * 0.65 : 0, stiffness: 300, damping: 18, dt: dt)
        blob.simdScale = SIMD3(squash.value.x, 0.62 * squash.value.y + rubProgress * 0.15, squash.value.z)
        Toybox.setWobble(blobMaterial, 0.01 + rubProgress * 0.02 + beatPulse * 0.006)
        progressRing.simdScale = SIMD3(repeating: max(ringScale.value, 0.001))
        progressRing.simdEulerAngles = SIMD3(Float.pi / 2, clock * 3, 0)
        halo.isHidden = selectedCount == 0
        halo.simdScale = SIMD3(repeating: 1 + Float(selectedCount - 1) * 0.15 + sin(clock * 4) * 0.04)
        halo.simdEulerAngles = SIMD3(0.25, clock, 0)
        body.simdPosition = SIMD3(0, lift.value, 0)
    }
}

// MARK: - A hand's buddy: fish ↔ starfish

enum BuddyMode: Equatable { case idle, swim, paint, erase }

final class Buddy {
    let slot: Int
    let fish: Fish
    let starfish: Starfish
    private(set) var mode: BuddyMode = .idle
    private(set) var colorIndex: Int
    var rubbingPot: Int?
    var rubAmount: Float = 0

    init(slot: Int, colorIndex: Int, start: SIMD3<Float>) {
        self.slot = slot
        self.colorIndex = colorIndex
        fish = Fish(color: Paint.colors[colorIndex % Paint.colors.count], at: start)
        starfish = Starfish(at: start)
    }

    /// Returns true when the buddy swapped between fish and starfish.
    @discardableResult
    func setMode(_ newMode: BuddyMode) -> Bool {
        guard newMode != mode else { return false }
        let swapped = (newMode == .erase) != (mode == .erase)
        if newMode == .erase { starfish.appear(at: fish.position.value) }
        if mode == .erase && newMode != .erase { fish.position = Spring3(starfish.position.value) }
        mode = newMode
        return swapped
    }

    var toolPosition: SIMD3<Float> {
        mode == .erase ? starfish.position.value : fish.position.value
    }

    var toolSpeed: Float { mode == .erase ? starfish.speed : fish.speed }

    func pick(_ index: Int) {
        colorIndex = index
        fish.colorPreview = nil
        fish.setColor(Paint.colors[index])
        fish.react(.surprised, for: 0.35)
    }

    var color: SIMD3<Float> { Paint.colors[colorIndex % Paint.colors.count] }
}
