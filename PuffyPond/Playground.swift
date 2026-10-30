import SwiftUI
import SceneKit
import Observation
import QuartzCore
import simd

nonisolated enum CameraStatus: Equatable { case starting, running, denied, unavailable }

nonisolated enum Hint: Equatable {
    case starting, raiseHands, swimming, pickingColor, drawing, erasing, clapToLife, transforming, touchMode
}

/// "You picked a color" moment for the HUD.
nonisolated struct ColorFlash: Equatable {
    let slot: Int
    let colorIndex: Int
    let id: Int
}

/// The whole toy: the 3D world, the two hand buddies, puffy strokes, living creatures, and the groove.
@Observable
final class Playground {
    // MARK: HUD state
    var cameraStatus: CameraStatus = .starting
    var showGuide = true
    var showCameraPreview = true
    var musicOn = true
    var hint: Hint = .starting
    var lifeProgress: Double = 0
    var hasDrawing = false
    var creatureCount = 0
    var previewHands: [[CGPoint]] = []
    var imageAspect: CGFloat = 4.0 / 3.0
    var pointerErases = false
    var fishColors: [Int] = [0, 1]
    var colorFlash: ColorFlash?

    // MARK: World
    @ObservationIgnored let effects = Effects(scene: SCNScene())
    var scene: SCNScene { effects.scene }
    @ObservationIgnored let cameraNode = SCNNode()
    @ObservationIgnored let audio = GrooveEngine()
    @ObservationIgnored private let input = HandInput()
    @ObservationIgnored private let frameDriver = FrameDriver()
    @ObservationIgnored private var buddies: [Buddy] = []
    @ObservationIgnored private var strokes: [Stroke] = []
    @ObservationIgnored private var activeStroke: [Int: Stroke] = [:]
    @ObservationIgnored private var lastBead: [Int: SIMD2<Float>] = [:]
    @ObservationIgnored private var blipDistance: [Int: Float] = [:]
    @ObservationIgnored private var creatures: [Creature] = []
    @ObservationIgnored private var pots: [PaintPot] = []
    /// What you actually see: wet, textured paint on the canvas.
    @ObservationIgnored private let paintLayer = PaintLayer(center: SIMD2(0, 0.1), size: Playground.canvasSize,
                                                            z: Playground.canvasZ + 0.0015)
    @ObservationIgnored private var lastStamp: [Int: SIMD2<Float>] = [:]
    @ObservationIgnored private var frameDT: Float = 1.0 / 60.0
    /// Paint stops above the pots so dipping a fish never smears the bottom of the canvas.
    @ObservationIgnored private var paintFloorY: Float = -10
    @ObservationIgnored private var lastGurgle: [Int: Double] = [:]
    @ObservationIgnored private var flashCounter = 0
    @ObservationIgnored private var shake: Float = 0
    @ObservationIgnored private let canvasNode = SCNNode()
    @ObservationIgnored private var canvasSquash = Spring3(SIMD3(1, 1, 1))

    // Layout
    @ObservationIgnored private var aspect: Float = 16.0 / 10.0
    @ObservationIgnored private var cameraDistance: Float = 7
    @ObservationIgnored private let cameraY: Float = 0.1
    @ObservationIgnored private let tanHalfFOV = Float(tan(17.0 * Double.pi / 180))
    static let canvasSize = SIMD2<Float>(3.6, 2.4)
    static let canvasZ: Float = 0.04            // front face of the canvas
    static let strokeRadius: Float = 0.085

    // Timing
    @ObservationIgnored private var lastTime: Double = 0
    @ObservationIgnored private var clock: Float = 0
    @ObservationIgnored private var lastDrawActivity: Double = 0
    @ObservationIgnored private var transforming = false
    @ObservationIgnored private var lastSqueak: Double = 0
    @ObservationIgnored private var lastBeatIndex = -1
    @ObservationIgnored private var energy: Float = 0
    @ObservationIgnored private var handsSeenTime: Float = 0

