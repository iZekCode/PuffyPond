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
    @State private var gallery = Gallery()
    @State private var magicStore = MagicModelStore()
    /// Which painting the gallery opens on; nil while at the easel.
    @State private var visit: GalleryVisit?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            PlaygroundView(playground: playground)
                .ignoresSafeArea()
            HUDView(playground: playground, session: tracker.session, magicStore: magicStore,
                    paintingCount: gallery.paintings.count, finish: hangPainting, openGallery: { open(GalleryVisit(index: 0, justHung: false)) })
            if let visit {
                GalleryView(gallery: gallery, startAt: visit.index, justHung: visit.justHung) { open(nil) }
                    .transition(.opacity)
            }
        }
        .immersive()
        .environment(\.uiScale, Platform.isPad ? 1.2 : 1)
        .onAppear {
            Platform.keepAwake()
            playground.setUpMagic(store: magicStore)
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

    /// Photographs the painting off the easel and walks over to see it hanging in the gallery.
    private func hangPainting() {
        guard let photo = playground.finishPainting(), gallery.add(photo) != nil else { return }
        open(GalleryVisit(index: 0, justHung: true))
    }

    private func open(_ next: GalleryVisit?) {
        playground.isAway = next != nil
        withAnimation(.easeInOut(duration: 0.45)) { visit = next }
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

private struct GalleryVisit {
    let index: Int
    let justHung: Bool
}
