import SwiftUI
import SceneKit
import Metal
import Observation
import QuartzCore
import simd

nonisolated enum CameraStatus: Equatable { case starting, running, denied, unavailable }

nonisolated enum Hint: Equatable {
    case starting, raiseHands, swimming, pickingColor, drawing, erasing, readyToHang, tracing, touchMode
}

/// "You picked a color" moment for the HUD.
nonisolated struct ColorFlash: Equatable {
    let slot: Int
    let colorIndex: Int
    let id: Int
}

/// The whole toy: the 3D world, the two hand buddies, wet paint on the canvas, and the groove.
@Observable
final class Playground {
    // MARK: HUD state
    var cameraStatus: CameraStatus = .starting
    var showGuide = true
    var showCameraPreview = true
    var musicOn = true
    var hint: Hint = .starting
    var hasDrawing = false
    /// The gallery is showing: hands stop painting until the kids come back to the easel.
    var isAway = false
    var previewHands: [[CGPoint]] = []
    var imageAspect: CGFloat = 4.0 / 3.0
    var pointerErases = false
    var buddyColors: [Int] = [0, 1]
    var buddyKinds: [CritterKind] = [.octopus, .seahorse]
    var colorFlash: ColorFlash?
    /// AI "magic" mode; nil until the app hands over its model store (see `setUpMagic`).
    private(set) var magic: MagicController?

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
    @ObservationIgnored private var pots: [PaintPot] = []
    @ObservationIgnored private var critterPots: [CritterPot] = []
    @ObservationIgnored private var templatePots: [TemplatePot] = []
    /// The dotted animal to trace, if one is on the canvas.
    @ObservationIgnored private var template: TemplateOutline?
    /// What you actually see: wet, textured paint on the canvas.
    @ObservationIgnored private let paintLayer = PaintLayer(center: SIMD2(0, 0.1), size: Playground.canvasSize,
                                                            z: Playground.canvasZ + 0.0015)
    @ObservationIgnored private var lastStamp: [Int: SIMD2<Float>] = [:]
    @ObservationIgnored private var frameDT: Float = 1.0 / 60.0
    @ObservationIgnored private var lastGurgle: [Int: Double] = [:]
    @ObservationIgnored private var flashCounter = 0
    @ObservationIgnored private var shake: Float = 0
    @ObservationIgnored private let canvasNode = SCNNode()
    @ObservationIgnored private var canvasBoard: SCNNode?
    @ObservationIgnored private var studioLights: [SCNNode] = []
    @ObservationIgnored private let magicOverlay = MagicOverlay()
    /// Counts paintings so Magic keeps one seed per painting (the picture doesn't jump around between runs).
    @ObservationIgnored private var paintingNumber = 0
    /// The bare board, photographed once, so Magic can tell paint from canvas weave.
    @ObservationIgnored private var blankPhoto: CGImage?

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
    /// Template bubbles stand on the easel tray along the bottom of the canvas.
    static let templateRowY: Float = 0.1 - canvasSize.y * 0.5 + 0.23
    static let strokeRadius: Float = 0.085

    // Timing
    @ObservationIgnored private var lastTime: Double = 0
    @ObservationIgnored private var clock: Float = 0
    @ObservationIgnored private var lastSqueak: Double = 0
    @ObservationIgnored private var lastBeatIndex = -1
    @ObservationIgnored private var energy: Float = 0
    @ObservationIgnored private var handsSeenTime: Float = 0

    // Pointer (mouse/touch) fallback acts as the left buddy.
    @ObservationIgnored private var pointer: SIMD2<Float>?
    @ObservationIgnored private var pointerPrevious: SIMD2<Float>?

    init() {
        buildWorld()
        frameDriver.onFrame = { [weak self] dt in self?.tick(dt: Float(dt)) }
    }

    func start() {
        audio.start()
        frameDriver.start()
    }

    func pause() {
        audio.pause()
        magic?.pause()
    }

