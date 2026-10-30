import SceneKit
import CoreGraphics
import simd
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

/// Short-lived flying things: balloon shards, popped googly eyes, shockwave rings, "POP!" text.
final class Effects {
    private enum Kind { case shard, eye, ring, text }

    private struct Flyer {
        let node: SCNNode
        let kind: Kind
        var velocity: SIMD3<Float>
        var spin: SIMD3<Float>
        var age: Float = 0
        let life: Float
        let gravity: Float
        let baseScale: SIMD3<Float>
    }

    let scene: SCNScene
    private var flyers: [Flyer] = []
    private static let starImage = Toybox.platformImage(makeStar())
    private static let bubbleImage = Toybox.platformImage(makeBubble())

    init(scene: SCNScene) {
        self.scene = scene
    }

    // MARK: Pop!

    /// The full balloon-pop spectacle.
    func pop(at center: SIMD3<Float>, radius: Float, colors: [SIMD3<Float>], eyeRadius: Float, eyes: [SIMD3<Float>]) {
        let palette = colors.isEmpty ? Paint.colors : colors

        // 1. Rubbery shards in the creature's own colors.
        let shardCount = 16
        for k in 0..<shardCount {
            let color = palette[k % palette.count]
            let size = Float.random(in: 0.035...0.07) * max(radius * 1.6, 0.6)
            let shard = Toybox.node(SCNSphere(radius: CGFloat(size)), Toybox.balloon(color, wobble: 0, roughness: 0.3))
            let base = SIMD3<Float>(1, Float.random(in: 0.4...0.7), 0.18)
            shard.simdScale = base
            let dir = simd_normalize(SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -0.4...1.2), Float.random(in: -0.3...1)))
            shard.simdPosition = center + dir * radius * 0.5
            shard.simdEulerAngles = SIMD3(Float.random(in: 0...6), Float.random(in: 0...6), Float.random(in: 0...6))
            scene.rootNode.addChildNode(shard)
            flyers.append(Flyer(node: shard, kind: .shard, velocity: dir * Float.random(in: 2.2...4.2),
                                spin: SIMD3(Float.random(in: -14...14), Float.random(in: -14...14), Float.random(in: -14...14)),
                                life: Float.random(in: 0.9...1.4), gravity: -7, baseScale: base))
        }

        // 2. The googly eyes go flying (and keep looking surprised).
        for (i, p) in eyes.enumerated() {
            let eye = Toybox.eye(radius: eyeRadius)
            eye.root.simdPosition = p
            scene.rootNode.addChildNode(eye.root)
            let side: Float = i == 0 ? -1 : 1
            flyers.append(Flyer(node: eye.root, kind: .eye,
                                velocity: SIMD3(side * Float.random(in: 0.8...1.6), Float.random(in: 2.5...3.5), 1.2),
                                spin: SIMD3(0, 0, -side * Float.random(in: 6...10)),
                                life: 1.3, gravity: -6.5, baseScale: SIMD3(repeating: 1)))
        }

        // 3. Shockwave ring.
        let ringMaterial = SCNMaterial()
        ringMaterial.lightingModel = .constant
        ringMaterial.diffuse.contents = PlatformColor.white
        ringMaterial.writesToDepthBuffer = false
        let ring = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(max(radius * 0.6, 0.15)), pipeRadius: 0.03))
        ring.geometry?.materials = [ringMaterial]
        ring.simdPosition = center
        ring.simdEulerAngles = SIMD3(Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(ring)
        flyers.append(Flyer(node: ring, kind: .ring, velocity: .zero, spin: .zero, life: 0.4, gravity: 0,
                            baseScale: SIMD3(repeating: 1)))

        // 4. Comic "POP!" in puffy letters.
        let text = popText(color: palette[0])
        text.simdPosition = center + SIMD3(0, radius * 0.4 + 0.15, 0.35)
        scene.rootNode.addChildNode(text)
        flyers.append(Flyer(node: text, kind: .text, velocity: SIMD3(0, 0.45, 0), spin: .zero, life: 0.9, gravity: 0,
                            baseScale: SIMD3(repeating: 1)))

        // 5. Confetti and sparkles.
        for color in palette {
            Toybox.burst(in: scene, at: center, color: color, count: 26, speed: 3.2, size: 0.055)
        }
        Self.sparkles(in: scene, at: center, color: SIMD3(1, 0.95, 0.6), count: 40, speed: 2.6)
    }

    /// Paint splash + sparkles when a fish picks up a new color.
    func colorSplash(at point: SIMD3<Float>, color: SIMD3<Float>) {
        for _ in 0..<8 {
            let drop = Toybox.node(SCNSphere(radius: CGFloat(Float.random(in: 0.025...0.045))),
                                   Toybox.balloon(color, wobble: 0, roughness: 0.2))
            drop.simdPosition = point
            scene.rootNode.addChildNode(drop)
            let v = SIMD3<Float>(Float.random(in: -1.4...1.4), Float.random(in: 1.5...3.2), Float.random(in: 0...1))
            flyers.append(Flyer(node: drop, kind: .shard, velocity: v, spin: .zero, life: 0.8, gravity: -8,
                                baseScale: SIMD3(repeating: 1)))
        }
        Self.sparkles(in: scene, at: point, color: SIMD3(1, 1, 1), count: 18, speed: 1.4)
        Toybox.burst(in: scene, at: point, color: color, count: 24, speed: 1.8, size: 0.05, gravity: -2)
    }

    private func popText(color: SIMD3<Float>) -> SCNNode {
        let text = SCNText(string: "POP!", extrusionDepth: 0.4)
        text.font = PlatformFont.systemFont(ofSize: 2, weight: .black)
        text.flatness = 0.05
        text.chamferRadius = 0.15
        text.materials = [Toybox.balloon(simd_clamp(color + 0.25, SIMD3(repeating: 0), SIMD3(repeating: 1)),
                                         wobble: 0, roughness: 0.2)]
        let node = SCNNode(geometry: text)
        let (lo, hi) = text.boundingBox
        let cx = (Float(lo.x) + Float(hi.x)) * 0.5
        let cy = (Float(lo.y) + Float(hi.y)) * 0.5
        var pivot = matrix_identity_float4x4
        pivot.columns.3 = SIMD4(cx, cy, 0, 1)
        node.simdPivot = pivot
        let holder = SCNNode()
        let scale: Float = 0.16
        node.simdScale = SIMD3(repeating: scale)
        holder.addChildNode(node)
        holder.simdScale = SIMD3(repeating: 0.001)
        return holder
    }

    // MARK: Per frame

    func update(dt: Float) {
        for i in flyers.indices {
            flyers[i].age += dt
            let f = flyers[i]
            let t = min(f.age / f.life, 1)
            switch f.kind {
            case .shard, .eye:
                flyers[i].velocity.y += f.gravity * dt
                flyers[i].velocity *= exp(-dt * 0.6)
                f.node.simdPosition += flyers[i].velocity * dt
                f.node.simdEulerAngles += f.spin * dt
                let fade: Float = t < 0.65 ? 1 : 1 - (t - 0.65) / 0.35
                f.node.opacity = CGFloat(fade)
                if f.kind == .shard {
                    f.node.simdScale = f.baseScale * (1 - t * 0.4)
                }
            case .ring:
                f.node.simdScale = SIMD3(repeating: 1 + t * 6)
                f.node.opacity = CGFloat(1 - t)
            case .text:
                // Bouncy pop-in, float up, fade out.
                let s: Float
                if t < 0.2 {
                    let x = t / 0.2
                    let u = x - 1
                    s = 1 + 3.2 * u * u * u + 2.2 * u * u
                } else {
                    s = 1 + sin(t * 20) * 0.03 * (1 - t)
                }
                f.node.simdScale = SIMD3(repeating: max(s, 0.001))
                f.node.simdPosition += f.velocity * dt
                let fade: Float = t < 0.6 ? 1 : 1 - (t - 0.6) / 0.4
                f.node.opacity = CGFloat(fade)
            }
        }
        for f in flyers where f.age >= f.life {
            f.node.removeFromParentNode()
        }
        flyers.removeAll { $0.age >= $0.life }
    }

    // MARK: Particles

    /// Twinkly star sparkles.
    static func sparkles(in scene: SCNScene, at position: SIMD3<Float>, color: SIMD3<Float>,
                         count: CGFloat, speed: CGFloat) {
        let p = SCNParticleSystem()
        p.particleImage = starImage
        p.birthRate = count / 0.05
        p.emissionDuration = 0.05
        p.loops = false
        p.particleLifeSpan = 0.6
        p.particleLifeSpanVariation = 0.3
        p.particleVelocity = speed
        p.particleVelocityVariation = speed * 0.7
        p.spreadingAngle = 180
        p.particleSize = 0.09
        p.particleSizeVariation = 0.05
        p.particleAngularVelocity = 400
        p.particleAngularVelocityVariation = 300
        p.particleColor = Paint.platform(color)
        p.dampingFactor = 2
        p.blendMode = .additive
        p.isLightingEnabled = false
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.1, 0.6, 1]
        p.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        let emitter = SCNNode()
        emitter.simdPosition = position
        emitter.addParticleSystem(p)
        scene.rootNode.addChildNode(emitter)
        emitter.runAction(.sequence([.wait(duration: 1.5), .removeFromParentNode()]))
    }

    /// Continuous ink bubbles for a fish's mouth (birth rate is driven per frame).
    static func inkBubbles() -> SCNParticleSystem {
        let p = SCNParticleSystem()
        p.particleImage = bubbleImage
        p.birthRate = 0
        p.loops = true
        p.particleLifeSpan = 0.55
        p.particleLifeSpanVariation = 0.2
        p.particleVelocity = 0.9
        p.particleVelocityVariation = 0.4
        p.emittingDirection = SCNVector3(0, 0, 1)
        p.spreadingAngle = 35
        p.particleSize = 0.035
        p.particleSizeVariation = 0.02
        p.dampingFactor = 2.5
        p.acceleration = SCNVector3(0, 0.6, 0)
        p.blendMode = .alpha
        p.isLightingEnabled = false
        let grow = CAKeyframeAnimation()
        grow.values = [0.4, 1.3, 0.0]
        grow.keyTimes = [0, 0.6, 1]
        p.propertyControllers = [.size: SCNParticlePropertyController(animation: grow)]
        return p
    }

    // MARK: Images

    private static func makeStar() -> CGImage? {
        Toybox.image(width: 64, height: 64) { ctx in
            let c = CGPoint(x: 32, y: 32)
            let path = CGMutablePath()
            for k in 0..<8 {
                let angle = CGFloat(k) * .pi / 4
                let r: CGFloat = k % 2 == 0 ? 30 : 8
                let p = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
        }
    }

    private static func makeBubble() -> CGImage? {
        Toybox.image(width: 64, height: 64) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            ctx.fillEllipse(in: CGRect(x: 6, y: 6, width: 52, height: 52))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 18, y: 34, width: 14, height: 12))
        }
    }
}
