import SwiftUI

@main
struct PuffyPondApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}

struct ContentView: View {
    @State private var playground = Playground()
    @State private var tracker = HandTracker()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            PlaygroundView(playground: playground)
                .ignoresSafeArea()
            HUDView(playground: playground, session: tracker.session)
        }
        .immersive()
        .onAppear {
            Platform.keepAwake()
            playground.start()
            startTracking()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                playground.start()
                startTracking()
            case .background:
                tracker.stop()
                playground.pause()
            default:
                break
            }
        }
    }

    private func startTracking() {
        let playground = playground
        tracker.onFrame = { frame in playground.ingest(frame) }
        tracker.start { status in
            switch status {
            case .running: playground.cameraStatus = .running
            case .denied: playground.cameraStatus = .denied
            case .unavailable: playground.cameraStatus = .unavailable
            }
        }
    }
}
