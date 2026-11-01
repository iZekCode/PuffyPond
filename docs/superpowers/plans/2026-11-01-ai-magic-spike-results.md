# AI Magic spike results

**Status: Mac done. First iPad run is in and FAILS the speed gate, but it was a Debug build with reduce-memory on; re-time in Release before drawing conclusions.**

## What was run (Mac, Apple M5, 24 GB, macOS 27, Xcode 27)

`tools/magic/convert.sh` converts the models, then the Swift CLI (`StableDiffusionSample`, release build) times them with the app's settings: 4 steps, strength 0.65, guidance 1.5, `dpmpp`, `cpuAndGPU`, `--reduce-memory`, scribble ControlNet, safety checker on, 640×384.

Input was a synthetic red-line fish (start image) plus its white-on-black scribble. Prompt: the app's fish + watercolor prompt.

## Numbers

| Measure | Mac (M5) | iPad (M1+) |
|---|---|---|
| Resources on disk | 1.7 GB (6-bit) | – |
| Cold run, 1 image, incl. load | 3.8 s | 83.8 s (first run: model load + Core ML specialization) |
| Seconds per generation call, reduce-memory on | CLI ≈ 3.8 s for one image. App: **4.3–4.6 s** (45 s first call) | **8.0–9.2 s** (Debug build; 84 s first call) |
| Marginal seconds per extra image in one batch (CLI only) | ≈ 0.66 s | – |
| Peak memory footprint | 4.9 GB (CLI; max RSS 3.5 GB) | not measured yet |

**Gate:** warm ≤ 1.5 s per image and peak memory ≤ 3 GB on the iPad. **Correction:** an earlier version of this file called ≈0.66 s the warm time. That was the *marginal* cost of one more image inside a single batch call (`--image-count`); the app generates one picture per call, and in reduce-memory mode every call reloads the text encoder, ControlNet, UNet and decoder (≈ 3+ s). The real per-picture cost today is ≈ 4.4 s on the Mac app, so **the speed gate currently fails on both**. The Mac app measured in the same range as the CLI single-image run, so the chip is not the problem; model reloads are the prime suspect. Next test: `-MagicReduceMemory NO` (models stay loaded). **Memory is the other risk:** the Mac footprint is above 3 GB. Measure the iPad before trusting this.

Note that 4 steps at strength 0.65 only run **2 denoising steps** (the first 35% of the schedule is skipped), so time per image is about half of what 4 full steps would cost.

**First iPad run** (iPad Pro 13-inch M5, Xcode Debug build, `thermal 0` throughout, safety checker never blocked): 83.8 s, then 8.0 / 8.5 / 9.1 / 9.2 s. One run was cancelled by a new stroke after 4.8 s, as designed. That is 5–6× over the 1.5 s gate on a chip that should match the Mac, so something other than the chip is slow. Suspects, in order:
1. **Debug build.** The package's Swift code (scheduler, image conversion) is unoptimised. On the Mac a debug CLI looked only mildly slower, so this alone is unlikely to explain 10×.
2. **Reduced-memory mode.** It reloads the text encoder, ControlNet, UNet and decoder for every picture. The Mac keeps those files hot in its page cache; the iPad may not. Test with launch argument `-MagicReduceMemory NO` (trades memory for speed).
3. Compute units or Core ML plan caching differences on iOS.

Re-time with: scheme ▸ Run ▸ Build Configuration **Release**, then once with the default and once with `-MagicReduceMemory NO`, and note peak memory for each.

## Scheduler verdict

`dpmpp` at 4 steps gave a clean picture (a watercolor fish that follows the scribble lines; see the check below). **Task 2 (`LCMScheduler`) stays skipped.** This is one sample from a synthetic input, so judge with real drawings on the iPad.

## What the converter needed (the plan's command does not work as written)

All of this is in `tools/magic/convert.sh`:

1. Python 3.11 venv (3.15 is too new for torch/coremltools) and `scipy<1.12` (newer wheels fail to load on macOS 27).
2. Remove `variant="fp16"`: `LCM_Dreamshaper_v7` has no fp16 files and `diffusers` 0.30 raises.
3. Skip the ControlNet base-model name check (it insists on `runwayml/stable-diffusion-v1-5`; LCM Dreamshaper is an SD 1.5 derivative).
4. `--attention-implementation ORIGINAL` instead of `SPLIT_EINSUM_V2`: V2 cannot split the 3840-token (48×80) query evenly and fails in tracing. ORIGINAL is Apple's pick for GPU anyway.
5. **Drop the LCM guidance-embedding layer** (`time_embedding.cond_proj`). The converter has no input for it. The layer is bias-free, so this is the same as feeding a zero guidance embedding. Speed is unchanged, but this is a quality compromise to watch on real drawings. The Swift pipeline also has no LCM scheduler, so it runs classifier-free guidance at 1.5 on an LCM UNet.
6. **The safety checker must be converted separately at 512×512** (`--latent-h 64 --latent-w 64`; this model defaults to 768×768). Apple's Swift `SafetyChecker` feeds a fixed 512×512 dummy tensor, so a checker converted at 640×384 (or 768×768) makes every generation throw "MultiArray shape (1 x 512 x 512 x 3) does not match…". The app keeps the checker on.

ControlNet model folder: `Resources/controlnet/LllyasvielControlV11PSd15Scribble.mlmodelc` (the only one, so `MagicEngine` finds it by itself).

## Still to do (needs you)

1. Pack and host: `aa archive -d build/magic-models -o magic-v1.aar` after removing everything but `Resources/` from that folder (or archive a folder holding only `Resources/`), then fill in `MagicModelRelease.url` and `.sha256`.
2. iPad timing: cold load, warm s/image, peak memory (Xcode memory gauge) with the app on the device.
3. Eyeball picture quality with real kids' drawings.

## Device check (plan Task 7)

_Pending. Fish + jellyfish brush appears in about 2 s; erase mid-generation drops the stale result; background mid-generation does not crash; 10 minutes of painting stays at 60 fps._
