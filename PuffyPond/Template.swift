import SceneKit
import simd

// MARK: - Templates (a faint dotted pond animal to trace)

/// A shape kids can trace when they don't know what to draw. Only a guide: it never goes into the
/// gallery photo, only their own paint does.
enum TemplateKind: CaseIterable {
    case fish, turtle, duck

    /// Outline as SVG-style path data (absolute M, L, C, Z) in a 300×220 sketch space, y down.
    private var paths: [String] {
        switch self {
        case .fish:
            return ["M60 110 C90 50 190 50 220 110 C190 170 90 170 60 110 Z",     // body
                    "M220 110 L270 70 L262 110 L270 150 Z",                       // tail
                    "M130 62 C140 35 170 35 175 60"]                              // fin
        case .turtle:
            return ["M80 140 C80 70 220 70 220 140 Z",                            // shell
                    "M220 125 C250 110 270 120 265 140 C258 155 235 150 222 140", // head
                    "M95 140 L90 170 L115 170 L115 142",                          // legs
                    "M185 142 L185 170 L210 170 L205 140",
                    "M120 100 L150 85 L180 100 L170 128 L130 128 Z"]              // shell pattern
        case .duck:
            return ["M70 130 C70 175 220 180 235 135 C240 115 210 110 190 120 C170 95 175 60 150 55 "
                        + "C120 50 110 85 125 110 C100 105 70 110 70 130 Z",      // body and neck
                    "M112 72 L85 78 L112 86"]                                     // beak
        }
    }

    private var eyeSpots: [SIMD2<Float>] {
        switch self {
        case .fish: return [SIMD2(100, 100)]
        case .turtle: return [SIMD2(252, 128)]
        case .duck: return [SIMD2(138, 72)]
        }
    }

    /// Bubble icon color.
    var signatureColor: SIMD3<Float> {
        switch self {
        case .fish: return Paint.colors[0]     // tangerine
        case .turtle: return Paint.colors[4]   // mint
        case .duck: return Paint.colors[2]     // lemon
        }
    }

    /// Outline polylines and eye dots, scaled to fit `size` around `center` (world units, y up).
    func shape(center: SIMD2<Float>, size: SIMD2<Float>) -> (lines: [[SIMD2<Float>]], eyes: [SIMD2<Float>]) {
        let lines = paths.flatMap { Self.polylines($0) }
        let all = lines.flatMap { $0 } + eyeSpots
        let lo = all.reduce(all[0], simd_min)
        let hi = all.reduce(all[0], simd_max)
        let scale = min(size.x / (hi.x - lo.x), size.y / (hi.y - lo.y))
        let mid = (lo + hi) * 0.5
        func place(_ p: SIMD2<Float>) -> SIMD2<Float> { center + SIMD2(p.x - mid.x, mid.y - p.y) * scale }
        return (lines.map { $0.map(place) }, eyeSpots.map(place))
    }

    /// Flattens path data into polylines (curves sampled into short straight pieces).
    private static func polylines(_ path: String) -> [[SIMD2<Float>]] {
        let spaced = path.reduce(into: "") { s, ch in s += ch.isLetter ? " \(ch) " : String(ch) }
        var tokens = spaced.split(separator: " ").map(String.init)[...]
        func point() -> SIMD2<Float> {
            let x = Float(tokens.removeFirst()) ?? 0
            let y = Float(tokens.removeFirst()) ?? 0
            return SIMD2(x, y)
        }
        var lines: [[SIMD2<Float>]] = []
        var current: [SIMD2<Float>] = []
        var command = "M"
        while let token = tokens.first {
            if token.first?.isLetter == true {
                command = token
                tokens.removeFirst()
            }
            switch command {
            case "M":
                if current.count > 1 { lines.append(current) }
                current = [point()]
                command = "L"
            case "L":
                current.append(point())
            case "C":
                let a = current.last ?? .zero
                let c1 = point(), c2 = point(), b = point()
                for k in 1...16 {
                    let t = Float(k) / 16, u = 1 - t
                    current.append(a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t))
                }
            case "Z":
                if let first = current.first { current.append(first) }
                if current.count > 1 { lines.append(current) }
                current = []
            default:
                tokens.removeFirst()
            }
        }
        if current.count > 1 { lines.append(current) }
        return lines
    }
}

/// The dotted outline lying on the canvas, just under the paint. The starfish scrubs it away dash by dash.
final class TemplateOutline {
    let kind: TemplateKind
    let node = SCNNode()
    private let material = SCNMaterial()
    private let origin: SIMD2<Float>        // bottom-left of the canvas
    private let size: SIMD2<Float>
    private var marks: [[SIMD2<Float>]]     // dashes; a single point is an eye dot
    private var dirty = true
    private var fading = false

