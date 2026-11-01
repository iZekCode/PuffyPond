import SceneKit

/// The AI picture, on its own plane just in front of the wet paint. Two planes make a crossfade:
/// the old picture stays underneath until the new one is fully opaque.
final class MagicOverlay {
    let node = SCNNode()
    /// Whether a picture is on show (or fading in).
    private(set) var isShowing = false

    private let back = SCNNode()
    private let front = SCNNode()
    private var current: CGImage?

    init(center: SIMD2<Float> = SIMD2(0, 0.1), size: SIMD2<Float> = Playground.canvasSize,
         z: Float = Playground.canvasZ + 0.003) {
        for plane in [back, front] {
            let geometry = SCNPlane(width: CGFloat(size.x), height: CGFloat(size.y))
            let material = SCNMaterial()
            material.lightingModel = .constant            // the picture's own colors, whatever the studio lights do
            material.writesToDepthBuffer = false
            material.blendMode = .alpha
            geometry.materials = [material]
            plane.geometry = geometry
            plane.opacity = 0
            plane.isHidden = true
            plane.renderingOrder = 5
            node.addChildNode(plane)
        }
        node.simdPosition = SIMD3(center.x, center.y, z)
    }

    /// Crossfades to a new picture.
    func show(_ image: CGImage, fade: Double = 0.6) {
        front.removeAllActions()
        back.removeAllActions()
        if let current {
            Self.set(back, current)
            back.opacity = 1
            back.isHidden = false
        }
        Self.set(front, image)
        front.opacity = 0
        front.isHidden = false
        current = image
        isShowing = true
        let back = back
        front.runAction(.fadeOpacity(to: 1, duration: fade)) { back.isHidden = true }
    }

    func hide(fade: Double = 0.3) {
        current = nil
        isShowing = false
        for plane in [back, front] {
            plane.removeAllActions()
            let plane = plane
            plane.runAction(.fadeOpacity(to: 0, duration: fade)) { plane.isHidden = true }
        }
    }

    private static func set(_ plane: SCNNode, _ image: CGImage) {
        plane.geometry?.firstMaterial?.diffuse.contents = image
    }
}
