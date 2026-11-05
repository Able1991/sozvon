#!/bin/bash
# Собирает build/pyannote-models-v1.tar.gz из локального кэша Hugging Face
# (нужен один раз токен и принятые условия на страницах моделей).
# Архив кладётся в релиз models-v1, setup.sh качает его без токена и сверяет SHA-256.
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
