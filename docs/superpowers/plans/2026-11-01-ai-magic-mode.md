# AI Magic Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When "Magic" is on, every time the kids pause painting, an on-device diffusion model re-imagines the canvas as an artistic picture that follows their strokes, and it crossfades in over the wet paint.

**Architecture:** Fully on-device, no server. The canvas is photographed with the existing `photographCanvas()` at 640×384. Two images come out of that photo: the colored picture (img2img start image) and a white-on-black scribble map (ControlNet input). Apple's `ml-stable-diffusion` Swift package runs an LCM-distilled SD 1.5 UNet plus a ControlNet Scribble model in 4 steps. A small state machine decides when to generate: after a stroke ends, after the canvas sits idle for a moment, and only when the canvas actually changed and nothing is already running. The result is shown on its own SceneKit plane just in front of the paint, and crossfades in.

**Tech Stack:** Swift 6 / SwiftUI / SceneKit (existing), `apple/ml-stable-diffusion` Swift package (product `StableDiffusion`), Core ML, AppleArchive for unpacking the model download, Swift Testing.

**Spec:** this conversation (no separate spec). Requirements: on-device diffusion "AI magic" mode, SDXS/SD-Turbo-class speed, ControlNet scribble, generate on pen-up and crossfade, not every frame, M1+ iPad with ≥ 8 GB RAM, model (~1–2 GB) downloaded separately rather than bundled.

## Model choice (decided)

| Part | Model | Why |
|---|---|---|
| Base UNet | `SimianLuo/LCM_Dreamshaper_v7` (SD 1.5 + LCM distillation) | Good in 4 steps. SD 1.5 is what the scribble ControlNet is trained on. Its license (CreativeML OpenRAIL-M) allows shipping. |
| ControlNet | `lllyasviel/control_v11p_sd15_scribble` | Keeps the kids' lines as the structure of the picture. |
| Rejected | SD-Turbo / SDXS | SD 2.1-based, with no mature scribble ControlNet. SD-Turbo also has a more restrictive license. Revisit only if Task 1 fails the speed gate. |

## Global Constraints

- App deployment target stays iOS 17.0 / macOS (current). Magic is an optional feature behind `MagicSupport.isSupported`.
- iOS: Magic is only offered when `ProcessInfo.processInfo.physicalMemory >= 8 * 1024 * 1024 * 1024` and the GPU supports `MTLGPUFamily.apple7` (M1 or newer). Mac: Apple silicon only.
- Fixed generation size: 640×384 px (latent 80×48), matching the canvas aspect `Playground.canvasSize` 6.4 : 4.0.
- 4 LCM steps, guidance scale 1.5, img2img strength 0.65, ControlNet conditioning scale 0.9, seed fixed per painting.
- Prompts are built by the app only. There is never a free-text prompt (kids app). The safety checker stays enabled (`disableSafety: false`).
- Model files are never bundled in the app. They are downloaded into `Application Support/MagicModels/<version>/`.
- Generation never blocks the frame loop. All model work runs off the main actor.

## Review Focus

1. **Canvas changes while a generation runs** (erase, clear, hang in gallery). The stale result must be dropped, not shown. Pinned in Task 4 (`staleResultIsDropped`) and Task 6 (overlay hidden on clear).
2. **App goes to background mid-generation.** Generation is cancelled and the overlay stays as it was. iOS kills GPU work in the background. Pinned in Task 4 (`pauseCancelsRunning`).
3. **Model missing, half-downloaded or corrupt.** Magic shows as "needs download", never crashes. Pinned in Task 5 (`partialDownloadIsNotReady`).
4. **Empty canvas or only template dots.** No generation. Pinned in Task 3 (`blankCanvasHasNoScribble`).
5. **Memory pressure / thermal throttling on an 8 GB iPad.** Resources are released when Magic is turned off, and generation is skipped while `thermalState >= .serious`. Pinned in Task 4 (`seriousThermalStateSkips`).

---

### Task 1: Spike — convert the models and measure speed (go / no-go)

No app code. This decides whether the rest of the plan runs as written.

**Files:**
- Create: `tools/magic/convert.sh`
- Create: `docs/superpowers/plans/2026-11-01-ai-magic-spike-results.md`

- [ ] **Step 1: Write `tools/magic/convert.sh`.** It clones `apple/ml-stable-diffusion` into a venv and runs:

