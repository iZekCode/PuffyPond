import SceneKit
import SwiftUI
import CoreGraphics
import simd
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

// MARK: - Colors

enum Paint {
    /// Bright, high-contrast toy colors.
    static let colors: [SIMD3<Float>] = [
        SIMD3(1.00, 0.42, 0.20), // tangerine
        SIMD3(0.18, 0.62, 1.00), // sky blue
        SIMD3(1.00, 0.80, 0.16), // lemon
        SIMD3(0.98, 0.36, 0.62), // bubblegum
        SIMD3(0.30, 0.85, 0.50), // mint
        SIMD3(0.62, 0.42, 1.00), // grape
    ]

    static let names = ["Tangerine", "Sky", "Lemon", "Bubblegum", "Mint", "Grape"]

    static func swiftUI(_ c: SIMD3<Float>) -> Color {
        Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    static func platform(_ c: SIMD3<Float>, alpha: CGFloat = 1) -> PlatformColor {
        PlatformColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
    }
}

// MARK: - Materials

enum Toybox {
    /// Makes surfaces breathe and jiggle like a water balloon. Strength and speed are per material.
    static let wobbleShader = """
    #pragma arguments
    float wobbleAmount;
    float wobbleSpeed;
    #pragma body
    float t = scn_frame.time * wobbleSpeed;
    float3 p = _geometry.position.xyz;
    float w = sin(t + p.y * 7.0 + p.x * 3.0) * 0.6 + sin(t * 1.37 + p.x * 6.0 - p.z * 4.0) * 0.4;
    _geometry.position.xyz += _geometry.normal * (w * wobbleAmount);
    """

    /// Glossy, soft, inflated-balloon surface.
    static func balloon(_ color: SIMD3<Float>, wobble: Float = 0.006, speed: Float = 3,
                        roughness: CGFloat = 0.28) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = Paint.platform(color)
        m.roughness.contents = NSNumber(value: Double(roughness))
        m.metalness.contents = NSNumber(value: 0.0)
        m.clearCoat.contents = NSNumber(value: 1.0)
        m.clearCoatRoughness.contents = NSNumber(value: 0.08)
        m.shaderModifiers = [.geometry: wobbleShader]
        m.setValue(NSNumber(value: wobble), forKey: "wobbleAmount")
        m.setValue(NSNumber(value: speed), forKey: "wobbleSpeed")
        return m
    }

    static func setWobble(_ material: SCNMaterial, _ amount: Float) {
        material.setValue(NSNumber(value: amount), forKey: "wobbleAmount")
    }

