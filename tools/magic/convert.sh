#!/usr/bin/env bash
# Converts the Magic mode models to Core ML (LCM Dreamshaper v7 + scribble ControlNet, 640x384).
# Output: build/magic-models/Resources. Needs Python 3.10+, ~20 GB free disk and a few hours of patience.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/build/magic-work"
mkdir -p "$WORK"
cd "$WORK"

[ -d ml-stable-diffusion ] || git clone https://github.com/apple/ml-stable-diffusion.git
[ -d venv ] || python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -e ml-stable-diffusion

python -m python_coreml_stable_diffusion.torch2coreml \
  --model-version SimianLuo/LCM_Dreamshaper_v7 \
  --convert-unet --unet-support-controlnet --convert-text-encoder \
  --convert-vae-encoder --convert-vae-decoder --convert-safety-checker \
  --convert-controlnet lllyasviel/control_v11p_sd15_scribble \
  --latent-h 48 --latent-w 80 \
  --attention-implementation SPLIT_EINSUM_V2 \
  --quantize-nbits 6 \
  --bundle-resources-for-swift-cli \
  -o "$ROOT/build/magic-models"

echo "Done. Resources in $ROOT/build/magic-models/Resources"
