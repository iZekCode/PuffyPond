import SwiftUI
import SceneKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Observation
import simd

// MARK: - Saved paintings

struct Painting: Identifiable, Equatable {
    let url: URL
    let date: Date
    var id: URL { url }
}

/// Finished paintings, kept as PNGs on the device (newest first).
@Observable
final class Gallery {
    private(set) var paintings: [Painting] = []
    @ObservationIgnored private let folder: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Gallery", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    private func reload() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        paintings = files
            .filter { $0.pathExtension == "png" }
            .map { url in
                Painting(url: url, date: (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    /// Hangs a new painting at the front of the gallery.
    @discardableResult
    func add(_ image: CGImage) -> Painting? {
        let date = Date()
        let url = folder.appendingPathComponent("painting-\(Int(date.timeIntervalSince1970 * 1000)).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let painting = Painting(url: url, date: date)
        paintings.insert(painting, at: 0)
        return painting
    }

    func remove(_ painting: Painting) {
        try? FileManager.default.removeItem(at: painting.url)
        paintings.removeAll { $0 == painting }
    }

    static func image(of painting: Painting) -> PlatformImage? {
        #if os(macOS)
        return NSImage(contentsOf: painting.url)
        #else
        return UIImage(contentsOfFile: painting.url.path)
        #endif
    }
}

extension PlatformImage {
    var cgImageValue: CGImage? {
        #if os(macOS)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}

// MARK: - The museum hall

/// A quiet museum room: one painting hangs in a white frame on a grey partition wall, lit from above,
/// and the brush animals line up in front of it to admire the work.
final class GalleryHall {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let canvasMaterial = SCNMaterial()
    private let artwork = SCNNode()
    private var visitors: [(critter: Critter, home: SIMD3<Float>)] = []
    private let frameDriver = FrameDriver()
    private var clock: Float = 0
    private let tanHalfFOV = Float(tan(17.0 * Double.pi / 180))
    private var cameraDistance: Float = 9.2
    private static let cameraY: Float = 0.15
    private static let visitorZ: Float = 2.6

    /// The painting keeps the easel canvas's shape.
    static let artSize = SIMD2<Float>(4.2, 4.2 * Playground.canvasSize.y / Playground.canvasSize.x)
    static let artY: Float = 0.55

    init() {
        build()
        frameDriver.onFrame = { [weak self] dt in self?.tick(dt: Float(dt)) }
    }

    func start() { frameDriver.start() }
    func stop() { frameDriver.stop() }

    /// Keeps the framed painting and the row of visitors in view for any screen shape; the visitors
    /// stand along the bottom edge, cut off a little like people in front of you at a museum.
    func layout(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = Float(size.width / size.height)
        let needHalfW: Float = 3.1
        let needHalfH: Float = 2.75
        cameraDistance = max(needHalfH / tanHalfFOV, needHalfW / (tanHalfFOV * aspect))
        cameraNode.simdPosition = SIMD3(0, Self.cameraY, cameraDistance)
        let halfH = (cameraDistance - Self.visitorZ) * tanHalfFOV
        let halfW = halfH * aspect
        let bottom = Self.cameraY - halfH
        let spacing = min(1.05, halfW * 2 / Float(visitors.count))
        for k in visitors.indices {
            let x = (Float(k) - Float(visitors.count - 1) / 2) * spacing
            visitors[k].home = SIMD3(x, bottom + 0.5 + (k % 2 == 0 ? 0 : 0.08), Self.visitorZ)
            visitors[k].critter.gazeBias = SIMD2(-x * 0.12, 0.55)
        }
    }

    /// Puts a painting in the frame. A fresh one gets a cheer from the visitors.
    func show(_ image: PlatformImage?, cheer: Bool) {
        canvasMaterial.diffuse.contents = image
        artwork.removeAllActions()
        artwork.opacity = 0
        artwork.runAction(.fadeIn(duration: 0.35))
        for (k, visitor) in visitors.enumerated() {
            visitor.critter.squash.velocity += SIMD3(-2, 3, 0)
            visitor.critter.react(cheer ? .happy : .surprised, for: cheer ? 1.6 + Float(k) * 0.1 : 0.6)
        }
        if cheer {
            Toybox.confetti(in: scene, at: SIMD3(0, Self.artY + Self.artSize.y * 0.5, 0.6))
        }
    }

    private func build() {
        scene.background.contents = Self.backdrop()
        scene.lightingEnvironment.contents = Studio.environment()
        scene.lightingEnvironment.intensity = 0.8

        let camera = SCNCamera()
        camera.fieldOfView = 34
        camera.zNear = 0.1
        camera.zFar = 50
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.2
        camera.screenSpaceAmbientOcclusionIntensity = 0.5
        camera.screenSpaceAmbientOcclusionRadius = 0.3
        camera.vignettingIntensity = 0.3
        camera.vignettingPower = 0.8
        cameraNode.camera = camera
        cameraNode.simdPosition = SIMD3(0, Self.cameraY, cameraDistance)
        scene.rootNode.addChildNode(cameraNode)

        // Track light from the ceiling: a soft pool on the painting, the visitors' shadows on the wall.
        let track = SCNLight()
        track.type = .spot
        track.intensity = 1100
        track.color = PlatformColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
        track.spotInnerAngle = 25
        track.spotOuterAngle = 80
        track.castsShadow = true
        track.shadowMode = .deferred
        track.shadowRadius = 12
        track.shadowSampleCount = 16
        track.shadowColor = PlatformColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.4)
        track.shadowMapSize = CGSize(width: 2048, height: 2048)
        track.zNear = 1
        track.zFar = 30
        let trackNode = SCNNode()
        trackNode.light = track
        trackNode.simdPosition = SIMD3(-1.5, 5.5, 7)
        trackNode.simdLook(at: SIMD3(0, Self.artY - 0.3, 0))
        scene.rootNode.addChildNode(trackNode)

        let fill = SCNLight()
        fill.type = .ambient
        fill.intensity = 380
        fill.color = PlatformColor(red: 0.92, green: 0.94, blue: 1, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        scene.rootNode.addChildNode(fillNode)

        // Grey partition wall, floor to ceiling.
        let wall = SCNMaterial()
        wall.lightingModel = .physicallyBased
        wall.diffuse.contents = PlatformColor(red: 0.5, green: 0.5, blue: 0.51, alpha: 1)
        wall.roughness.contents = NSNumber(value: 0.95)
        wall.metalness.contents = NSNumber(value: 0.0)
        scene.rootNode.addChildNode(Toybox.node(SCNBox(width: 5.2, height: 16, length: 0.3, chamferRadius: 0),
                                                wall, at: SIMD3(0, 0.5, -0.15)))

        // White gallery frame around a canvas plane.
        let size = Self.artSize
        let paint = SCNMaterial()
        paint.lightingModel = .physicallyBased
        paint.roughness.contents = NSNumber(value: 0.25)
        paint.metalness.contents = NSNumber(value: 0.0)
        paint.diffuse.contents = PlatformColor(white: 0.97, alpha: 1)
        let bar: Float = 0.1
        let depth: Float = 0.12
        func piece(_ w: Float, _ h: Float, at p: SIMD2<Float>) {
            artwork.addChildNode(Toybox.node(SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(depth),
                                                    chamferRadius: 0.012), paint, at: SIMD3(p.x, p.y, depth / 2)))
        }
        let outer = size + SIMD2(repeating: bar * 2)
        piece(outer.x, bar, at: SIMD2(0, (size.y + bar) / 2))
        piece(outer.x, bar, at: SIMD2(0, -(size.y + bar) / 2))
        piece(bar, size.y, at: SIMD2(-(size.x + bar) / 2, 0))
        piece(bar, size.y, at: SIMD2((size.x + bar) / 2, 0))

        canvasMaterial.lightingModel = .lambert
        canvasMaterial.diffuse.mipFilter = .linear
        let canvas = SCNNode(geometry: SCNPlane(width: CGFloat(size.x), height: CGFloat(size.y)))
        canvas.geometry?.materials = [canvasMaterial]
        canvas.simdPosition = SIMD3(0, 0, 0.03)
        artwork.addChildNode(canvas)
        artwork.simdPosition = SIMD3(0, Self.artY, 0)
        scene.rootNode.addChildNode(artwork)

        // The brush animals, shoulder to shoulder along the bottom, looking up at the painting.
        for kind in CritterKind.allCases {
            let home = SIMD3<Float>(0, -2, Self.visitorZ)
            let critter = kind.make(color: kind.signatureColor, at: home)
            critter.sizeScale = 1.7
            scene.rootNode.addChildNode(critter.root)
            visitors.append((critter, home))
        }
        layout(size: CGSize(width: 16, height: 10))
    }

    private func tick(dt: Float) {
        clock += dt
        let pulse = exp(-(clock * 2).truncatingRemainder(dividingBy: 1) * 6)
        for (k, visitor) in visitors.enumerated() {
            let t = clock * 0.8 + Float(k) * 1.3
            let sway = SIMD3<Float>(sin(t) * 0.05, sin(t * 1.7) * 0.03, 0)
            visitor.critter.update(dt: dt, target: visitor.home + sway, visible: true, painting: false,
                                   beatPulse: pulse * 0.4)
        }
    }

    /// The rest of the museum, out of focus behind the partition: blue-grey walls hung with paintings,
    /// statues on plinths, a warm stone floor and ceiling light.
    static func backdrop() -> PlatformImage? {
        let w = 1600, h = 1000
        guard let sharp = Toybox.image(width: w, height: h, draw: { ctx in
            func fill(_ r: CGRect, _ c: SIMD4<Float>) {
                ctx.setFillColor(CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)))
                ctx.fill(r)
            }
            func polygon(_ points: [CGPoint], _ c: SIMD4<Float>) {
                ctx.setFillColor(CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w)))
                ctx.addLines(between: points)
                ctx.closePath()
                ctx.fillPath()
            }
            let W = CGFloat(w), H = CGFloat(h)
            let horizon: CGFloat = 330          // where the far wall meets the floor (y up)
            fill(CGRect(x: 0, y: 0, width: W, height: H), SIMD4(0.55, 0.58, 0.63, 1))          // walls
            // Side walls receding toward the middle, a little darker than the far wall.
            polygon([CGPoint(x: 0, y: 0), CGPoint(x: 420, y: horizon), CGPoint(x: 420, y: 880),
                     CGPoint(x: 0, y: H)], SIMD4(0.5, 0.53, 0.58, 1))
            polygon([CGPoint(x: W, y: 0), CGPoint(x: W - 420, y: horizon), CGPoint(x: W - 420, y: 880),
                     CGPoint(x: W, y: H)], SIMD4(0.48, 0.51, 0.56, 1))
            // Ceiling with a long skylight.
            polygon([CGPoint(x: 0, y: H), CGPoint(x: 420, y: 880), CGPoint(x: W - 420, y: 880),
                     CGPoint(x: W, y: H)], SIMD4(0.72, 0.7, 0.66, 1))
            fill(CGRect(x: 300, y: 920, width: W - 600, height: 40), SIMD4(0.95, 0.94, 0.9, 1))
            // Stone floor and the dark skirting line along the walls.
            polygon([CGPoint(x: 0, y: 0), CGPoint(x: 420, y: horizon), CGPoint(x: W - 420, y: horizon),
                     CGPoint(x: W, y: 0)], SIMD4(0.66, 0.61, 0.55, 1))
            fill(CGRect(x: 420, y: horizon, width: W - 840, height: 12), SIMD4(0.25, 0.25, 0.27, 1))
            polygon([CGPoint(x: 0, y: 40), CGPoint(x: 420, y: horizon + 10), CGPoint(x: 420, y: horizon),
                     CGPoint(x: 0, y: 0)], SIMD4(0.25, 0.25, 0.27, 1))
            polygon([CGPoint(x: W, y: 40), CGPoint(x: W - 420, y: horizon + 10), CGPoint(x: W - 420, y: horizon),
                     CGPoint(x: W, y: 0)], SIMD4(0.25, 0.25, 0.27, 1))
            // Paintings on the side walls: gilt or dark frames, warm canvases.
            let hung: [(CGRect, SIMD4<Float>, SIMD4<Float>)] = [
                (CGRect(x: 10, y: 470, width: 70, height: 130), SIMD4(0.5, 0.35, 0.2, 1), SIMD4(0.45, 0.32, 0.22, 1)),
                (CGRect(x: 160, y: 500, width: 70, height: 110), SIMD4(0.62, 0.5, 0.32, 1), SIMD4(0.8, 0.74, 0.62, 1)),
                (CGRect(x: 300, y: 530, width: 40, height: 70), SIMD4(0.55, 0.42, 0.25, 1), SIMD4(0.6, 0.45, 0.3, 1)),
                (CGRect(x: W - 120, y: 450, width: 100, height: 160), SIMD4(0.12, 0.12, 0.13, 1), SIMD4(0.3, 0.22, 0.16, 1)),
                (CGRect(x: W - 270, y: 500, width: 60, height: 100), SIMD4(0.55, 0.42, 0.25, 1), SIMD4(0.7, 0.6, 0.45, 1)),
            ]
            for (r, frame, art) in hung {
                fill(r, frame)
                fill(r.insetBy(dx: r.width * 0.12, dy: r.width * 0.12), art)
            }
            // Statues on plinths.
            let statues: [(CGFloat, CGFloat, CGFloat)] = [(180, 200, 70), (W - 140, 160, 90), (W - 300, 260, 50)]
            for (x, base, s) in statues {
                fill(CGRect(x: x - s * 0.6, y: base, width: s * 1.2, height: s * 2.4), SIMD4(0.42, 0.44, 0.47, 1))
                let top = base + s * 2.4
                ctx.setFillColor(CGColor(red: 0.86, green: 0.83, blue: 0.77, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: x - s * 0.45, y: top, width: s * 0.9, height: s * 1.5))
                ctx.fillEllipse(in: CGRect(x: x - s * 0.22, y: top + s * 1.35, width: s * 0.44, height: s * 0.5))
            }
        }) else { return nil }
        // Shallow depth of field: everything behind the partition is soft.
        let input = CIImage(cgImage: sharp)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 9).cropped(to: input.extent)
        return Toybox.platformImage(CIContext().createCGImage(blurred, from: input.extent) ?? sharp)
    }
}