    static func plain(_ color: SIMD3<Float>, roughness: CGFloat = 0.6) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = Paint.platform(color)
        m.roughness.contents = NSNumber(value: Double(roughness))
        m.metalness.contents = NSNumber(value: 0.0)
        return m
    }

    static func node(_ geometry: SCNGeometry, _ material: SCNMaterial,
                     at position: SIMD3<Float> = .zero, scale: SIMD3<Float> = SIMD3(1, 1, 1)) -> SCNNode {
        geometry.materials = [material]
        let n = SCNNode(geometry: geometry)
        n.simdPosition = position
        n.simdScale = scale
        return n
    }

    // MARK: - Googly eyes

    struct Eye {
        let root: SCNNode
        let pupil: SCNNode
        let radius: Float
    }

    /// A big glossy googly eye looking along +z.
    static func eye(radius r: Float) -> Eye {
        let root = SCNNode()
        let white = node(SCNSphere(radius: CGFloat(r)), balloon(SIMD3(1, 1, 1), wobble: 0, roughness: 0.15))
        white.simdScale = SIMD3(1, 1, 0.8)
        root.addChildNode(white)

        let pupil = SCNNode()
        let iris = node(SCNSphere(radius: CGFloat(r * 0.5)), balloon(SIMD3(0.04, 0.04, 0.06), wobble: 0, roughness: 0.1))
        iris.simdScale = SIMD3(1, 1, 0.45)
        pupil.addChildNode(iris)
        let glint = SCNNode(geometry: SCNSphere(radius: CGFloat(r * 0.13)))
        let glintMaterial = SCNMaterial()
        glintMaterial.lightingModel = .constant
        glintMaterial.diffuse.contents = PlatformColor.white
        glint.geometry?.materials = [glintMaterial]
        glint.simdPosition = SIMD3(r * 0.17, r * 0.2, r * 0.22)
        pupil.addChildNode(glint)
        pupil.simdPosition = SIMD3(0, 0, r * 0.66)
        root.addChildNode(pupil)
        return Eye(root: root, pupil: pupil, radius: r)
    }

    /// Points a pupil toward a direction (local x/y, -1…1).
    static func look(_ eye: Eye, toward direction: SIMD2<Float>) {
        let d = simd_length(direction) > 1 ? simd_normalize(direction) : direction
        let x = d.x * eye.radius * 0.32
        let y = d.y * eye.radius * 0.32
        let z = sqrt(max(eye.radius * eye.radius - x * x - y * y, 0)) * 0.66
        eye.pupil.simdPosition = SIMD3(x, y, z)
    }

    /// Eyelid squash for a blink that started `t` seconds ago (1 = fully open).
    static func blinkScale(_ t: Float) -> Float {
        guard t >= 0, t < 0.16 else { return 1 }
        return t < 0.07 ? 1 - 0.9 * (t / 0.07) : 0.1 + 0.9 * ((t - 0.07) / 0.09)
    }

    /// Pouty lips facing +z.
    static func lips(radius: Float, color: SIMD3<Float>) -> SCNNode {
        let torus = SCNTorus(ringRadius: CGFloat(radius), pipeRadius: CGFloat(radius * 0.48))
        let n = node(torus, balloon(color, wobble: 0.002, roughness: 0.2))
        n.simdEulerAngles = SIMD3(Float.pi / 2, 0, 0)
        n.simdScale = SIMD3(1.15, 1, 0.8)
        let container = SCNNode()   // free to be positioned/rotated by the caller
        container.addChildNode(n)
        return container
    }

    static func blush() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = PlatformColor(red: 1, green: 0.45, blue: 0.55, alpha: 0.45)
        m.writesToDepthBuffer = false
        return m
    }

    // MARK: - Generated images

    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(ctx)
        return ctx.makeImage()
    }

    static func platformImage(_ cg: CGImage?) -> PlatformImage? {
        guard let cg else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    static func dot(ring: Bool = false) -> PlatformImage? {
        platformImage(image(width: 64, height: 64) { ctx in
            if ring {
                ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
                ctx.setLineWidth(5)
                ctx.strokeEllipse(in: CGRect(x: 6, y: 6, width: 52, height: 52))
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
                ctx.fillEllipse(in: CGRect(x: 18, y: 36, width: 12, height: 10))
            } else {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: 56, height: 56))
            }
        })
    }

    // MARK: - Particles

    private static let dotImage = dot()

    /// One-shot burst (confetti, sparkles, poofs). Removes itself.
    static func burst(in scene: SCNScene, at position: SIMD3<Float>, color: SIMD3<Float>,
                      count: CGFloat = 60, speed: CGFloat = 2.2, size: CGFloat = 0.05, gravity: Float = -3) {
        let p = SCNParticleSystem()
        p.particleImage = dotImage
        p.birthRate = count / 0.06
        p.emissionDuration = 0.06
        p.loops = false
        p.particleLifeSpan = 0.9
        p.particleLifeSpanVariation = 0.35
        p.particleVelocity = speed
        p.particleVelocityVariation = speed * 0.6
        p.spreadingAngle = 180
        p.particleSize = size
        p.particleSizeVariation = size * 0.6
        p.particleColor = Paint.platform(color)
        p.acceleration = SCNVector3(0, CGFloat(gravity), 0)
        p.dampingFactor = 1.2
        p.blendMode = .alpha
        p.isLightingEnabled = false
        let fade = CAKeyframeAnimation()
        fade.values = [1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.6, 1]
        p.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]

        let emitter = SCNNode()
        emitter.simdPosition = position
        emitter.addParticleSystem(p)
        scene.rootNode.addChildNode(emitter)
        emitter.runAction(.sequence([.wait(duration: 2.0), .removeFromParentNode()]))
    }

    static func confetti(in scene: SCNScene, at position: SIMD3<Float>) {
        for color in Paint.colors {
            burst(in: scene, at: position, color: color, count: 22, speed: 3.0, size: 0.06)
        }
    }
}
