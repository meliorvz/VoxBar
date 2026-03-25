#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

python3 -m venv .venv
./.venv/bin/python -m ensurepip --upgrade
./.venv/bin/python -m pip install --upgrade pip
./.venv/bin/python -m pip install \
  beautifulsoup4 \
  kokoro-onnx \
  numpy \
  readability-lxml \
  requests \
  soundfile \
  trafilatura

mkdir -p models

if [[ ! -f models/kokoro-v1.0.int8.onnx ]]; then
  curl -L \
    -o models/kokoro-v1.0.int8.onnx \
    https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx
fi

if [[ ! -f models/voices-v1.0.bin ]]; then
  curl -L \
    -o models/voices-v1.0.bin \
    https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
fi

echo "Setup complete."