    // Pointer (mouse/touch) fallback acts as the left buddy.
    @ObservationIgnored private var pointer: SIMD2<Float>?
    @ObservationIgnored private var pointerPrevious: SIMD2<Float>?

    init() {
        buildWorld()
        input.onClap = { [weak self] in self?.bringToLife(reason: .clap) }
        frameDriver.onFrame = { [weak self] dt in self?.tick(dt: Float(dt)) }
    }

    func start() {
        audio.start()
        frameDriver.start()
    }

    func pause() {
        audio.pause()
    }

    func toggleMusic() {
        musicOn.toggle()
        audio.setMuted(!musicOn)
    }

    // MARK: - World building

    private func buildWorld() {
        scene.background.contents = Toybox.backdrop()
        scene.lightingEnvironment.contents = Toybox.environment()
        scene.lightingEnvironment.intensity = 1.3

        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.zNear = 0.1
        camera.zFar = 50
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.simdPosition = SIMD3(0, cameraY, cameraDistance)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 950
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 10
        key.shadowSampleCount = 16
        key.shadowColor = PlatformColor(white: 0, alpha: 0.28)
        key.orthographicScale = 5
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdEulerAngles = SIMD3(-0.55, -0.45, 0)
        keyNode.simdPosition = SIMD3(-2, 3, 5)
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 380
        fill.color = PlatformColor(red: 1, green: 0.96, blue: 0.92, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        // Easel + canvas
        let size = Self.canvasSize
        let canvasMaterial = Toybox.plain(SIMD3(1, 1, 1), roughness: 0.85)
        canvasMaterial.diffuse.contents = Toybox.canvasTexture()
        canvasMaterial.diffuse.wrapS = .repeat
        canvasMaterial.diffuse.wrapT = .repeat
        canvasMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(6, 4, 1)
        let board = Toybox.node(SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: 0.08, chamferRadius: 0.02),
                                canvasMaterial)
        canvasNode.addChildNode(board)
        let wood = Toybox.plain(SIMD3(0.86, 0.68, 0.45), roughness: 0.7)
        for x: Float in [-1.1, 1.1] {
            let leg = Toybox.node(SCNCylinder(radius: 0.05, height: 2.6), wood,
                                  at: SIMD3(x, -size.y * 0.5 - 0.9, -0.12))
            leg.simdEulerAngles = SIMD3(0, 0, x > 0 ? -0.12 : 0.12)
            canvasNode.addChildNode(leg)
        }
        let ledge = Toybox.node(SCNBox(width: CGFloat(size.x * 0.8), height: 0.08, length: 0.2, chamferRadius: 0.03), wood,
                                at: SIMD3(0, -size.y * 0.5 - 0.04, 0.04))
        canvasNode.addChildNode(ledge)
        canvasNode.simdPosition = SIMD3(0, 0.1, 0)
        scene.rootNode.addChildNode(canvasNode)

        // Paint pots along the bottom: rub a fish in one to pick up its color.
        let potY = 0.1 - size.y * 0.5 + 0.26
        paintFloorY = potY + PaintPot.radius + 0.1
        scene.rootNode.addChildNode(paintLayer.node)
        for k in 0..<Paint.colors.count {
            let x = (Float(k) - Float(Paint.colors.count - 1) / 2) * 0.56
            let pot = PaintPot(colorIndex: k, at: SIMD3(x, potY, 0.3))
            scene.rootNode.addChildNode(pot.root)
            pots.append(pot)
        }

        scene.rootNode.addChildNode(Toybox.ambientBubbles())

        for slot in 0..<2 {
            let start = SIMD3<Float>(slot == 0 ? -1.2 : 1.2, -0.9, 0.5)
            let buddy = Buddy(slot: slot, colorIndex: slot == 0 ? 0 : 1, start: start)
            scene.rootNode.addChildNode(buddy.fish.root)
            scene.rootNode.addChildNode(buddy.starfish.root)
            buddies.append(buddy)
        }
    }