    /// Gives the easel its AI "magic" brain. Does nothing on devices that can't run it.
    func setUpMagic(store: MagicModelStore) {
        guard magic == nil, MagicSupport.isSupported else { return }
        scene.rootNode.addChildNode(magicOverlay.node)
        blankPhoto = photographCanvas(pixels: MagicController.photoWidth)
        magic = MagicController(
            overlay: magicOverlay, store: store,
            photograph: { [weak self] width in self?.photographCanvas(pixels: width) },
            blank: { [weak self] in self?.blankPhoto },
            context: { [weak self] in
                guard let self else { return (nil, []) }
                let brushes = strokes.map(\.brush)
                return (template?.kind, brushes.isEmpty ? buddyKinds : brushes)
            },
            seed: { [weak self] in UInt32(truncatingIfNeeded: self?.paintingNumber ?? 0) })
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
        studioLights.append(keyNode)

        // Cool bounce light from the room.
        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 260
        fill.color = PlatformColor(red: 0.9, green: 0.93, blue: 1, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)
        studioLights.append(fillNode)

        // Stretched linen canvas (deep, like a gallery-wrapped canvas) on a wooden studio easel.
        let size = Self.canvasSize
        let linen = Studio.canvasMaterial(repeats: size / Studio.weaveTileSize)
        let depth: Float = 0.16
        let board = Toybox.node(SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(depth),
                                       chamferRadius: 0.012), linen, at: SIMD3(0, 0, Self.canvasZ - depth / 2))
        canvasNode.addChildNode(board)
        canvasBoard = board
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
        // A row of template bubbles on the tray: rub one to get a dotted animal to trace.
        for (k, kind) in TemplateKind.allCases.enumerated() {
            let x = (Float(k) - Float(TemplateKind.allCases.count - 1) / 2) * 0.9
            let pot = TemplatePot(kind: kind, at: SIMD3(x, Self.templateRowY, 0.3))
            scene.rootNode.addChildNode(pot.root)
            templatePots.append(pot)
        }

