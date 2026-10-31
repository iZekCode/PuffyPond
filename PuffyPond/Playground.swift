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
    var hasDrawing = false
    var creatureCount = 0
    var previewHands: [[CGPoint]] = []
    var imageAspect: CGFloat = 4.0 / 3.0
    var pointerErases = false
    var buddyColors: [Int] = [0, 1]
    var buddyKinds: [CritterKind] = [.octopus, .seahorse]
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
    @ObservationIgnored private var critterPots: [CritterPot] = []
    /// What you actually see: wet, textured paint on the canvas.
    @ObservationIgnored private let paintLayer = PaintLayer(center: SIMD2(0, 0.1), size: Playground.canvasSize,
                                                            z: Playground.canvasZ + 0.0015)
    @ObservationIgnored private var lastStamp: [Int: SIMD2<Float>] = [:]
    @ObservationIgnored private var frameDT: Float = 1.0 / 60.0
    @ObservationIgnored private var lastGurgle: [Int: Double] = [:]
    @ObservationIgnored private var flashCounter = 0
    @ObservationIgnored private var shake: Float = 0
    @ObservationIgnored private let canvasNode = SCNNode()

    // Layout
    @ObservationIgnored private var aspect: Float = 16.0 / 10.0
    @ObservationIgnored private var cameraDistance: Float = 7
    @ObservationIgnored private let cameraY: Float = 0.1
    @ObservationIgnored private let tanHalfFOV = Float(tan(17.0 * Double.pi / 180))
    /// A big canvas (≈ 1.8× wider than before) — lots of room for broad arm strokes.
    static let canvasSize = SIMD2<Float>(6.4, 4.0)
    static let canvasZ: Float = 0.04            // front face of the canvas
    /// The pot and bubble columns sit just outside the canvas's left and right edges.
    static let shelfX: Float = canvasSize.x * 0.5 + 0.38
    static let shelfSpacing: Float = 0.62
    static let strokeRadius: Float = 0.085

    // Timing
    @ObservationIgnored private var lastTime: Double = 0
    @ObservationIgnored private var clock: Float = 0
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
        // A painter's studio: soft window light in an out-of-focus room.
        scene.background.contents = Studio.backdrop()
        scene.background.intensity = 1.7          // the room photo, brought up to the camera's exposure
        scene.lightingEnvironment.contents = Studio.environment()
        scene.lightingEnvironment.intensity = 1.1

        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.zNear = 0.1
        camera.zFar = 50
        // Photographic look: tone-mapped HDR, contact shadows, a soft lens vignette and a hint of bloom.
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.35
        camera.minimumExposure = -2
        camera.maximumExposure = 2
        camera.screenSpaceAmbientOcclusionIntensity = 0.6
        camera.screenSpaceAmbientOcclusionRadius = 0.25
        camera.vignettingIntensity = 0.35
        camera.vignettingPower = 0.9
        camera.bloomIntensity = 0.12
        camera.bloomThreshold = 0.95
        camera.bloomBlurRadius = 8
        cameraNode.camera = camera
        cameraNode.simdPosition = SIMD3(0, cameraY, cameraDistance)
        scene.rootNode.addChildNode(cameraNode)

        // Window light from the upper left: a warm spot that rakes across the canvas (bright on the left,
        // falling off to the right) so every ridge of paint shows, with soft shadows from the critters.
        let key = SCNLight()
        key.type = .spot
        key.intensity = 1050
        key.color = PlatformColor(red: 1, green: 0.95, blue: 0.88, alpha: 1)
        key.spotInnerAngle = 30
        key.spotOuterAngle = 95
        key.attenuationStartDistance = 4
        key.attenuationEndDistance = 22
        key.attenuationFalloffExponent = 1.2
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 14
        key.shadowSampleCount = 24
        key.shadowColor = PlatformColor(red: 0.12, green: 0.1, blue: 0.14, alpha: 0.45)
        key.shadowMapSize = CGSize(width: 4096, height: 4096)
        key.zNear = 1
        key.zFar = 30
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = SIMD3(-6.5, 4.5, 6)
        keyNode.simdLook(at: SIMD3(0.8, 0, 0))
        scene.rootNode.addChildNode(keyNode)

        // Cool bounce light from the room.
        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 260
        fill.color = PlatformColor(red: 0.9, green: 0.93, blue: 1, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        // Stretched linen canvas (deep, like a gallery-wrapped canvas) on a wooden studio easel.
        let size = Self.canvasSize
        let linen = Studio.canvasMaterial(repeats: size / Studio.weaveTileSize)
        let depth: Float = 0.16
        let board = Toybox.node(SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(depth),
                                       chamferRadius: 0.012), linen, at: SIMD3(0, 0, Self.canvasZ - depth / 2))
        canvasNode.addChildNode(board)
        let woodAlong = Studio.woodMaterial(grainAlongV: true)     // upright beams
        let woodAcross = Studio.woodMaterial(grainAlongV: false)   // horizontal beams
        func beam(_ w: Float, _ h: Float, _ d: Float, at p: SIMD3<Float>, tilt: Float = 0) {
            let n = Toybox.node(SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: 0.012),
                                h > w ? woodAlong : woodAcross, at: p)
            n.simdEulerAngles = SIMD3(0, 0, tilt)
            canvasNode.addChildNode(n)
        }
        let back = Self.canvasZ - depth - 0.06
        beam(0.14, 8.4, 0.1, at: SIMD3(0, -0.6, back))                                   // mast
        for side: Float in [-1, 1] {                                                       // splayed front legs
            beam(0.12, 7.2, 0.09, at: SIMD3(side * 1.25, -1.6, back - 0.04), tilt: side * 0.33)
        }
        beam(size.x + 0.5, 0.12, 0.3, at: SIMD3(0, -size.y * 0.5 - 0.06, Self.canvasZ - 0.04))   // tray
        beam(size.x + 0.5, 0.1, 0.05, at: SIMD3(0, -size.y * 0.5 + 0.02, Self.canvasZ + 0.1))    // tray lip
        beam(0.6, 0.16, 0.26, at: SIMD3(0, size.y * 0.5 + 0.06, Self.canvasZ - 0.06))           // top clamp
        canvasNode.simdPosition = SIMD3(0, 0.1, 0)
        scene.rootNode.addChildNode(canvasNode)

        scene.rootNode.addChildNode(paintLayer.node)
        // Two columns just outside the canvas, so dipping never smears the painting:
        // paint pots down the right (rub a critter in one to pick up its color),
        // critter bubbles down the left (rub one to become that brush animal).
        func columnY(_ k: Int, of count: Int) -> Float {
            0.1 + (Float(count - 1) / 2 - Float(k)) * Self.shelfSpacing
        }
        for k in 0..<Paint.colors.count {
            let pot = PaintPot(colorIndex: k, at: SIMD3(Self.shelfX, columnY(k, of: Paint.colors.count), 0.3))
            scene.rootNode.addChildNode(pot.root)
            pots.append(pot)
        }
        for (k, kind) in CritterKind.allCases.enumerated() {
            let pot = CritterPot(kind: kind, at: SIMD3(-Self.shelfX, columnY(k, of: CritterKind.allCases.count), 0.3))
            scene.rootNode.addChildNode(pot.root)
            scene.rootNode.addChildNode(pot.resident.root)
            critterPots.append(pot)
        }


        for slot in 0..<2 {
            let start = SIMD3<Float>(slot == 0 ? -1.2 : 1.2, -0.9, 0.5)
            let buddy = Buddy(slot: slot, colorIndex: slot == 0 ? 0 : 1, kind: buddyKinds[slot], start: start)
            scene.rootNode.addChildNode(buddy.critter.root)
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
        let needHalfW = (Self.shelfX + PaintPot.radius + 0.12) * 1.02   // canvas plus the two pot columns
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

            let buddyZ: Float = 0.42
            let target: SIMD3<Float>
            if let hand {
                target = worldPoint(hand.position, z: buddyZ)
            } else {
                // Idle: swim lazy loops so the buddies always feel alive.
                let h = halfSize(atZ: buddyZ)
                let t = clock * 0.35 + Float(buddy.slot) * 3.1
                target = SIMD3(sin(t) * h.x * 0.6, cameraY - h.y * 0.62 + sin(t * 2.3) * 0.15, buddyZ)
            }
            buddy.critter.update(dt: dt, target: target, visible: mode != .erase, painting: mode == .paint,
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
            let rubbers = buddies.filter { $0.rubbingPot == .color(pot.colorIndex) }
            let progress = rubbers.map(\.rubAmount).max() ?? 0
            if progress > 0 { rubbing = true }
            let wearing = buddies.filter { $0.colorIndex == pot.colorIndex }.count
            pot.update(dt: dt, beatPulse: beatPulse, rubProgress: min(progress, 1), selectedCount: wearing)
        }
        for pot in critterPots {
            let rubbers = buddies.filter { $0.rubbingPot == .critter(pot.kind) }
            let progress = rubbers.map(\.rubAmount).max() ?? 0
            if progress > 0 { rubbing = true }
            let wearers = buddies.filter { $0.critter.kind == pot.kind }
            pot.update(dt: dt, beatPulse: beatPulse, rubProgress: min(progress, 1), selectedCount: wearers.count,
                       color: wearers.first?.color)
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
                    buddy.critter.react(.surprised, for: 0.5)
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
                for buddy in buddies { buddy.critter.react(.surprised, for: 0.6) }
            }
        }
        for creature in creatures where creature.isGone {
            creature.root.removeFromParentNode()
        }
        creatures.removeAll { $0.isGone }

        effects.update(dt: dt)
        shake = max(0, shake - dt * 4)
        let jolt = shake * shake * 0.05
        cameraNode.simdPosition = SIMD3(Float.random(in: -jolt...jolt), cameraY + Float.random(in: -jolt...jolt),
                                        cameraDistance)

        // Music swells with how much you move.
        energy += (min(movement / 3, 1) - energy) * min(1, dt * 1.5)
        audio.update(energy: energy, now: now)

        publishHUD(dt: dt, hands: hands, drawing: drawingNow, erasing: erasingNow, rubbing: rubbing)
    }

    private func panFor(_ x: Float) -> Float {
        max(-1, min(1, x / max(halfSize(atZ: 0.5).x, 0.1)))
    }

    // MARK: - Painting

    private func paint(with buddy: Buddy, now: Double) {
        let slot = buddy.slot
        let p3 = buddy.critter.position.value
        let half = Self.canvasSize * 0.5 - SIMD2(repeating: Self.strokeRadius)
        let center = SIMD2<Float>(0, 0.1)
        var p = SIMD2(p3.x, p3.y)
        // Only a little slack sideways: reaching for a pot or bubble beside the canvas shouldn't paint.
        let onCanvas = abs(p.x - center.x) <= half.x + 0.05 && abs(p.y - center.y) <= half.y + 0.12
        guard onCanvas, !transforming else {
            finishStroke(slot: slot)
            return
        }
        p = simd_clamp(p, center - half, center + half)

        // Lay real paint every frame, the way this brush animal paints.
        let dabs = buddy.critter.dabs(from: lastStamp[slot] ?? p, to: p, radius: Self.strokeRadius,
                                      speed: buddy.critter.speed)
        lay(dabs, color: buddy.color, seed: Float(slot) * 13.7 + Float(strokes.count) * 2.3)
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
            buddy.critter.gulp()
            audio.play(.blip, a: (p.y - center.y) / Self.canvasSize.y + 0.5, pan: panFor(p.x))
        }
        if strokes.reduce(0, { $0 + $1.points.count }) > 2600 { bringToLife(reason: .full) }
    }

    private func lay(_ dabs: [BrushDab], color: SIMD3<Float>, seed: Float) {
        for (k, dab) in dabs.enumerated() {
            paintLayer.stamp(from: dab.from, to: dab.to, radius: dab.radius, color: color, speed: dab.speed,
                             seed: seed + Float(k) * 5.1, style: dab.style)
        }
    }

    private func finishStroke(slot: Int) {
        if activeStroke[slot] != nil, slot < buddies.count {
            let buddy = buddies[slot]
            buddy.critter.react(.happy, for: 0.7)   // proud of that line
            // Some brushes paint when you let go (the pufferfish bursts).
            lay(buddy.critter.released(), color: buddy.color, seed: Float(slot) * 7.7 + Float(strokes.count))
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

    enum LifeReason { case clap, full, button }

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
        for buddy in buddies { buddy.critter.react(.happy, for: 1.2) }

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

    /// Dip a critter into a pot and rub/swipe: it soaks up the color (faster the more you rub).
    /// Rub it in a critter bubble instead and it turns into that brush animal.
    private func rubPots(_ buddy: Buddy, dt: Float, now: Double) {
        func stop() {
            buddy.rubbingPot = nil
            buddy.rubAmount = 0
            buddy.critter.colorPreview = nil
        }
        guard buddy.mode == .swim || buddy.mode == .paint else { return stop() }
        let p = buddy.critter.position.value
        func near(_ c: SIMD3<Float>) -> Bool {
            simd_distance(SIMD2(p.x, p.y), SIMD2(c.x, c.y + 0.04)) < PaintPot.radius + 0.14
        }
        let target: PotTarget
        let potPosition: SIMD3<Float>
        if let pot = pots.first(where: { near($0.root.simdPosition) }), pot.colorIndex != buddy.colorIndex {
            target = .color(pot.colorIndex)
            potPosition = pot.root.simdPosition
        } else if let pot = critterPots.first(where: { near($0.root.simdPosition) }), pot.kind != buddy.critter.kind {
            target = .critter(pot.kind)
            potPosition = pot.root.simdPosition
        } else {
            return stop()
        }
        if buddy.rubbingPot != target {
            buddy.rubbingPot = target
            buddy.rubAmount = 0
            bouncePot(target, 0.6)
        }
        // Slow animals (snail, jelly) can't rub fast, so just sitting in the pot counts for a lot too.
        buddy.rubAmount += dt * 0.9 + min(buddy.critter.speed, 3) * dt * 0.9
        let progress = min(buddy.rubAmount, 1)
        if case .color(let index) = target { buddy.critter.colorPreview = (Paint.colors[index], progress * 0.85) }
        let pan = panFor(potPosition.x)
        if now - (lastGurgle[buddy.slot] ?? 0) > 0.11 {
            lastGurgle[buddy.slot] = now
            audio.play(.gurgle, a: progress, pan: pan)
        }
        guard progress >= 1 else { return }
        buddy.rubbingPot = nil
        buddy.rubAmount = 0
        bouncePot(target, 1.5)
        switch target {
        case .color(let index):
            buddy.pick(index)
            effects.colorSplash(at: potPosition + SIMD3(0, 0.15, 0.1), color: Paint.colors[index])
            audio.play(.pick, a: Float(index), pan: pan)
            flashCounter += 1
            colorFlash = ColorFlash(slot: buddy.slot, colorIndex: index, id: flashCounter)
        case .critter(let kind):
            finishStroke(slot: buddy.slot)
            let old = buddy.become(kind)
            old.root.removeFromParentNode()
            scene.rootNode.addChildNode(buddy.critter.root)
            effects.colorSplash(at: potPosition + SIMD3(0, 0.15, 0.1), color: buddy.color)
            audio.play(.swap, pan: pan)
        }
    }

    private func bouncePot(_ target: PotTarget, _ strength: Float) {
        switch target {
        case .color(let index): pots.first { $0.colorIndex == index }?.bounce(strength)
        case .critter(let kind): critterPots.first { $0.kind == kind }?.bounce(strength)
        }
    }

    private func publishHUD(dt: Float, hands: [HandState], drawing: Bool, erasing: Bool, rubbing: Bool) {
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
        let drawingExists = !strokes.isEmpty
        if drawingExists != hasDrawing { hasDrawing = drawingExists }
        if creatures.count != creatureCount { creatureCount = creatures.count }
        let colors = buddies.map(\.colorIndex)
        if colors != buddyColors { buddyColors = colors }
        let kinds = buddies.map(\.critter.kind)
        if kinds != buddyKinds { buddyKinds = kinds }

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