    private static let pixelsPerUnit: Float = 200
    private static let lineWidth: Float = 0.06
    private static let eyeRadius: Float = 0.07
    private static let dash: Float = 0.18
    private static let gap: Float = 0.14
    private static let ink = CGColor(red: 0.42, green: 0.36, blue: 0.3, alpha: 0.5)

    init(kind: TemplateKind, canvasCenter: SIMD2<Float>, canvasSize: SIMD2<Float>, z: Float) {
        self.kind = kind
        origin = canvasCenter - canvasSize * 0.5
        size = canvasSize
        // Big and bold so small kids can follow it; nudged up a little, clear of the bubbles on the tray.
        let shape = kind.shape(center: canvasCenter + SIMD2(0, 0.15), size: canvasSize * SIMD2(0.72, 0.68))
        marks = shape.lines.flatMap { Self.dashes($0) } + shape.eyes.map { [$0] }

        let plane = SCNPlane(width: CGFloat(canvasSize.x), height: CGFloat(canvasSize.y))
        material.lightingModel = .physicallyBased
        material.roughness.contents = NSNumber(value: 1.0)
        material.metalness.contents = NSNumber(value: 0.0)
        material.transparencyMode = .aOne
        material.writesToDepthBuffer = false
        plane.materials = [material]
        node.geometry = plane
        node.castsShadow = false
        node.simdPosition = SIMD3(canvasCenter.x, canvasCenter.y, z)
        node.opacity = 0
        node.runAction(.fadeIn(duration: 0.4))
        render()
    }

    var isEmpty: Bool { marks.isEmpty }

    /// Starfish scrub: wipes the dashes it touches. Returns true if anything was wiped.
    @discardableResult
    func erase(at p: SIMD2<Float>, radius: Float) -> Bool {
        guard !fading else { return false }
        let before = marks.count
        marks.removeAll { mark in mark.contains { simd_distance($0, p) < radius + Self.lineWidth * 0.5 } }
        if marks.count != before { dirty = true }
        return marks.count != before
    }

    func update() {
        if dirty { render() }
    }

    /// Fades out and leaves the scene.
    func fadeAway() {
        fading = true
        node.runAction(.sequence([.fadeOut(duration: 0.35), .removeFromParentNode()]))
    }

    private func render() {
        dirty = false
        let s = Self.pixelsPerUnit
        let image = Toybox.image(width: Int(size.x * s), height: Int(size.y * s)) { ctx in
            func px(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: CGFloat((p.x - origin.x) * s), y: CGFloat((p.y - origin.y) * s))
            }
            ctx.setStrokeColor(Self.ink)
            ctx.setFillColor(Self.ink)
            ctx.setLineWidth(CGFloat(Self.lineWidth * s))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for mark in marks {
                if mark.count == 1 {
                    let c = px(mark[0])
                    let r = CGFloat(Self.eyeRadius * s)
                    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                } else {
                    ctx.move(to: px(mark[0]))
                    for p in mark.dropFirst() { ctx.addLine(to: px(p)) }
                    ctx.strokePath()
                }
            }
        }
        material.diffuse.contents = Toybox.platformImage(image)
    }

    /// Cuts a polyline into dashes of `dash` length separated by `gap`.
    private static func dashes(_ line: [SIMD2<Float>]) -> [[SIMD2<Float>]] {
        guard let first = line.first else { return [] }
        var out: [[SIMD2<Float>]] = []
        var piece = [first]
        var drawing = true
        var left = dash
        for (start, end) in zip(line, line.dropFirst()) {
            var a = start
            var length = simd_distance(a, end)
            while length > 0 && length >= left {
                let q = a + (end - a) * (left / length)
                if drawing {
                    piece.append(q)
                    out.append(piece)
                } else {
                    piece = [q]
                }
                drawing.toggle()
                a = q
                length -= left
                left = drawing ? dash : gap
            }
            left -= length
            if drawing { piece.append(end) }
        }
        if drawing && piece.count > 1 { out.append(piece) }
        return out
    }
}

// MARK: - Template bubbles (rub one to get its outline on the canvas)

/// A glass bubble on the easel tray with a little picture of the animal to trace.
final class TemplatePot {
    let root = SCNNode()
    let kind: TemplateKind
    private let bubble: SCNNode
    private let icon: SCNNode
    private let progressRing: SCNNode
    private let halo: SCNNode
    private var squash = Spring3(SIMD3(1, 1, 1))
    private var ringScale = Spring1(0)
    private var clock: Float = 0

