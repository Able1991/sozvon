#!/bin/bash
# Builds build/pyannote-models-v1.tar.gz from the local Hugging Face cache
# (needs a token once and the terms accepted on the model pages).
# The archive goes into the models-v1 release; setup.sh downloads it without a token and verifies SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}"
STAGE=build/pyannote-stage
rm -rf "$STAGE"; mkdir -p "$STAGE/hf-cache"
for m in segmentation-3.0 speaker-diarization-3.1 speaker-diarization-community-1 wespeaker-voxceleb-resnet34-LM; do
  rsync -a --copy-unsafe-links --exclude .locks "$SRC/models--pyannote--$m" "$STAGE/hf-cache/"
done
cat > "$STAGE/hf-cache/NOTICE-pyannote.txt" <<'TXT'
Speaker diarization models redistributed unmodified by Sozvon.

pyannote/segmentation-3.0          MIT License, (c) CNRS, Hervé Bredin and contributors
pyannote/speaker-diarization-3.1   MIT License, (c) CNRS, Hervé Bredin and contributors
pyannote/speaker-diarization-community-1   CC BY 4.0, pyannoteAI
pyannote/wespeaker-voxceleb-resnet34-LM   CC BY 4.0, WeSpeaker (Hongji Wang et al.)

Sources: https://huggingface.co/pyannote
Licenses: https://opensource.org/license/mit, https://creativecommons.org/licenses/by/4.0/
TXT
COPYFILE_DISABLE=1 tar -czf build/pyannote-models-v1.tar.gz -C "$STAGE" hf-cache
rm -rf "$STAGE"
shasum -a 256 build/pyannote-models-v1.tar.gz
