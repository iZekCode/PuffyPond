import SwiftUI
import AVFoundation

/// Light, friendly overlay: a hint bubble, camera preview, and a few buttons.
struct HUDView: View {
    @Bindable var playground: Playground
    let session: AVCaptureSession
    let magicStore: MagicModelStore
    let paintingCount: Int
    let finish: () -> Void
    let openGallery: () -> Void

    @Environment(\.uiScale) private var scale

    /// The iPad is wide and short: the title and the two buddy chips share one row so the hint fits
    /// in the free strip above the canvas.
    private var onePieceHeader: Bool { Platform.isPad }

    var body: some View {
        ZStack {
                VStack(spacing: 10 * scale) {
                    if onePieceHeader {
                        HStack(alignment: .center, spacing: 24 * scale) {
                            colorChip(slot: 0).frame(maxWidth: .infinity, alignment: .trailing)
                            title
                            colorChip(slot: 1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 24 * scale)
                        hintBubble
                    } else {
                        title
                        hintBubble
                        colorChips
                    }
                    Spacer()
                }
                .padding(.top, (onePieceHeader ? 8 : 14) * scale)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        if playground.showCameraPreview && playground.cameraStatus == .running {
                            cameraPreview
                        }
                        Spacer()
                        controls
                    }
                }
                .padding(16 * scale)

                if playground.showGuide {
                    GuideCard { withAnimation(.easeOut(duration: 0.3)) { playground.showGuide = false } }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                if playground.cameraStatus == .denied || playground.cameraStatus == .unavailable {
                    CameraNotice(denied: playground.cameraStatus == .denied)
                }
        }
    }