    /// Fit the canvas (plus room for creatures) into any window shape.
    func layout(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = Float(size.width / size.height)
        // The canvas nearly fills the window.
        let needHalfH = Self.canvasSize.y * 0.5 * 1.06
        let needHalfW = Self.canvasSize.x * 0.5 * 1.04
        cameraDistance = max(needHalfH / tanHalfFOV, needHalfW / (tanHalfFOV * aspect))
        cameraNode.simdPosition = SIMD3(0, cameraY, cameraDistance)
    }

    /// Visible half-size of the view at depth z.
    private func halfSize(atZ z: Float) -> SIMD2<Float> {
        let halfH = (cameraDistance - z) * tanHalfFOV
        return SIMD2(halfH * aspect, halfH)
    }

    /// View UV (0…1, y down) → point in the world at depth z.
    private func worldPoint(_ uv: SIMD2<Float>, z: Float) -> SIMD3<Float> {
        let h = halfSize(atZ: z)
        return SIMD3((uv.x * 2 - 1) * h.x, cameraY + (1 - uv.y * 2) * h.y, z)
    }

    // MARK: - Input

    func ingest(_ frame: HandFrame) {
        input.ingest(frame)
        let aspect = CGFloat(frame.imageAspect)
        if abs(aspect - imageAspect) > 0.001 { imageAspect = aspect }
        if showCameraPreview {
            previewHands = frame.hands.map { hand in
                hand.joints.compactMap { joint in
                    joint.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                }
            }
        }
    }

    func pointerBegan(_ uv: SIMD2<Float>) {
        pointer = uv
        pointerPrevious = uv
    }

    func pointerMoved(_ uv: SIMD2<Float>) { pointer = uv }

    func pointerEnded() {
        pointer = nil
        pointerPrevious = nil
    }

    // MARK: - Frame loop

