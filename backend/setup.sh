#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx"
MODEL_SHA256="6e742170d309016e5891a994e1ce1559c702a2ccd0075e67ef7157974f6406cb"
VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"
VOICES_SHA256="bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

validate_file() {
  local path="$1"
  local expected_sha="$2"
  local label="$3"

  if [[ ! -f "$path" ]]; then
    return 1
  fi

  local actual_sha
  actual_sha="$(sha256_file "$path")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    local size
    size="$(stat -f '%z' "$path" 2>/dev/null || echo unknown)"
    echo "$label failed validation. sha256=$actual_sha size=${size}b" >&2
    return 1
  fi

  return 0
}

download_and_verify() {
  local url="$1"
  local path="$2"
  local expected_sha="$3"
  local label="$4"
  local tmp_path
  local actual_sha

  tmp_path="$(mktemp "${path}.tmp.XXXXXX")"
  rm -f "$tmp_path"

  curl -L --fail --retry 3 --retry-delay 2 \
    -o "$tmp_path" \
    "$url"

  actual_sha="$(sha256_file "$tmp_path")"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    rm -f "$tmp_path"
    echo "Downloaded $label failed validation. sha256=$actual_sha" >&2
    exit 1
  fi

  mv "$tmp_path" "$path"
  echo "Installed $label"
}

ensure_asset() {
  local path="$1"
  local url="$2"
  local expected_sha="$3"
  local label="$4"

  if validate_file "$path" "$expected_sha" "$label"; then
    echo "Verified $label"
    return
  fi

  rm -f "$path"
  download_and_verify "$url" "$path" "$expected_sha" "$label"
}

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

ensure_asset "models/kokoro-v1.0.int8.onnx" "$MODEL_URL" "$MODEL_SHA256" "kokoro-v1.0.int8.onnx"
ensure_asset "models/voices-v1.0.bin" "$VOICES_URL" "$VOICES_SHA256" "voices-v1.0.bin"

echo "Setup complete."