        for slot in 0..<2 {
            let start = SIMD3<Float>(slot == 0 ? -1.2 : 1.2, -0.9, 0.5)
            let buddy = Buddy(slot: slot, colorIndex: slot == 0 ? 0 : 1, kind: buddyKinds[slot], start: start)
            scene.rootNode.addChildNode(buddy.critter.root)
            scene.rootNode.addChildNode(buddy.starfish.root)
            buddies.append(buddy)
        }
    }

    /// Fit the canvas (plus the pot columns) into any window shape.
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
        guard !isAway else { return }
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
        for pot in templatePots {
            let rubbers = buddies.filter { $0.rubbingPot == .template(pot.kind) }
            let progress = rubbers.map(\.rubAmount).max() ?? 0
            if progress > 0 { rubbing = true }
            pot.update(dt: dt, beatPulse: beatPulse, rubProgress: min(progress, 1), selected: template?.kind == pot.kind)
        }
        template?.update()

        paintLayer.update(dt: dt)
        magic?.tick(at: now)

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
        // The template bubbles overlap the bottom of the canvas: rubbing one shouldn't smear paint.
        let onTemplatePot = templatePots.contains { pot in
            let c = pot.root.simdPosition
            return simd_distance(p, SIMD2(c.x, c.y + 0.04)) < PaintPot.radius + 0.14
        }
        guard onCanvas, !onTemplatePot else {
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
            let stroke = Stroke(color: buddy.color, radius: Self.strokeRadius, surfaceZ: Self.canvasZ + Self.strokeRadius * 0.55,
                                brush: buddy.critter.kind)
            stroke.add(p, now: now)
            strokes.append(stroke)
            activeStroke[slot] = stroke
            lastBead[slot] = p
            magic?.strokeBegan(at: now)
            buddy.critter.gulp()
            audio.play(.blip, a: (p.y - center.y) / Self.canvasSize.y + 0.5, pan: panFor(p.x))
        }
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
            magic?.canvasChanged(at: CACurrentMediaTime())
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
        var erasedAny = template?.erase(at: p, radius: r) ?? false
        if let outline = template, outline.isEmpty {
            outline.node.removeFromParentNode()
            template = nil
        }
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
                    let piece = Stroke(color: stroke.color, radius: stroke.radius, surfaceZ: stroke.surfaceZ, brush: stroke.brush)
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
            magic?.canvasChanged(at: now)
            buddy.starfish.scrubbed()
            if now - lastSqueak > 0.09 {
                lastSqueak = now
                audio.play(.squeak, pan: panFor(p.x))
                Toybox.burst(in: scene, at: SIMD3(p.x, p.y, 0.2), color: SIMD3(1, 1, 1), count: 10, speed: 1.2,
                             size: 0.04, gravity: -1)
            }
        }
    }

    // MARK: - Hang it in the gallery

    /// Photographs the finished painting (just the canvas and its paint, lit like the studio) and
    /// clears the easel for the next one. Nil when there's nothing painted yet.
    func finishPainting() -> CGImage? {
        guard !strokes.isEmpty else {
            audio.play(.swap)
            return nil
        }
        for slot in Array(activeStroke.keys) { finishStroke(slot: slot) }
        guard let photo = photographCanvas() else {
            audio.play(.fizzle)
            return nil
        }
        clearCanvas()
        audio.play(.fanfare)
        for buddy in buddies { buddy.critter.react(.happy, for: 1.2) }
        return photo
    }

    /// Renders the canvas head-on in a little photo booth: copies of the board and the live paint,
    /// the studio's own lights, no critters, pots or tracing guide in the way.
    private func photographCanvas(pixels width: CGFloat = 1920) -> CGImage? {
        guard let canvasBoard else { return nil }
        let booth = SCNScene()
        booth.lightingEnvironment.contents = scene.lightingEnvironment.contents
        booth.lightingEnvironment.intensity = scene.lightingEnvironment.intensity
        let board = canvasBoard.clone()
        board.simdTransform = canvasBoard.simdWorldTransform
        booth.rootNode.addChildNode(board)
        booth.rootNode.addChildNode(paintLayer.node.clone())
        for light in studioLights { booth.rootNode.addChildNode(light.clone()) }

        let size = Self.canvasSize
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(size.y * 0.5 * 0.99)   // a hair inside the chamfered edge
        camera.zNear = 0.1
        camera.zFar = 20
        if let studio = cameraNode.camera {
            camera.wantsHDR = studio.wantsHDR
            camera.wantsExposureAdaptation = false
            camera.exposureOffset = studio.exposureOffset
            camera.minimumExposure = studio.minimumExposure
            camera.maximumExposure = studio.maximumExposure
        }
        let lens = SCNNode()
        lens.camera = camera
        lens.simdPosition = SIMD3(0, 0.1, 5)
        booth.rootNode.addChildNode(lens)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = booth
        renderer.pointOfView = lens
        let pixels = CGSize(width: width, height: width * CGFloat(size.y / size.x))
        return renderer.snapshot(atTime: 0, with: pixels, antialiasingMode: .multisampling4X).cgImageValue
    }

    /// Wipes the paint, strokes and tracing guide off the easel.
    private func clearCanvas() {
        for stroke in strokes { stroke.node.removeFromParentNode() }
        strokes.removeAll()
        paintLayer.clear()
        template?.fadeAway()
        template = nil
        activeStroke = [:]
        lastBead = [:]
        lastStamp = [:]
        paintingNumber += 1
        magic?.cleared()
    }

    func clearAll() {
        clearCanvas()
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
        } else if let pot = templatePots.first(where: { near($0.root.simdPosition) }), pot.kind != template?.kind {
            target = .template(pot.kind)
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
        case .template(let kind):
            showTemplate(kind)
            effects.colorSplash(at: potPosition + SIMD3(0, 0.15, 0.1), color: kind.signatureColor)
            audio.play(.sparkle, pan: pan)
        }
    }

    /// Lays a new dotted outline on the canvas (replacing any other one). Paint already there stays.
    private func showTemplate(_ kind: TemplateKind) {
        template?.fadeAway()
        let outline = TemplateOutline(kind: kind, canvasCenter: SIMD2(0, 0.1), canvasSize: Self.canvasSize,
                                      z: Self.canvasZ + 0.0008)
        scene.rootNode.addChildNode(outline.node)
        template = outline
    }

    private func bouncePot(_ target: PotTarget, _ strength: Float) {
        switch target {
        case .color(let index): pots.first { $0.colorIndex == index }?.bounce(strength)
        case .critter(let kind): critterPots.first { $0.kind == kind }?.bounce(strength)
        case .template(let kind): templatePots.first { $0.kind == kind }?.bounce(strength)
        }
    }

    private func publishHUD(dt: Float, hands: [HandState], drawing: Bool, erasing: Bool, rubbing: Bool) {
        let next: Hint
        if erasing {
            next = .erasing
        } else if drawing {
            next = .drawing
        } else if rubbing {
            next = .pickingColor
        } else if !strokes.isEmpty {
            next = .readyToHang
        } else if template != nil {
            next = .tracing
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