    private func tick(dt rawDT: Float) {
        let dt = min(max(rawDT, 1.0 / 240.0), 1.0 / 20.0)
        frameDT = dt
        let now = CACurrentMediaTime()
        clock += dt
        let beat = audio.beat
        let beatFraction = Float(beat - beat.rounded(.down))
        let beatPulse = exp(-beatFraction * 6)
        let beatIndex = Int(beat.rounded(.down))
        let onBeat = beatIndex != lastBeatIndex
        lastBeatIndex = beatIndex

        var hands = input.advance(dt: dt, now: now)
        if let p = pointer {
            let previous = pointerPrevious ?? p
            hands.removeAll { $0.slot == 0 }
            hands.append(HandState(slot: 0, pose: pointerErases ? .fist : .pinch, position: p,
                                   velocity: (p - previous) / dt, tracking: true, isPointer: true))
            pointerPrevious = p
        }

        var movement: Float = 0
        var drawingNow = false
        var erasingNow = false
        for buddy in buddies {
            let hand = hands.first { $0.slot == buddy.slot && $0.tracking }
            let mode: BuddyMode
            switch hand?.pose {
            case nil: mode = .idle
            case .open?: mode = .swim
            case .pinch?: mode = .paint
            case .fist?: mode = .erase
            }
            if buddy.setMode(mode) {
                audio.play(.swap, pan: buddy.slot == 0 ? -0.5 : 0.5)
            }
            if mode != .paint { finishStroke(slot: buddy.slot) }

            let fishZ: Float = 0.42
            let target: SIMD3<Float>
            if let hand {
                target = worldPoint(hand.position, z: fishZ)
            } else {
                // Idle: swim lazy loops so the buddies always feel alive.
                let h = halfSize(atZ: fishZ)
                let t = clock * 0.35 + Float(buddy.slot) * 3.1
                target = SIMD3(sin(t) * h.x * 0.6, cameraY - h.y * 0.62 + sin(t * 2.3) * 0.15, fishZ)
            }
            buddy.fish.update(dt: dt, target: target, visible: mode != .erase, painting: mode == .paint,
                              beatPulse: beatPulse)
            buddy.starfish.update(dt: dt, target: SIMD3(target.x, target.y, 0.3), visible: mode == .erase,
                                  beatPulse: beatPulse)

            movement += min(buddy.toolSpeed, 4) * (hand == nil ? 0 : 1)
            switch mode {
            case .paint:
                drawingNow = true
                paint(with: buddy, now: now)
            case .erase:
                erasingNow = true
                erase(with: buddy, now: now)
            case .idle, .swim:
                break
            }
            rubPots(buddy, dt: dt, now: now)
        }
        var rubbing = false
        for pot in pots {
            let rubbers = buddies.filter { $0.rubbingPot == pot.colorIndex }
            let progress = rubbers.map(\.rubAmount).max() ?? 0
            if progress > 0 { rubbing = true }
            let wearing = buddies.filter { $0.colorIndex == pot.colorIndex }.count
            pot.update(dt: dt, beatPulse: beatPulse, rubProgress: min(progress, 1), selectedCount: wearing)
        }

        // Bump creatures with your buddies.
        for buddy in buddies where buddy.mode != .idle {
            let tool = buddy.toolPosition
            for creature in creatures where creature.isInteractive {
                let d = simd_distance(SIMD2(tool.x, tool.y), SIMD2(creature.position.value.x, creature.position.value.y))
                guard d < creature.radius * 0.85 + 0.12 else { continue }
                if buddy.mode == .erase {
                    creature.pop()
                } else if buddy.toolSpeed > 0.4,
                          creature.poke(from: tool, strength: min(buddy.toolSpeed / 3, 1)) {
                    audio.play(.boing, a: min(creature.radius / 1.2, 1), pan: panFor(creature.position.value.x))
                    buddy.fish.react(.surprised, for: 0.5)
                }
            }
        }

        paintLayer.update(dt: dt)

        // Creatures live their lives.
        let bounds = halfSize(atZ: 1)
        let lookTarget = buddies.filter { $0.mode != .idle }.first?.toolPosition
        for i in creatures.indices {
            for j in creatures.indices where j != i {
                creatures[i].separate(from: creatures[j], dt: dt)
            }
        }
        for creature in creatures {
            if creature.update(dt: dt, beatPulse: beatPulse, lookAt: lookTarget, halfSize: bounds, cameraY: cameraY) {
                effects.pop(at: creature.position.value, radius: creature.radius, colors: creature.palette,
                            eyeRadius: creature.currentEyeRadius, eyes: creature.eyeWorldPositions)
                audio.play(.pop, pan: panFor(creature.position.value.x))
                audio.play(.sparkle)
                shake = 1
                for buddy in buddies { buddy.fish.react(.surprised, for: 0.6) }
            }
        }
        for creature in creatures where creature.isGone {
            creature.root.removeFromParentNode()
        }
        creatures.removeAll { $0.isGone }

        // Bring the drawing to life after a little pause.
        let idleFor = now - lastDrawActivity
        var progress: Double = 0
        if !strokes.isEmpty && !transforming && !drawingNow && !erasingNow {
            progress = min(max((idleFor - 0.8) / 2.2, 0), 1)
            if progress >= 1 { bringToLife(reason: .timeout) }
        }

        // Canvas and paint cards bounce on the beat.
        if onBeat { canvasSquash.velocity += SIMD3(0.6, -0.6, 0) * (0.4 + energy) }
        canvasSquash.step(to: SIMD3(1, 1, 1), stiffness: 300, damping: 14, dt: dt)
        canvasNode.simdScale = SIMD3(canvasSquash.value.x, canvasSquash.value.y, 1)
        effects.update(dt: dt)
        shake = max(0, shake - dt * 4)
        let jolt = shake * shake * 0.05
        cameraNode.simdPosition = SIMD3(Float.random(in: -jolt...jolt), cameraY + Float.random(in: -jolt...jolt),
                                        cameraDistance)

        // Music swells with how much you move.
        energy += (min(movement / 3, 1) - energy) * min(1, dt * 1.5)
        audio.update(energy: energy, now: now)

        publishHUD(dt: dt, hands: hands, drawing: drawingNow, erasing: erasingNow, rubbing: rubbing, progress: progress)
    }

