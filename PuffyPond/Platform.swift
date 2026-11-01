import SwiftUI
import SceneKit
import AVFoundation
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Everything that differs between Mac and iPhone/iPad lives here.

enum Platform {
    #if os(macOS)
    private static var awakeActivity: NSObjectProtocol?
    #endif

    /// Nobody touches the device while playing with hands — keep the display awake.
    static func keepAwake() {
        #if os(macOS)
        if awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing with hand gestures")
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    static func openCameraSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// iPad is a landscape-only, finger-sized screen; everything else (Mac, iPhone) keeps the base sizes.
    static var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    static func configure(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(HandTracker.rotationAngle) {
            connection.videoRotationAngle = HandTracker.rotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = HandTracker.mirrored
        }
    }
}

extension EnvironmentValues {
    /// How much bigger than the base sizes controls and text are drawn (1.2 on iPad).
    @Entry var uiScale: CGFloat = 1
}

extension View {
    @ViewBuilder
    func immersive() -> some View {
        #if os(iOS)
        self.statusBarHidden().persistentSystemOverlays(.hidden)
        #else
        self
        #endif
    }
}

/// Calls back once per screen refresh with the elapsed time.
final class FrameDriver: NSObject {
    var onFrame: ((Double) -> Void)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        #if os(macOS)
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) else { return }
        #else
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 1.0 / 60 : link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        onFrame?(min(dt, 1.0 / 20))
    }
}

// MARK: - 3D view

private func configure(_ view: SCNView, playground: Playground) {
    view.scene = playground.scene
    view.pointOfView = playground.cameraNode
    view.antialiasingMode = .multisampling4X
    view.rendersContinuously = true
    view.preferredFramesPerSecond = 60
    view.isPlaying = true
    view.allowsCameraControl = false
}

#if os(macOS)

struct PlaygroundView: NSViewRepresentable {
    let playground: Playground

    func makeNSView(context: Context) -> PlaygroundSCNView {
        let view = PlaygroundSCNView(frame: .zero, options: nil)
        view.playground = playground
        configure(view, playground: playground)
        return view
    }

    func updateNSView(_ nsView: PlaygroundSCNView, context: Context) {}
}

/// Mouse drag paints with the left buddy (hold ⌥ or right-drag to erase).
final class PlaygroundSCNView: SCNView {
    weak var playground: Playground?

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        playground?.layout(size: bounds.size)
    }

    private func normalized(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let y = isFlipped ? p.y / h : 1 - p.y / h
        return SIMD2(Float(p.x / w), Float(y))
    }

    override func mouseDown(with event: NSEvent) {
        playground?.pointerErases = event.modifierFlags.contains(.option)
        playground?.pointerBegan(normalized(event))
    }

    override func mouseDragged(with event: NSEvent) { playground?.pointerMoved(normalized(event)) }
    override func mouseUp(with event: NSEvent) { playground?.pointerEnded() }

    override func rightMouseDown(with event: NSEvent) {
        playground?.pointerErases = true
        playground?.pointerBegan(normalized(event))
    }

    override func rightMouseDragged(with event: NSEvent) { playground?.pointerMoved(normalized(event)) }

    override func rightMouseUp(with event: NSEvent) {
        playground?.pointerEnded()
        playground?.pointerErases = false
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = previewLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            Platform.configure(previewLayer.connection)
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

#else

struct PlaygroundView: UIViewRepresentable {
    let playground: Playground

    func makeUIView(context: Context) -> PlaygroundSCNView {
        let view = PlaygroundSCNView(frame: .zero, options: nil)
        view.playground = playground
        view.isMultipleTouchEnabled = false
        configure(view, playground: playground)
        return view
    }

    func updateUIView(_ uiView: PlaygroundSCNView, context: Context) {}
}

/// One finger paints with the left buddy; the HUD toggles erasing.
final class PlaygroundSCNView: SCNView {
    weak var playground: Playground?

    override func layoutSubviews() {
        super.layoutSubviews()
        playground?.layout(size: bounds.size)
    }

    private func normalized(_ touches: Set<UITouch>) -> SIMD2<Float>? {
        guard let touch = touches.first else { return nil }
        let p = touch.location(in: self)
        return SIMD2(Float(p.x / max(bounds.width, 1)), Float(p.y / max(bounds.height, 1)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let uv = normalized(touches) { playground?.pointerBegan(uv) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let uv = normalized(touches) { playground?.pointerMoved(uv) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { playground?.pointerEnded() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { playground?.pointerEnded() }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var rotationObserver: NSKeyValueObservation?

        override func layoutSubviews() {
            super.layoutSubviews()
            Platform.configure(previewLayer.connection)
            followDeviceRotation()
        }

        /// Keeps the preview upright when the iPad is turned between the two landscape sides.
        private func followDeviceRotation() {
            guard rotation == nil,
                  let device = (previewLayer.session?.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotation = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            rotationObserver = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.apply(angle) }
            }
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

#endif