```bash
python -m python_coreml_stable_diffusion.torch2coreml \
  --model-version SimianLuo/LCM_Dreamshaper_v7 \
  --convert-unet --unet-support-controlnet --convert-text-encoder \
  --convert-vae-encoder --convert-vae-decoder --convert-safety-checker \
  --convert-controlnet lllyasviel/control_v11p_sd15_scribble \
  --latent-h 48 --latent-w 80 \
  --attention-implementation SPLIT_EINSUM_V2 \
  --quantize-nbits 6 \
  --bundle-resources-for-swift-cli \
  -o build/magic-models
```

- [ ] **Step 2: Run it on the Mac.** Expected: `build/magic-models/Resources/` contains `Unet.mlmodelc`, `ControlledUnet.mlmodelc` (or `Unet` with control inputs), `controlnet/…scribble.mlmodelc`, `TextEncoder.mlmodelc`, `VAEEncoder.mlmodelc`, `VAEDecoder.mlmodelc`, `SafetyChecker.mlmodelc`, `vocab.json`, `merges.txt`. Total size about 1.2–1.6 GB.
- [ ] **Step 3: Time it with the Swift CLI on the Mac.** Use `swift run StableDiffusionSample` with `--image`, `--strength 0.65`, `--controlnet`, `--step-count 4`, scheduler `dpmpp`. Record the seconds per image.
- [ ] **Step 4: Time it on the target iPad.** Use a throwaway SwiftUI test view that loads the same resources with `StableDiffusionPipeline` and `.cpuAndGPU` compute units. Record the cold load time, the warm seconds per image, and the peak memory (Xcode memory gauge).
- [ ] **Step 5: Check whether `dpmpp` at 4 steps on an LCM model gives clean pictures.** If the pictures are muddy, Task 2 (`LCMScheduler`) is required. If they are clean, skip Task 2 and use `.dpmSolverMultistepScheduler`.
- [ ] **Step 6: Write the results file** with the numbers and a verdict. **Gate:** warm time ≤ 1.5 s per image and peak memory ≤ 3 GB on the iPad. If it fails, stop here and report back. The fallback plans are to drop ControlNet (img2img only) or to switch to SDXS-512 without ControlNet.
- [ ] **Step 7: Commit** `tools/magic/convert.sh` and the results file (not the models). Add `build/` to `.gitignore`.

### Task 2: `LCMScheduler` (only if Task 1 step 5 says so)

**Files:**
- Create: `PuffyPond/Magic/LCMScheduler.swift`
- Create: `PuffyPondTests/LCMSchedulerTests.swift` (also add the `PuffyPondTests` Swift Testing unit test target in Xcode: File ▸ New ▸ Target ▸ Unit Testing Bundle, host app PuffyPond)
- Modify: `PuffyPond.xcodeproj/project.pbxproj` (add the SPM package `https://github.com/apple/ml-stable-diffusion`, product `StableDiffusion`, latest 1.x tag)