    private func panFor(_ x: Float) -> Float {
        max(-1, min(1, x / max(halfSize(atZ: 0.5).x, 0.1)))
    }

    // MARK: - Painting

    private func paint(with buddy: Buddy, now: Double) {
        let slot = buddy.slot
        let p3 = buddy.fish.position.value
        let half = Self.canvasSize * 0.5 - SIMD2(repeating: Self.strokeRadius)
        let center = SIMD2<Float>(0, 0.1)
        var p = SIMD2(p3.x, p3.y)
        let onCanvas = abs(p.x - center.x) <= half.x + 0.25 && abs(p.y - center.y) <= half.y + 0.12
        guard onCanvas, !transforming, p.y > paintFloorY else {
            finishStroke(slot: slot)
            return
        }
        p = simd_clamp(p, center - half, center + half)

        // Lay real paint every frame along the fish's path.
        let speed = buddy.fish.speed
        paintLayer.stamp(from: lastStamp[slot] ?? p, to: p, radius: Self.strokeRadius,
                         color: buddy.color, speed: speed, seed: Float(slot) * 13.7 + Float(strokes.count) * 2.3)
        lastStamp[slot] = p

        let spacing = Self.strokeRadius * 0.6
        if let stroke = activeStroke[slot], let last = lastBead[slot] {
            let gap = simd_distance(p, last)
            guard gap >= spacing else { return }
            let steps = min(Int(gap / spacing), 12)
            for s in 1...steps {
                let q = last + (p - last) * (Float(s) / Float(steps))
                stroke.add(q, now: now)
            }
            lastBead[slot] = p
            blipDistance[slot, default: 0] += gap
            if blipDistance[slot, default: 0] > 0.16 {
                blipDistance[slot] = 0
                let height = (p.y - center.y) / Self.canvasSize.y + 0.5
                audio.play(.blip, a: height, pan: panFor(p.x))
            }
        } else {
            let stroke = Stroke(color: buddy.color, radius: Self.strokeRadius, surfaceZ: Self.canvasZ + Self.strokeRadius * 0.55)
            stroke.add(p, now: now)
            strokes.append(stroke)
            activeStroke[slot] = stroke
            lastBead[slot] = p
            buddy.fish.gulp()
            audio.play(.blip, a: (p.y - center.y) / Self.canvasSize.y + 0.5, pan: panFor(p.x))
        }
        lastDrawActivity = now
        if strokes.reduce(0, { $0 + $1.points.count }) > 2600 { bringToLife(reason: .full) }
    }

    private func finishStroke(slot: Int) {
        if activeStroke[slot] != nil, slot < buddies.count {
            buddies[slot].fish.react(.happy, for: 0.7)   // proud of that line
        }
        activeStroke[slot] = nil
        lastBead[slot] = nil
        lastStamp[slot] = nil
    }