    private var title: some View {
        Text("Puffy Pond")
            .font(.system(size: 30 * scale, weight: .black, design: .rounded))
            .foregroundStyle(
                LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.3),
                                        Color(red: 0.95, green: 0.35, blue: 0.65),
                                        Color(red: 0.4, green: 0.55, blue: 1)],
                               startPoint: .leading, endPoint: .trailing))
            .shadow(color: .white, radius: 0, x: 0, y: 2)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            .fixedSize()
    }

    // MARK: Hint

    private var hintContent: (symbol: String, text: String) {
        switch playground.hint {
        case .starting: return ("camera.fill", "Waking up the camera…")
        case .raiseHands: return ("hand.raised.fill", "Raise both hands — a brush animal follows each one")
        case .swimming: return ("hand.pinch.fill", "Pinch to draw · rub a pot for a color, a bubble for a new animal")
        case .pickingColor: return ("drop.fill", "Rub rub rub! Swipe through the pot to soak up the color")
        case .drawing: return ("paintbrush.pointed.fill", "Swoosh! Keep pinching and sweep your arm")
        case .erasing: return ("star.fill", "Starfish scrub! Wipe the paint away")
        case .readyToHang: return ("photo.artframe", "All done? Tap the frame to hang it in the gallery")
        case .tracing: return ("scribble.variable", "Pinch and follow the dotted line · fist to wipe it away")
        case .touchMode: return ("hand.draw.fill", "Drag to draw · tap the frame when you're done")
        }
    }

    private var hintBubble: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: hintContent.symbol)
                .font(.system(size: 16 * scale, weight: .bold))
                .symbolEffect(.bounce, value: playground.hint)
                .frame(width: 30 * scale, height: 30 * scale)
            Text(hintContent.text)
                .font(.system(size: 17 * scale, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 10 * scale)
        .background(.white.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .foregroundStyle(Color(red: 0.25, green: 0.2, blue: 0.35))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: playground.hint)
    }

    // MARK: Buddy colors

    /// Each buddy's current paint and brush animal, so it's always clear what you'll draw with.
    private var colorChips: some View {
        HStack(spacing: 10 * scale) {
            colorChip(slot: 0)
            colorChip(slot: 1)
        }
    }

    private func colorChip(slot: Int) -> some View {
        let index = slot < playground.buddyColors.count ? playground.buddyColors[slot] : slot
        let kind = slot < playground.buddyKinds.count ? playground.buddyKinds[slot] : .octopus
        return HStack(spacing: 8 * scale) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15 * scale, weight: .bold))
            Text("\(Paint.names[index % Paint.names.count]) \(kind.name)")
                .font(.system(size: 14 * scale, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 7 * scale)
        .background(Paint.swiftUI(Paint.colors[index % Paint.colors.count]).gradient, in: Capsule())
        .overlay(Capsule().stroke(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .symbolEffect(.bounce, value: index)
        .symbolEffect(.bounce, value: kind)
        .phaseAnimator([1.0, 1.18, 1.0], trigger: index) { view, scale in
            view.scaleEffect(scale)
        } animation: { _ in .spring(response: 0.22, dampingFraction: 0.5) }
        .animation(.easeInOut(duration: 0.25), value: index)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10 * scale) {
            if let magic = playground.magic {
                MagicButton(magic: magic, store: magicStore)
            }
            if playground.hasDrawing {
                RoundButton(symbol: "photo.artframe", tint: .pink, action: finish)
            }
            if paintingCount > 0 {
                RoundButton(symbol: "building.columns.fill", tint: .orange, action: openGallery)
            }
            #if os(iOS)
            RoundButton(symbol: playground.pointerErases ? "star.fill" : "paintbrush.pointed.fill",
                        tint: playground.pointerErases ? .orange : .blue) {
                playground.pointerErases.toggle()
            }
            #endif
            RoundButton(symbol: playground.musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill", tint: .purple) {
                playground.toggleMusic()
            }
            RoundButton(symbol: playground.showCameraPreview ? "video.fill" : "video.slash.fill", tint: .teal) {
                playground.showCameraPreview.toggle()
            }
            RoundButton(symbol: "questionmark", tint: .indigo) {
                withAnimation { playground.showGuide = true }
            }
            RoundButton(symbol: "arrow.counterclockwise", tint: .red) { playground.clearAll() }
        }
    }

    // MARK: Camera preview

    private var cameraPreview: some View {
        // The strip under the canvas on a landscape iPad is short, so the preview is too.
        let height: CGFloat = Platform.isPad ? 88 : 110
        let width = height * max(playground.imageAspect, 0.3)
        return ZStack {
            CameraPreview(session: session)
            Canvas { context, size in
                for hand in playground.previewHands {
                    for joint in hand {
                        let p = CGPoint(x: joint.x * size.width, y: joint.y * size.height)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                                     with: .color(.white))
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .allowsHitTesting(false)
    }
}

struct RoundButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18 * scale, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46 * scale, height: 46 * scale)
                .background(tint.gradient, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: tint.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }
}

/// Turns Magic on and off. Before the model is downloaded it downloads it, with a progress ring.
private struct MagicButton: View {
    let magic: MagicController
    let store: MagicModelStore
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: tapped) {
            ZStack {
                Image(systemName: failed ? "exclamationmark.arrow.triangle.2.circlepath" : "sparkles")
                    .font(.system(size: 18 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46 * scale, height: 46 * scale)
                    .background(Color.cyan.gradient.opacity(lit ? 1 : 0.55), in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    .symbolEffect(.variableColor.iterative, isActive: magic.isGenerating)
                if case .downloading(let progress) = store.state {
                    Circle()
                        .trim(from: 0, to: max(progress, 0.03))
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 38 * scale, height: 38 * scale)
                }
            }
            .shadow(color: Color.cyan.opacity(lit ? 0.6 : 0.3), radius: lit ? 10 : 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var failed: Bool {
        if case .failed = store.state { return true }
        return false
    }

    private var lit: Bool {
        if case .ready = store.state { return magic.isOn }
        return false
    }

    private var label: String {
        switch store.state {
        case .notDownloaded: return "Download Magic"
        case .downloading: return "Downloading Magic"
        case .ready: return magic.isOn ? "Turn Magic off" : "Turn Magic on"
        case .failed(let message): return "Magic download failed: \(message). Tap to retry"
        }
    }

    private func tapped() {
        switch store.state {
        case .notDownloaded, .failed:
            Task { await store.download() }
        case .downloading:
            break
        case .ready:
            magic.isOn.toggle()
        }
    }
}

private struct GuideCard: View {
    let dismiss: () -> Void
    @Environment(\.uiScale) private var scale

    private struct Row: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let detail: String
        var id: String { title }
    }

    private let rows: [Row] = [
        Row(symbol: "hand.raised.fill", color: .orange, title: "Open hand = swim",
            detail: "Each hand has a brush animal that follows you around."),
        Row(symbol: "hand.pinch.fill", color: .blue, title: "Pinch = draw",
            detail: "Hold a pinch and sweep your arm. Every animal paints its own way."),
        Row(symbol: "drop.fill", color: .mint, title: "Rub a paint pot = new color",
            detail: "Swipe your critter back and forth through a pot at the bottom until it soaks up the color."),
        Row(symbol: "sparkles", color: .indigo, title: "Rub a bubble = new brush animal",
            detail: "Octopus bundle brush, snail palette knife, puffer splatter, seahorse calligraphy, jelly watercolor, frog prints."),
        Row(symbol: "star.fill", color: .pink, title: "Fist = Starfish",
            detail: "Make a fist and your critter turns into a starfish that scrubs paint away."),
        Row(symbol: "photo.artframe", color: .purple, title: "All done? Hang it up",
            detail: "Tap the frame and your painting goes into the gallery, where the critters come to admire it."),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 18 * scale) {
                Text("Let's make friends!")
                    .font(.system(size: 30 * scale, weight: .black, design: .rounded))
                Text("Stand back so the camera sees both hands. Big, happy moves work best.")
                    .font(.system(size: 15 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28 * scale, alignment: .top),
                                         count: Platform.isPad ? 2 : 1),
                          alignment: .leading, spacing: 18 * scale) {
                    ForEach(rows) { row in
                        HStack(spacing: 14 * scale) {
                            Image(systemName: row.symbol)
                                .font(.system(size: 22 * scale, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 48 * scale, height: 48 * scale)
                                .background(row.color.gradient, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                                Text(row.detail).font(.system(size: 14 * scale, design: .rounded)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("Raise your hands to start · tap to close")
                    .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(28 * scale)
            .frame(maxWidth: Platform.isPad ? 900 : 480)
            .background(.white, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(Color.pink.opacity(0.3), lineWidth: 4))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            .foregroundStyle(Color(red: 0.25, green: 0.2, blue: 0.35))
            .padding(24)
            .onTapGesture(perform: dismiss)
        }
    }
}

private struct CameraNotice: View {
    let denied: Bool
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.largeTitle)
            Text(denied ? "Camera access is off" : "No camera found")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(denied
                 ? "Puffy Pond needs the camera to see your hands. Video never leaves your device. You can still draw with the mouse or your finger."
                 : "You can still draw with the mouse or your finger.")
                .font(.system(size: 14, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if denied {
                Button("Open Settings") { Platform.openCameraSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24 * scale)
        .frame(maxWidth: 360 * scale)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }
}
