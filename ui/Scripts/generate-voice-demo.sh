#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTICLE_TTS_PYTHON="$ROOT_DIR/../backend/.venv/bin/python"

cd "$ROOT_DIR"
"$ARTICLE_TTS_PYTHON" Scripts/generate_voice_demo.py "$@"