**Interfaces:**
- Produces: `final class LCMScheduler: Scheduler` (the protocol from the `StableDiffusion` package), `init(stepCount: Int, trainStepCount: Int = 1000, originalSteps: Int = 50)`. It is used by Task 5 through a custom pipeline configuration hook. If the package's `StableDiffusionScheduler` enum cannot take a custom scheduler, fork the package and add `case lcmScheduler`, and note the fork in the results file.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func timestepsForFourSteps() {
    #expect(LCMScheduler(stepCount: 4).timeSteps == [999, 759, 519, 279])
}
// Use the strength-to-timesteps method name the package's `Scheduler` protocol actually declares.
@Test func img2imgStrengthSkipsEarlySteps() {
    // strength 0.65 starts partway: the first kept timestep is ≤ 650
    #expect(LCMScheduler(stepCount: 4).calculateTimesteps(strength: 0.65).first! <= 650)
}
@Test func finalStepReturnsDenoisedSample() { /* step() with alpha_cumprod of last t → output equals predicted x0 within 1e-3 */ }
```

- [ ] **Step 2: Run it and check it fails.** Run: `xcodebuild test -project PuffyPond.xcodeproj -scheme PuffyPond -destination 'platform=macOS' -only-testing:PuffyPondTests/LCMSchedulerTests`. Expected: FAIL, `LCMScheduler` not found.
- [ ] **Step 3: Implement it.** Port diffusers' `LCMScheduler`: scaled-linear betas (0.00085 to 0.012), origin timesteps `(1...50).map { $0 * 20 - 1 }` reversed, taken every `50 / stepCount`, and the boundary-condition scalings `c_skip`/`c_out` with `timestep_scaling = 10`. Noise is re-injected between steps from the seeded generator the pipeline passes in.
- [ ] **Step 4: Run it and check it passes.** Same command. Expected: PASS.
- [ ] **Step 5: Commit** (`feat: add LCM scheduler for 4-step magic`).

### Task 3: Canvas → model inputs (`MagicPrompt`, `ScribbleMap`)

Pure code with no models, so it is quick to test.

**Files:**
- Create: `PuffyPond/Magic/MagicPrompt.swift`
- Create: `PuffyPond/Magic/ScribbleMap.swift`
- Test: `PuffyPondTests/MagicInputTests.swift`
- If Task 2 was skipped, also do its setup here: add the `PuffyPondTests` Swift Testing target and the `ml-stable-diffusion` SPM package (see Task 2 Files).

**Interfaces:**
- Produces:
  - `struct MagicPrompt { let positive: String; let negative: String; static func make(template: TemplateKind?, brushes: [CritterKind]) -> MagicPrompt }`
  - `struct MagicInputs { let start: CGImage; let scribble: CGImage; let fingerprint: [UInt8] }`. `fingerprint` is a 16×10 grayscale thumbnail.
  - `enum ScribbleMap { static func make(painted: CGImage, blank: CGImage, size: CGSize = CGSize(width: 640, height: 384)) -> MagicInputs?; static func difference(_ a: [UInt8], _ b: [UInt8]) -> Float }`. It returns nil when no scribble pixel is found. `difference` is the mean absolute difference, from 0 to 1.

Prompt table (exact copy):

| Input | Fragment |
|---|---|
| template `.fish` | `"a cute colorful fish"` |
| template `.turtle` | `"a friendly sea turtle"` |
| template `.duck` | `"a little yellow duck"` |
| no template | `"a magical underwater pond scene"` |
| `.jellyfish` brush present | `", soft watercolor"` |
| `.snail` | `", thick impasto oil paint"` |
| `.seahorse` | `", elegant ink calligraphy"` |
| `.pufferfish` | `", playful splatter art"` |
| `.frog` | `", dotted pointillism"` |
| `.octopus` | `", bold gouache brushwork"` |
| always appended | `", children's book illustration, bright, whimsical, high quality"` |
| negative (fixed) | `"scary, dark, violent, blood, text, watermark, ugly, blurry, realistic photo"` |

Brush fragments follow the order of `brushes`, with duplicates removed.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func fishWithWatercolor() {
    let p = MagicPrompt.make(template: .fish, brushes: [.jellyfish, .jellyfish])
    #expect(p.positive == "a cute colorful fish, soft watercolor, children's book illustration, bright, whimsical, high quality")
}
@Test func noTemplateTwoBrushes() {
    #expect(MagicPrompt.make(template: nil, brushes: [.octopus, .frog]).positive
        == "a magical underwater pond scene, bold gouache brushwork, dotted pointillism, children's book illustration, bright, whimsical, high quality")
}
@Test func blankCanvasHasNoScribble() {
    let blank = solidImage(.init(gray: 0.9), 640, 384)
    #expect(ScribbleMap.make(painted: blank, blank: blank) == nil)
}
@Test func redLineBecomesWhiteScribble() {
    // painted = blank + 8 px red horizontal line at y = 192
    let inputs = try #require(ScribbleMap.make(painted: withLine, blank: blank))
    #expect(pixel(inputs.scribble, 320, 192) == 255)   // line → white
    #expect(pixel(inputs.scribble, 320, 50) == 0)      // empty canvas → black
    #expect(inputs.start.width == 640 && inputs.start.height == 384)
}
@Test func differenceOfIdenticalIsZero() { #expect(ScribbleMap.difference(f, f) == 0) }
```

(`solidImage` and `pixel` are small helpers in the test file that use `CGContext`.)

- [ ] **Step 2: Run them and check they fail.** Run with `-only-testing:PuffyPondTests/MagicInputTests`. Expected: FAIL, the types are missing.
- [ ] **Step 3: Implement it.** `ScribbleMap.make` draws both images into 640×384 RGBA `CGContext`s. A pixel is scribble when the per-channel max |painted − blank| > 0.12. Dilate by 1 px and output an 8-bit gray image. The canvas weave and lighting are identical in both photos, so they cancel out.
- [ ] **Step 4: Run them and check they pass.** Expected: PASS.
- [ ] **Step 5: Commit** (`feat: turn canvas photo into magic prompt and scribble`).

