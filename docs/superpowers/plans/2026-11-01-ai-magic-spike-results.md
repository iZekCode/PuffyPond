# AI Magic spike results

**Status: Mac half done, iPad half PENDING.** The gate needs the iPad numbers, so the verdict is still open.

## What was run (Mac, Apple M5, 24 GB, macOS 27, Xcode 27)

`tools/magic/convert.sh` converts the models, then the Swift CLI (`StableDiffusionSample`, release build) times them with the app's settings: 4 steps, strength 0.65, guidance 1.5, `dpmpp`, `cpuAndGPU`, `--reduce-memory`, scribble ControlNet, safety checker on, 640×384.

Input was a synthetic red-line fish (start image) plus its white-on-black scribble. Prompt: the app's fish + watercolor prompt.

## Numbers

| Measure | Mac (M5) | iPad (M1+) |
|---|---|---|
| Resources on disk | 1.7 GB (6-bit) | – |
| Cold run, 1 image, incl. load | 3.8 s | pending |
| Warm seconds per image | ≈ 0.66 s (5 images 6.4 s vs 1 image 3.8 s) | pending |
| Peak memory footprint | 4.9 GB (CLI; max RSS 3.5 GB) | pending |

**Gate:** warm ≤ 1.5 s per image and peak memory ≤ 3 GB on the iPad. Speed has plenty of room on the Mac. **Memory is the risk:** the Mac footprint is above 3 GB. Measure the iPad before trusting this.

Note that 4 steps at strength 0.65 only run **2 denoising steps** (the first 35% of the schedule is skipped), so time per image is about half of what 4 full steps would cost.

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
