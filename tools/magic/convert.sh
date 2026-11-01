#!/usr/bin/env bash
# Converts the Magic mode models to Core ML (LCM Dreamshaper v7 + scribble ControlNet, 640x384).
# Output: build/magic-models/Resources. Needs Python 3.10+, ~20 GB free disk and a few hours of patience.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/build/magic-work"
mkdir -p "$WORK"
cd "$WORK"

[ -d ml-stable-diffusion ] || git clone https://github.com/apple/ml-stable-diffusion.git
# torch and coremltools lag behind the newest Python; override with PYTHON=python3.x if needed.
PYTHON="${PYTHON:-$(command -v python3.11 || command -v python3)}"
[ -d venv ] || "$PYTHON" -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -e ml-stable-diffusion
# Newer scipy wheels fail to load on macOS 27 (dlopen: zero-fill __thread_bss); numpy<1.24 rules out the fixed ones.
pip install "scipy<1.12"
# LCM_Dreamshaper_v7 ships no fp16 variant files and diffusers 0.30 turns that into an error; load the default weights.
sed -i '' 's/variant="fp16",//' ml-stable-diffusion/python_coreml_stable_diffusion/torch2coreml.py
# The converter insists a ControlNet is paired with its exact base model (runwayml/stable-diffusion-v1-5). LCM Dreamshaper v7 is an SD 1.5
# derivative, which is what the scribble ControlNet is trained for, so skip that name check.
sed -i '' 's/if base_model is not None and base_model != args.model_version:/if False and base_model is not None and base_model != args.model_version:/' ml-stable-diffusion/python_coreml_stable_diffusion/torch2coreml.py

# LCM UNets carry a guidance-embedding layer (time_embedding.cond_proj) that Apple's converter has no input for. Drop it: the layer is
# bias-free, so this equals feeding a zero guidance embedding. SPEED IS UNAFFECTED; PICTURE QUALITY MUST BE CHECKED BY EYE.
python3 - <<'PY'
import pathlib
f = pathlib.Path("ml-stable-diffusion/python_coreml_stable_diffusion/torch2coreml.py")
t = f.read_text()
old = "load_state_dict_summary = reference_unet.load_state_dict(\n            pipe.unet.state_dict())"
new = "load_state_dict_summary = reference_unet.load_state_dict(\n            {k: v for k, v in pipe.unet.state_dict().items() if not k.startswith('time_embedding.cond_proj')})"
if old in t:
    f.write_text(t.replace(old, new))
PY

# SPLIT_EINSUM_V2 cannot split the 3840-token (48x80) query evenly and fails in tracing. ORIGINAL is the variant Apple recommends
# for GPU (cpuAndGPU) anyway.
ATTENTION="${ATTENTION:-ORIGINAL}"

python -m python_coreml_stable_diffusion.torch2coreml \
  --model-version SimianLuo/LCM_Dreamshaper_v7 \
  --convert-unet --unet-support-controlnet --convert-text-encoder \
  --convert-vae-encoder --convert-vae-decoder \
  --convert-controlnet lllyasviel/control_v11p_sd15_scribble \
  --latent-h 48 --latent-w 80 \
  --attention-implementation "$ATTENTION" \
  --quantize-nbits 6 \
  --bundle-resources-for-swift-cli \
  -o "$ROOT/build/magic-models"

# Apple's Swift SafetyChecker feeds a fixed 512x512 dummy image, so the checker must be converted for 512x512 (latent 64x64; this model
# defaults to 768x768), not for 640x384 (a 640x384 checker fails with "MultiArray shape (1 x 512 x 512 x 3) does not match ... (1 x 384 x 640 x 3)").
python -m python_coreml_stable_diffusion.torch2coreml \
  --model-version SimianLuo/LCM_Dreamshaper_v7 \
  --convert-safety-checker \
  --latent-h 64 --latent-w 64 \
  --bundle-resources-for-swift-cli \
  -o "$ROOT/build/magic-safety"
rm -rf "$ROOT/build/magic-models/Resources/SafetyChecker.mlmodelc"
cp -R "$ROOT/build/magic-safety/Resources/SafetyChecker.mlmodelc" "$ROOT/build/magic-models/Resources/"

echo "Done. Resources in $ROOT/build/magic-models/Resources"