    init(kind: TemplateKind, at position: SIMD3<Float>) {
        self.kind = kind
        root.simdPosition = position
        clock = Float(TemplateKind.allCases.firstIndex(of: kind) ?? 0) * 1.7

        let glass = SCNMaterial()
        glass.lightingModel = .blinn
        glass.diffuse.contents = PlatformColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 0.14)
        glass.specular.contents = PlatformColor.white
        glass.shininess = 0.9
        glass.transparencyMode = .aOne
        glass.writesToDepthBuffer = false
        bubble = Toybox.node(SCNSphere(radius: CGFloat(PaintPot.radius)), glass)
        root.addChildNode(bubble)
        let stand = Toybox.balloon(kind.signatureColor, wobble: 0, roughness: 0.25)
        root.addChildNode(Toybox.node(SCNTorus(ringRadius: 0.14, pipeRadius: 0.035), stand, at: SIMD3(0, -0.19, 0)))

        // The animal's outline, drawn solid in its color, floating inside the bubble.
        let picture = SCNMaterial()
        picture.lightingModel = .constant
        picture.diffuse.contents = Toybox.platformImage(Self.iconImage(kind))
        picture.transparencyMode = .aOne
        picture.writesToDepthBuffer = false
        let plane = SCNPlane(width: 0.3, height: 0.3)
        plane.materials = [picture]
        icon = SCNNode(geometry: plane)
        icon.castsShadow = false
        root.addChildNode(icon)

        let ringMaterial = SCNMaterial()
        ringMaterial.lightingModel = .constant
        ringMaterial.diffuse.contents = PlatformColor.white
        progressRing = SCNNode(geometry: SCNTorus(ringRadius: 0.27, pipeRadius: 0.022))
        progressRing.geometry?.materials = [ringMaterial]
        progressRing.simdEulerAngles = SIMD3(Float.pi / 2, 0, 0)
        progressRing.simdScale = SIMD3(repeating: 0.001)
        root.addChildNode(progressRing)

        halo = SCNNode(geometry: SCNTorus(ringRadius: 0.22, pipeRadius: 0.014))
        halo.geometry?.materials = [ringMaterial]
        halo.simdPosition = SIMD3(0, -0.17, 0)
        root.addChildNode(halo)
    }

    func bounce(_ strength: Float = 1) {
        squash.velocity += SIMD3(3, -5, 3) * strength
    }

    /// - Parameters:
    ///   - rubProgress: 0…1 while a buddy is rubbing this bubble.
    ///   - selected: this animal's outline is on the canvas right now.
    func update(dt: Float, beatPulse: Float, rubProgress: Float, selected: Bool) {
        clock += dt
        let jiggle = rubProgress > 0 ? sin(clock * 30) * 0.05 * rubProgress : 0
        squash.step(to: SIMD3(1 + beatPulse * 0.04 + jiggle, 1 - beatPulse * 0.05 - jiggle, 1 + jiggle),
                    stiffness: 260, damping: 9, dt: dt)
        bubble.simdScale = squash.value
        icon.simdScale = squash.value
        icon.simdPosition = SIMD3(0, sin(clock * 1.3) * 0.015, 0.02)
        icon.simdEulerAngles = SIMD3(0, 0, sin(clock * 0.9) * 0.08)
        ringScale.step(to: rubProgress > 0 ? 0.35 + rubProgress * 0.65 : 0, stiffness: 300, damping: 18, dt: dt)
        progressRing.simdScale = SIMD3(repeating: max(ringScale.value, 0.001))
        progressRing.simdEulerAngles = SIMD3(Float.pi / 2, clock * 3, 0)
        halo.isHidden = !selected
        halo.simdScale = SIMD3(repeating: 1 + sin(clock * 4) * 0.04)
        halo.simdEulerAngles = SIMD3(0.25, clock, 0)
    }

    private static func iconImage(_ kind: TemplateKind) -> CGImage? {
        let side = 256
        let shape = kind.shape(center: SIMD2(0.5, 0.5), size: SIMD2(0.86, 0.86))
        let c = kind.signatureColor
        let ink = CGColor(red: CGFloat(c.x) * 0.8, green: CGFloat(c.y) * 0.8, blue: CGFloat(c.z) * 0.8, alpha: 1)
        return Toybox.image(width: side, height: side) { ctx in
            func px(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x) * CGFloat(side), y: CGFloat(p.y) * CGFloat(side)) }
            ctx.setStrokeColor(ink)
            ctx.setFillColor(ink)
            ctx.setLineWidth(14)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for line in shape.lines {
                ctx.move(to: px(line[0]))
                for p in line.dropFirst() { ctx.addLine(to: px(p)) }
                ctx.strokePath()
            }
            for eye in shape.eyes {
                let e = px(eye)
                ctx.fillEllipse(in: CGRect(x: e.x - 10, y: e.y - 10, width: 20, height: 20))
            }
        }
    }
}