### Task 4: When to generate (`MagicDirector`)

A pure state machine with an injected clock. It owns all the "should we?" decisions.

**Files:**
- Create: `PuffyPond/Magic/MagicDirector.swift`
- Test: `PuffyPondTests/MagicDirectorTests.swift`

**Interfaces:**
- Produces:

```swift
struct MagicDirector {
    enum Action: Equatable { case none, generate(version: Int) }
    static let idleDelay: Double = 0.45          // s after the last stroke ends
    static let minChange: Float = 0.01           // fingerprint difference that counts as "changed"
    private(set) var canvasVersion = 0
    private(set) var isRunning = false
    mutating func canvasChanged(at time: Double)              // stroke ended / erase / clear
    mutating func tick(at time: Double, fingerprint: () -> [UInt8]?, thermal: ProcessInfo.ThermalState) -> Action
    mutating func finished(version: Int) -> Bool              // true = result still matches the canvas, show it
    mutating func pause()                                     // background / Magic off: cancels running
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func waitsForIdle() { canvasChanged(at: 0); #expect(tick(at: 0.3) == .none); #expect(tick(at: 0.5) == .generate(version: 1)) }
@Test func neverTwoAtOnce() { /* generate at 0.5, change at 0.6, tick at 1.2 → .none while running */ }
@Test func unchangedFingerprintSkips() { /* finished(1), change, tick with same fingerprint → .none */ }
@Test func staleResultIsDropped() { /* generate v1, canvasChanged, finished(version: 1) == false */ }
@Test func pauseCancelsRunning() { /* generate, pause() → isRunning == false, finished(version: 1) == false */ }
@Test func seriousThermalStateSkips() { #expect(tick(at: 1, thermal: .serious) == .none) }
@Test func nilFingerprintSkips() { /* blank canvas → fingerprint returns nil → .none */ }
```

- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement it.** The fingerprint closure is only called once the idle delay has passed, so the canvas photo is not taken every frame.
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Commit** (`feat: decide when magic should generate`).

### Task 5: Model download and engine (`MagicModelStore`, `MagicEngine`, `MagicSupport`)

**Files:**
- Create: `PuffyPond/Magic/MagicSupport.swift`
- Create: `PuffyPond/Magic/MagicModelStore.swift`
- Create: `PuffyPond/Magic/MagicEngine.swift`
- Test: `PuffyPondTests/MagicModelStoreTests.swift`
- The project uses a generated Info.plist (`GENERATE_INFOPLIST_FILE = YES`), so the release details live in code instead: `enum MagicModelRelease { static let version = "lcm-dreamshaper7-scribble-640x384-v1"; static let url: URL; static let sha256: String }` in `MagicModelStore.swift`.

**Interfaces:**
- Consumes: `MagicInputs`, `MagicPrompt` (Task 3), `LCMScheduler` (Task 2, if built).
- Produces:

```swift
enum MagicSupport { static var isSupported: Bool }      // RAM + GPU family rule from Global Constraints

@Observable final class MagicModelStore {
    enum State: Equatable { case notDownloaded, downloading(progress: Double), ready(URL), failed(String) }
    private(set) var state: State
    init(root: URL = .applicationSupportDirectory.appending(path: "MagicModels"), version: String, remote: URL, sha256: String)
    func download() async                              // URLSession download → verify SHA256 → AppleArchive extract to <root>/<version>.partial → rename to <root>/<version>
    func delete()
}

actor MagicEngine {
    init(resources: URL)
    func load() async throws                           // StableDiffusionPipeline(resourcesAt:controlNet:[<scribble model name>], configuration: .cpuAndGPU, reduceMemory: true) then loadResources(). Copy the exact name from the `controlnet/` folder Task 1 produced (recorded in the spike results); the converter renames it.
    func generate(_ inputs: MagicInputs, prompt: MagicPrompt, seed: UInt32) async throws -> CGImage?   // nil = safety checker blocked it
    func unload()
}
```

- [ ] **Step 1: Write the failing tests** for the store (the engine needs real models and is checked by hand in Task 7):

```swift
@Test func readyOnlyWhenFinalFolderExists() { /* create <root>/<version>/Resources/vocab.json → state == .ready */ }
@Test func partialDownloadIsNotReady() { /* only <root>/<version>.partial exists → state == .notDownloaded, and the partial folder is deleted on init */ }
@Test func wrongChecksumFails() { /* download() from a file:// URL with a mismatched sha → state == .failed, no final folder */ }
```