// MARK: - Gallery screen

struct GalleryView: View {
    let gallery: Gallery
    let close: () -> Void
    @State private var index: Int
    @State private var hall = GalleryHall()
    @State private var confirmingRemoval = false
    @Environment(\.uiScale) private var scale
    private let cheerOnOpen: Bool

    init(gallery: Gallery, startAt index: Int = 0, justHung: Bool = false, close: @escaping () -> Void) {
        self.gallery = gallery
        self.close = close
        _index = State(initialValue: index)
        cheerOnOpen = justHung
    }

    private var current: Painting? {
        gallery.paintings.indices.contains(index) ? gallery.paintings[index] : nil
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                SceneView(scene: hall.scene, pointOfView: hall.cameraNode, options: [.rendersContinuously],
                          antialiasingMode: .multisampling4X)
                    .onAppear { hall.layout(size: proxy.size) }
                    .onChange(of: proxy.size) { _, size in hall.layout(size: size) }
            }
            .ignoresSafeArea()
                .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
                    if drag.translation.width < -60 { step(1) } else if drag.translation.width > 60 { step(-1) }
                })

            VStack {
                HStack(alignment: .top) {
                    RoundButton(symbol: "paintbrush.pointed.fill", tint: .blue, action: close)
                    Spacer()
                    VStack(spacing: 4) {
                        Text("Puffy Pond Gallery")
                            .font(.system(size: 26 * scale, weight: .black, design: .rounded))
                        if let current {
                            Text("\(current.date.formatted(.dateTime.month(.wide).day().hour().minute()))"
                                 + (gallery.paintings.count > 1 ? " · \(index + 1) of \(gallery.paintings.count)" : ""))
                                .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.85), in: Capsule())
                    .foregroundStyle(Color(red: 0.25, green: 0.2, blue: 0.35))
                    Spacer()
                    RoundButton(symbol: "trash.fill", tint: .red) { confirmingRemoval = true }
                        .opacity(current == nil ? 0 : 1)
                }
                Spacer()
            }
            .padding(16 * scale)

            // Page buttons sit at the middle of the two sides, where thumbs rest on a wide screen.
            HStack {
                RoundButton(symbol: "chevron.left", tint: .indigo) { step(-1) }
                    .opacity(index > 0 ? 1 : 0)
                Spacer()
                RoundButton(symbol: "chevron.right", tint: .indigo) { step(1) }
                    .opacity(index < gallery.paintings.count - 1 ? 1 : 0)
            }
            .padding(.horizontal, 16 * scale)
        }
        .confirmationDialog("Take this painting down?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Take it down", role: .destructive, action: removeCurrent)
        }
        .onAppear {
            hall.start()
            showCurrent(cheer: cheerOnOpen)
        }
        .onDisappear { hall.stop() }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard gallery.paintings.indices.contains(next) else { return }
        index = next
        showCurrent(cheer: false)
    }

    private func removeCurrent() {
        guard let current else { return }
        gallery.remove(current)
        if gallery.paintings.isEmpty {
            close()
            return
        }
        index = min(index, gallery.paintings.count - 1)
        showCurrent(cheer: false)
    }

    private func showCurrent(cheer: Bool) {
        hall.show(current.flatMap(Gallery.image(of:)), cheer: cheer)
    }
}