    private func erase(with buddy: Buddy, now: Double) {
        let s = buddy.starfish.position.value
        let p = SIMD2(s.x, s.y)
        let r = Starfish.eraseRadius
        paintLayer.erase(at: p, radius: r, dt: frameDT)
        var erasedAny = false
        var newStrokes: [Stroke] = []
        for stroke in strokes {
            guard stroke.points.contains(where: { simd_distance($0.p, p) < r }) else {
                newStrokes.append(stroke)
                continue
            }
            erasedAny = true
            // Split into the runs that survive.
            var runs: [[StrokePoint]] = [[]]
            for point in stroke.points {
                if simd_distance(point.p, p) < r {
                    if !(runs.last?.isEmpty ?? true) { runs.append([]) }
                } else {
                    runs[runs.count - 1].append(point)
                }
            }
            runs.removeAll { $0.isEmpty }
            if let first = runs.first {
                stroke.replacePoints(first)
                newStrokes.append(stroke)
                for run in runs.dropFirst() {
                    let piece = Stroke(color: stroke.color, radius: stroke.radius, surfaceZ: stroke.surfaceZ)
                    piece.replacePoints(run)
                    scene.rootNode.addChildNode(piece.node)
                    newStrokes.append(piece)
                }
            } else {
                stroke.node.removeFromParentNode()
                for (slot, active) in activeStroke where active === stroke { activeStroke[slot] = nil }
            }
        }
        strokes = newStrokes
        if erasedAny {
            lastDrawActivity = now
            buddy.starfish.scrubbed()
            if now - lastSqueak > 0.09 {
                lastSqueak = now
                audio.play(.squeak, pan: panFor(p.x))
                Toybox.burst(in: scene, at: SIMD3(p.x, p.y, 0.2), color: SIMD3(1, 1, 1), count: 10, speed: 1.2,
                             size: 0.04, gravity: -1)
            }
        }
    }

    // MARK: - Bring the drawing to life

    enum LifeReason { case clap, timeout, full, button }

    func bringToLife(reason: LifeReason) {
        guard !transforming else { return }
        guard !strokes.isEmpty else {
            if reason == .clap { audio.play(.swap) }
            return
        }
        transforming = true
        let formed = strokes
        strokes = []
        activeStroke = [:]
        lastBead = [:]
        let input = formed.map { stroke in
            InflateStroke(points: stroke.points.map(\.p), radius: stroke.radius, color: stroke.color)
        }
        audio.play(.rise)
        // Anticipation: the strokes jiggle and swell before the reveal.
        for stroke in formed {
            stroke.node.runAction(.repeatForever(.sequence([
                .moveBy(x: 0.012, y: 0.008, z: 0.02, duration: 0.05),
                .moveBy(x: -0.012, y: -0.008, z: -0.02, duration: 0.05),
            ])), forKey: "shake")
        }
        paintLayer.trembling = true
        let started = CACurrentMediaTime()
        Task {
            let mesh = await Task.detached(priority: .userInitiated) { Inflator.inflate(input) }.value
            let waited = CACurrentMediaTime() - started
            if waited < 0.7 {
                try? await Task.sleep(nanoseconds: UInt64((0.7 - waited) * 1_000_000_000))
            }
            self.finishLife(mesh: mesh, formed: formed)
        }
    }

    private func finishLife(mesh: CreatureMesh?, formed: [Stroke]) {
        for stroke in formed {
            stroke.node.removeAction(forKey: "shake")
            stroke.node.runAction(.sequence([.fadeOut(duration: 0.18), .removeFromParentNode()]))
        }
        paintLayer.trembling = false
        paintLayer.dissolveAway()   // the paint lifts off the canvas and becomes the creature
        transforming = false
        lastDrawActivity = CACurrentMediaTime()
        guard let mesh else {
            audio.play(.fizzle)
            return
        }
        let creature = Creature(mesh: mesh, canvasZ: Self.canvasZ)
        scene.rootNode.addChildNode(creature.root)
        creatures.append(creature)
        let center = SIMD3<Float>(mesh.center.x, mesh.center.y, Self.canvasZ + 0.2)
        Toybox.confetti(in: scene, at: center)
        Toybox.burst(in: scene, at: center, color: SIMD3(1, 1, 0.85), count: 40, speed: 1.6, size: 0.035, gravity: 0.5)
        audio.play(.fanfare)
        for buddy in buddies { buddy.fish.react(.happy, for: 1.2) }
        canvasSquash.velocity += SIMD3(1.5, -1.5, 0)

        // Keep the pond lively but uncluttered: the oldest friend floats away.
        let living = creatures.filter { $0.phase == .alive || $0.phase == .forming }
        if living.count > 5 { living.first?.leave() }
    }