- [ ] **Step 2: Run them and check they fail.**
- [ ] **Step 3: Implement `MagicSupport`, `MagicModelStore` and `MagicEngine`.** Generation config: `stepCount 4`, `guidanceScale 1.5`, `strength 0.65`, `startingImage inputs.start`, `controlNetInputs [inputs.scribble]`, `seed`, `disableSafety false`, the scheduler from Task 1's verdict. `generate` checks `Task.isCancelled` in the pipeline's progress handler and returns early when it is set.
- [ ] **Step 4: Run them and check they pass.**
- [ ] **Step 5: Upload the archive.** Pack Task 1's `Resources` with `aa archive -d build/magic-models/Resources -o magic-v1.aar`, upload it (GitHub release asset or similar), and fill in `MagicModelRelease.url` and `.sha256`. Ask the user where to host it before uploading.
- [ ] **Step 6: Commit** (`feat: download and run the on-device magic model`).

### Task 6: Hook into the playground (overlay, toggle, gallery)

**Files:**
- Create: `PuffyPond/Magic/MagicOverlay.swift`
- Create: `PuffyPond/Magic/MagicController.swift`
- Modify: `PuffyPond/Playground.swift`. Add `magic` and call it from `finishStroke(slot:)`, `erase(with:now:)` (only when `erasedAny`), `clearCanvas()`, `tick(dt:)`, and `pause()`. Add a `pixels:` parameter to `photographCanvas()` (default 1920) and photograph the blank board once after `buildWorld()`.
- Modify: `PuffyPond/HUDView.swift`. Add a "Magic" toggle chip, shown only when `MagicSupport.isSupported`, with a download progress ring and a small sparkle spinner while generating.
- Modify: `PuffyPond/ContentView.swift`. Create `MagicModelStore` and pass it to the HUD.

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:

```swift
final class MagicOverlay {                                 // SCNPlane the size of Playground.canvasSize at canvasZ + 0.003
    let node: SCNNode
    func show(_ image: CGImage, fade: Double = 0.6)        // crossfade: the old image stays under until the new one is opaque
    func hide(fade: Double = 0.3)
}
@MainActor final class MagicController {
    var isOn: Bool                                         // turning off → director.pause(), overlay.hide(), engine.unload()
    var isGenerating: Bool { get }
    init(overlay: MagicOverlay, store: MagicModelStore, photograph: @escaping (CGFloat) -> CGImage?, blank: @escaping () -> CGImage?, context: @escaping () -> (TemplateKind?, [CritterKind]))
    func canvasChanged(at time: Double)
    func cleared()                                         // canvasChanged + overlay.hide()
    func tick(at time: Double)
    func pause()
}
```

- [ ] **Step 1: Implement `MagicOverlay` and `MagicController`.** The controller runs `MagicDirector`. On `.generate(version:)` it photographs at 640 px wide, builds the inputs with `ScribbleMap.make(painted:blank:)`, and runs `engine.generate` in a `Task`. It calls `overlay.show` only when `director.finished(version:)` is true. The seed comes from a new `Playground.paintingNumber: Int` that `clearCanvas()` increments: `UInt32(truncatingIfNeeded: paintingNumber)`. It stays the same within one painting, so the picture does not jump around between generations.
- [ ] **Step 2: Wire `Playground` and the HUD** as listed under Files. `finishPainting()` keeps photographing the paint, not the AI image. Hanging AI pictures in the gallery is out of scope.
- [ ] **Step 3: Build for both platforms.** Run `xcodebuild build -scheme PuffyPond -destination 'platform=macOS'` and `-destination 'generic/platform=iOS'`. Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Run the full test suite.** Expected: all pass.
- [ ] **Step 5: Commit** (`feat: magic mode re-imagines the canvas on pen-up`).

### Task 7: On-device check

- [ ] **Step 1: Test on the iPad (M1+).** Download the model, turn Magic on, trace the fish template with the jellyfish brush, and pause. Expected: a watercolor fish fades in within about 2 s and follows the traced lines.
- [ ] **Step 2: Erase part of the drawing while it is generating.** Expected: that result never appears, and a new one follows.
- [ ] **Step 3: Background the app mid-generation, then come back.** Expected: no crash, and Magic resumes on the next stroke.
- [ ] **Step 4: Paint continuously for 10 minutes.** Watch the frame rate (should stay at 60 fps while painting) and the thermal state. Write the results under "Device check" in the spike results file.
- [ ] **Step 5: Commit** the results.
