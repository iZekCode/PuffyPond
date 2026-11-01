# AI Magic spike results

**Status: PENDING.** Task 1 needs the Core ML conversion (several GB of downloads, hours of CPU) and timing on a real M1+ iPad. It was not run in the session that built the rest of the plan, so the speed gate below is unverified.

## What to run

1. `tools/magic/convert.sh`
2. Time it on the Mac with `swift run StableDiffusionSample` (`--image`, `--strength 0.65`, `--controlnet`, `--step-count 4`, scheduler `dpmpp`).
3. Time it on the iPad: cold load, warm seconds per image, peak memory.
4. Check whether `dpmpp` at 4 steps on this LCM model is clean. If muddy, build the `LCMScheduler` (plan Task 2).
5. Check that `Resources/controlnet/` holds exactly one `.mlmodelc` (the engine finds it by itself), then pack with `aa archive -d build/magic-models -o magic-v1.aar` (so the archive holds `Resources/…`), host it, and fill in `MagicModelRelease.url` and `.sha256` in `MagicModelStore.swift`.

## Gate

Warm time ≤ 1.5 s per image and peak memory ≤ 3 GB on the iPad. If it fails, fall back to img2img without ControlNet, or SDXS-512 without ControlNet.

## Numbers

| Measure | Mac | iPad |
|---|---|---|
| Cold load | | |
| Warm s / image | | |
| Peak memory | | |

Scheduler verdict: _(dpmpp clean / needs LCMScheduler)_

## Device check (plan Task 7)

_Pending. Fish + jellyfish brush appears in about 2 s; erase mid-generation drops the stale result; background mid-generation does not crash; 10 minutes of painting stays at 60 fps._