    func clearAll() {
        for stroke in strokes { stroke.node.removeFromParentNode() }
        strokes.removeAll()
        paintLayer.clear()
        activeStroke = [:]
        lastBead = [:]
        for creature in creatures { creature.pop() }
        audio.play(.pop)
    }

    // MARK: - HUD

    // MARK: - Paint pots

    /// Dip a fish into a pot and rub/swipe: it soaks up the color (faster the more you rub).
    private func rubPots(_ buddy: Buddy, dt: Float, now: Double) {
        guard buddy.mode == .swim || buddy.mode == .paint else {
            buddy.rubbingPot = nil
            buddy.rubAmount = 0
            buddy.fish.colorPreview = nil
            return
        }
        let p = buddy.fish.position.value
        let touching = pots.first { pot in
            let c = pot.root.simdPosition
            return simd_distance(SIMD2(p.x, p.y), SIMD2(c.x, c.y + 0.04)) < PaintPot.radius + 0.14
        }
        guard let pot = touching, pot.colorIndex != buddy.colorIndex else {
            buddy.rubbingPot = nil
            buddy.rubAmount = 0
            buddy.fish.colorPreview = nil
            return
        }
        if buddy.rubbingPot != pot.colorIndex {
            buddy.rubbingPot = pot.colorIndex
            buddy.rubAmount = 0
            pot.bounce(0.6)
        }
        buddy.rubAmount += dt * 0.6 + min(buddy.fish.speed, 3) * dt * 0.9
        let progress = min(buddy.rubAmount, 1)
        buddy.fish.colorPreview = (pot.color, progress * 0.85)
        let pan = panFor(pot.root.simdPosition.x)
        if now - (lastGurgle[buddy.slot] ?? 0) > 0.11 {
            lastGurgle[buddy.slot] = now
            audio.play(.gurgle, a: progress, pan: pan)
        }
        if progress >= 1 {
            buddy.pick(pot.colorIndex)
            buddy.rubbingPot = nil
            buddy.rubAmount = 0
            pot.bounce(1.5)
            effects.colorSplash(at: pot.root.simdPosition + SIMD3(0, 0.15, 0.1), color: pot.color)
            audio.play(.pick, a: Float(pot.colorIndex), pan: pan)
            flashCounter += 1
            colorFlash = ColorFlash(slot: buddy.slot, colorIndex: pot.colorIndex, id: flashCounter)
        }
    }

    private func publishHUD(dt: Float, hands: [HandState], drawing: Bool, erasing: Bool, rubbing: Bool,
                            progress: Double) {
        let next: Hint
        if transforming {
            next = .transforming
        } else if erasing {
            next = .erasing
        } else if drawing {
            next = .drawing
        } else if rubbing {
            next = .pickingColor
        } else if !strokes.isEmpty {
            next = .clapToLife
        } else if hands.contains(where: { $0.tracking && !$0.isPointer }) {
            next = .swimming
        } else if cameraStatus == .denied || cameraStatus == .unavailable {
            next = .touchMode
        } else if cameraStatus == .starting {
            next = .starting
        } else {
            next = .raiseHands
        }
        if next != hint { hint = next }
        let rounded = (progress * 30).rounded() / 30
        if rounded != lifeProgress { lifeProgress = rounded }
        let drawingExists = !strokes.isEmpty
        if drawingExists != hasDrawing { hasDrawing = drawingExists }
        if creatures.count != creatureCount { creatureCount = creatures.count }
        let colors = buddies.map(\.colorIndex)
        if colors != fishColors { fishColors = colors }

        let cameraHands = hands.filter { !$0.isPointer }
        if cameraHands.isEmpty {
            handsSeenTime = 0
        } else {
            handsSeenTime += dt
            if showGuide && handsSeenTime > 1.5 {
                withAnimation(.easeOut(duration: 0.4)) { showGuide = false }
            }
        }
    }
}
