import SwiftUI
import AVFoundation

/// Light, friendly overlay: a hint bubble, the "bring to life" countdown, camera preview, and a few buttons.
struct HUDView: View {
    @Bindable var playground: Playground
    let session: AVCaptureSession

    var body: some View {
        ZStack {
                VStack(spacing: 10) {
                    Text("Puffy Pond")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.3),
                                                    Color(red: 0.95, green: 0.35, blue: 0.65),
                                                    Color(red: 0.4, green: 0.55, blue: 1)],
                                           startPoint: .leading, endPoint: .trailing))
                        .shadow(color: .white, radius: 0, x: 0, y: 2)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                    hintBubble
                    fishChips
                    Spacer()
                }
                .padding(.top, 14)
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
                .padding(16)

                if playground.showGuide {
                    GuideCard { withAnimation(.easeOut(duration: 0.3)) { playground.showGuide = false } }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                if playground.cameraStatus == .denied || playground.cameraStatus == .unavailable {
                    CameraNotice(denied: playground.cameraStatus == .denied)
                }
        }
    }

    // MARK: Hint

    private var hintContent: (symbol: String, text: String) {
        switch playground.hint {
        case .starting: return ("camera.fill", "Waking up the camera…")
        case .raiseHands: return ("hand.raised.fill", "Raise both hands — a fish follows each one")
        case .swimming: return ("hand.pinch.fill", "Pinch to draw · rub a fish in a paint pot for a new color")
        case .pickingColor: return ("drop.fill", "Rub rub rub! Swipe through the pot to soak up the color")
        case .drawing: return ("paintbrush.pointed.fill", "Swoosh! Keep pinching and sweep your arm")
        case .erasing: return ("star.fill", "Starfish scrub! Bonk a creature to pop it")
        case .clapToLife: return ("hands.clap.fill", "Clap to bring it to life!")
        case .transforming: return ("sparkles", "Here it comes…")
        case .touchMode: return ("hand.draw.fill", "Drag to draw · double-click to bring to life")
        }
    }

    private var hintBubble: some View {
        HStack(spacing: 10) {
            ZStack {
                if playground.hint == .clapToLife && playground.lifeProgress > 0 {
                    Circle()
                        .trim(from: 0, to: playground.lifeProgress)
                        .stroke(Color.pink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                }
                Image(systemName: hintContent.symbol)
                    .font(.system(size: 16, weight: .bold))
                    .symbolEffect(.bounce, value: playground.hint)
            }
            .frame(width: 30, height: 30)
            Text(hintContent.text)
                .font(.system(size: 17, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.white.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .foregroundStyle(Color(red: 0.25, green: 0.2, blue: 0.35))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: playground.hint)
    }

    // MARK: Fish colors

    /// Each fish's current paint, so it's always clear what color you'll draw with.
    private var fishChips: some View {
        HStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { slot in
                let index = slot < playground.fishColors.count ? playground.fishColors[slot] : slot
                HStack(spacing: 8) {
                    Image(systemName: "fish.fill")
                        .font(.system(size: 15, weight: .bold))
                        .scaleEffect(x: slot == 0 ? -1 : 1, y: 1)
                    Text(Paint.names[index % Paint.names.count])
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Paint.swiftUI(Paint.colors[index % Paint.colors.count]).gradient, in: Capsule())
                .overlay(Capsule().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                .symbolEffect(.bounce, value: index)
                .phaseAnimator([1.0, 1.18, 1.0], trigger: index) { view, scale in
                    view.scaleEffect(scale)
                } animation: { _ in .spring(response: 0.22, dampingFraction: 0.5) }
                .animation(.easeInOut(duration: 0.25), value: index)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if playground.hasDrawing {
                RoundButton(symbol: "sparkles", tint: .pink) { playground.bringToLife(reason: .button) }
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
        let height: CGFloat = 110
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

private struct RoundButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tint.gradient, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(color: tint.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct GuideCard: View {
    let dismiss: () -> Void

    private struct Row: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let detail: String
        var id: String { title }
    }

    private let rows: [Row] = [
        Row(symbol: "hand.raised.fill", color: .orange, title: "Open hand = swim",
            detail: "Each hand has a Little Fish that follows you around."),
        Row(symbol: "hand.pinch.fill", color: .blue, title: "Pinch = draw",
            detail: "Hold a pinch and sweep your arm. The fish blows puffy balloon ink."),
        Row(symbol: "drop.fill", color: .mint, title: "Rub a paint pot = new color",
            detail: "Swipe a fish back and forth through a pot at the bottom until it soaks up the color."),
        Row(symbol: "star.fill", color: .pink, title: "Fist = Starfish",
            detail: "Make a fist and your fish turns into a starfish that scrubs paint away."),
        Row(symbol: "hands.clap.fill", color: .purple, title: "Clap = bring it to life",
            detail: "Your drawing inflates into a 3D balloon buddy. Or just wait a moment."),
        Row(symbol: "hand.wave.fill", color: .teal, title: "Play with them",
            detail: "Bump creatures with your fish to make them boing. A starfish pops them!"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 18) {
                Text("Let's make friends!")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                Text("Stand back so the camera sees both hands. Big, happy moves work best.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(spacing: 14) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(row.color.gradient, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.system(size: 17, weight: .bold, design: .rounded))
                            Text(row.detail).font(.system(size: 14, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Raise your hands to start · tap to close")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(28)
            .frame(maxWidth: 480)
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
        .padding(24)
        .frame(maxWidth: 360)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }
}
