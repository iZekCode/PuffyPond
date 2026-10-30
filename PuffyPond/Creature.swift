import SceneKit
import simd

/// A finished drawing, alive: it puffs up off the canvas, then floats, bobs, wiggles,
/// dances to the beat, watches your hands, and boings when you bump it.
final class Creature {
    enum Phase { case forming, alive, leaving, popping, gone }

    let root = SCNNode()
    private let squashNode = SCNNode()
    private let bodyMaterial: SCNMaterial
    private var eyes: [Toybox.Eye] = []
    private let faceNode = SCNNode()

    private(set) var phase: Phase = .forming
    var position: Spring3
    private var squash = Spring3(SIMD3(1, 1, 0.03))
    private var spinVelocity: Float = 0
    private var spinAngle: Float = 0
    private var facePresence = Spring1(0)
    private var age: Float = 0
    private var wanderTarget: SIMD3<Float>
    private var nextWander: Float = 0
    private let seed = Float.random(in: 0...100)
    private var blinkStart: Float = -10
    private var nextBlink: Float = 2.5
    private var surprised: Float = 0
    private var boingCooldown: Float = 0
    private var popTime: Float = 0
    /// Grows to full drawing size while inflating on the canvas, then shrinks to a cute 50% as it lifts off.
    private var size = Spring1(1)
    static let finalSize: Float = 0.5
    private let baseRadius: Float
    private let eyeRadius: Float
    let mainColor: SIMD3<Float>
    let palette: [SIMD3<Float>]

    var radius: Float { baseRadius * size.value }

    init(mesh: CreatureMesh, canvasZ: Float) {
        let geometry = MeshBuilder.geometry(positions: mesh.positions, normals: mesh.normals,
                                            colors: mesh.colors, indices: mesh.indices)
        bodyMaterial = Toybox.balloon(SIMD3(1, 1, 1), wobble: 0.012, speed: 4, roughness: 0.25)
        geometry.materials = [bodyMaterial]
        let body = SCNNode(geometry: geometry)
        body.castsShadow = true
        mainColor = mesh.mainColor
        palette = mesh.palette
        eyeRadius = mesh.eyeRadius
        baseRadius = max(simd_length(SIMD2(mesh.halfExtents.x, mesh.halfExtents.y)), 0.15)

        root.addChildNode(squashNode)
        squashNode.addChildNode(body)
        squashNode.addChildNode(faceNode)

        for center in mesh.eyeCenters {
            let eye = Toybox.eye(radius: mesh.eyeRadius)
            eye.root.simdPosition = center
            faceNode.addChildNode(eye.root)
            eyes.append(eye)
        }
        let lipColor = simd_clamp(mesh.mainColor * 0.65 + SIMD3(0.35, 0.05, 0.12), SIMD3(repeating: 0), SIMD3(repeating: 1))
        let lips = Toybox.lips(radius: mesh.eyeRadius * 0.32, color: lipColor)
        lips.simdPosition = mesh.mouth
        faceNode.addChildNode(lips)
        let blush = Toybox.blush()
        for side: Float in [-1, 1] {
            let cheek = SCNNode(geometry: SCNSphere(radius: CGFloat(mesh.eyeRadius * 0.38)))
            cheek.geometry?.materials = [blush]
            cheek.simdScale = SIMD3(1.2, 0.7, 0.2)
            cheek.simdPosition = mesh.mouth + SIMD3(side * mesh.eyeRadius * 1.6, mesh.eyeRadius * 0.25, 0.01)
            faceNode.addChildNode(cheek)
        }
        faceNode.simdScale = SIMD3(repeating: 0.001)

        // Starts flat on the canvas, exactly where it was drawn.
        let start = SIMD3<Float>(mesh.center.x, mesh.center.y, canvasZ + mesh.halfExtents.z * 0.8 + 0.02)
        position = Spring3(start)
        wanderTarget = start
        root.simdPosition = start
        squashNode.simdScale = squash.value
        squash.velocity = SIMD3(3, 3, 0)   // little "inhale" before it puffs up
    }

    var isGone: Bool { phase == .gone }

    /// Where the eyes are right now (they fly off when it pops).
    var eyeWorldPositions: [SIMD3<Float>] { eyes.map { $0.root.simdWorldPosition } }
    var currentEyeRadius: Float { eyeRadius * size.value }
    var isInteractive: Bool { phase == .alive }

    // MARK: Reactions

    /// Bumped by a fish or a hand: bounce away, squash, look surprised.
    @discardableResult
    func poke(from point: SIMD3<Float>, strength: Float) -> Bool {
        guard phase == .alive, boingCooldown <= 0 else { return false }
        boingCooldown = 0.45
        var away = position.value - point
        away.z *= 0.3
        let dir = simd_length(away) > 1e-4 ? simd_normalize(away) : SIMD3(0, 1, 0)
        position.velocity += dir * (1.2 + strength * 1.5)
        squash.velocity += SIMD3(-4, 5, -2) * (0.6 + strength * 0.4)
        spinVelocity += (dir.x >= 0 ? 1 : -1) * (4 + strength * 4)
        surprised = 0.6
        return true
    }

    /// Scrubbed by the starfish: big swell, then POP.
    func pop() {
        guard phase == .alive || phase == .forming else { return }
        phase = .popping
        popTime = 0
        squash.velocity += SIMD3(6, 6, 6)
        surprised = 1
    }

    /// Too many friends: this one floats up and away like a lost balloon.
    func leave() {
        guard phase == .alive || phase == .forming else { return }
        phase = .leaving
        position.velocity += SIMD3(0, 0.6, 0)
    }

    // MARK: Per frame

    /// - Returns: true on the frame the pop happens (spawn confetti/sound).
    func update(dt: Float, beatPulse: Float, lookAt: SIMD3<Float>?, halfSize: SIMD2<Float>, cameraY: Float) -> Bool {
        age += dt
        boingCooldown -= dt
        surprised = max(0, surprised - dt)
        var popped = false

        switch phase {
        case .forming:
            // Inflate: depth springs from flat to full with a big overshoot.
            squash.step(to: SIMD3(1, 1, 1), stiffness: 70, damping: 5.5, dt: dt)
            if age > 0.35 {
                facePresence.step(to: 1, stiffness: 260, damping: 11, dt: dt)
            }
            // Puff up at drawing size, then "boop" down to a cute size as it lifts off.
            size.step(to: age > 0.55 ? Self.finalSize : 1, stiffness: 90, damping: 9, dt: dt)
            if age > 1.1 {
                phase = .alive
                pickWanderTarget(halfSize: halfSize, cameraY: cameraY)
            }
            position.step(to: wanderTarget, stiffness: 20, damping: 9, dt: dt)

        case .alive:
            size.step(to: Self.finalSize, stiffness: 90, damping: 9, dt: dt)
            nextWander -= dt
            if nextWander <= 0 || simd_distance(position.value, wanderTarget) < 0.15 {
                pickWanderTarget(halfSize: halfSize, cameraY: cameraY)
            }
            // Slow, floaty steering plus a gentle bob.
            position.step(to: wanderTarget, stiffness: 2.2, damping: 2.4, dt: dt)
            let beat = beatPulse * 0.08
            squash.step(to: SIMD3(1 + beat * 0.6, 1 - beat, 1 + beat * 0.4), stiffness: 160, damping: 7, dt: dt)
            facePresence.step(to: 1, stiffness: 260, damping: 11, dt: dt)

        case .leaving:
            position.velocity.y += dt * 1.2
            position.value += position.velocity * dt
            squash.step(to: SIMD3(0.92, 1.1, 0.92), stiffness: 60, damping: 6, dt: dt)
            if position.value.y > cameraY + halfSize.y + radius + 0.5 { phase = .gone }

        case .popping:
            // Swell and tremble, then burst.
            popTime += dt
            squash.step(to: SIMD3(1.45, 1.45, 1.45), stiffness: 300, damping: 8, dt: dt)
            squash.value += SIMD3(Float.random(in: -0.03...0.03), Float.random(in: -0.03...0.03), 0)
            if popTime > 0.2 {
                phase = .gone
                popped = true
            }

        case .gone:
            break
        }

        // Personality: wiggle, sway, turn to show off its 3D shape.
        spinVelocity *= exp(-dt * 2.5)
        spinAngle += spinVelocity * dt
        let t = age + seed
        let v = position.velocity
        let sway = sin(t * 0.9) * 0.35 + spinAngle
        let roll = sin(t * 1.9) * 0.1 - v.x * 0.15
        let nod = sin(t * 1.3) * 0.08 + v.y * 0.1
        root.simdEulerAngles = SIMD3(nod, sway, roll)
        root.simdPosition = position.value + SIMD3(0, phase == .alive ? sin(t * 1.7) * 0.05 : 0, 0)
        squashNode.simdScale = squash.value * size.value
        Toybox.setWobble(bodyMaterial, 0.01 + beatPulse * 0.012 + (surprised > 0 ? 0.015 : 0)
                         + (phase == .popping ? 0.04 : 0))

        // Eyes: blink, follow your hands, go wide when surprised.
        if age - blinkStart > nextBlink {
            blinkStart = age
            nextBlink = Float.random(in: 2.2...5.5)
        }
        let lid = surprised > 0 ? 1.0 : Toybox.blinkScale(age - blinkStart)
        let wide: Float = surprised > 0 ? 1.25 : 1
        var look = SIMD2<Float>(sin(t * 0.6) * 0.4, 0)
        if let lookAt {
            let d = lookAt - position.value
            look = SIMD2(d.x, d.y) * 1.2
        }
        for eye in eyes {
            eye.root.simdScale = SIMD3(wide, lid * wide, 1)
            Toybox.look(eye, toward: look)
        }
        faceNode.simdScale = SIMD3(repeating: max(facePresence.value, 0.001))
        return popped
    }

    private func pickWanderTarget(halfSize: SIMD2<Float>, cameraY: Float) {
        let mx = max(halfSize.x * 0.82 - radius * 0.6, 0.2)
        let my = max(halfSize.y * 0.7 - radius * 0.6, 0.2)
        wanderTarget = SIMD3(Float.random(in: -mx...mx),
                             cameraY + Float.random(in: -my...my),
                             Float.random(in: 0.6...1.4))
        nextWander = Float.random(in: 3...6)
    }

    /// Soft push so creatures don't overlap.
    func separate(from other: Creature, dt: Float) {
        let d = position.value - other.position.value
        let dist = simd_length(d)
        let minDist = (radius + other.radius) * 0.75
        guard dist < minDist, dist > 1e-4 else { return }
        let push = d / dist * (minDist - dist) * 2.5 * dt
        position.velocity += push
    }
}
