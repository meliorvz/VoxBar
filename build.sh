#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Setting up backend..."
(cd "$ROOT_DIR/backend" && ./setup.sh)

echo "Building VoxBar app..."
(cd "$ROOT_DIR/ui" && ./Scripts/build-app.sh)

open "$ROOT_DIR/ui/dist/VoxBar.app"

echo "Done."
echo "Launch with: open \"$ROOT_DIR/ui/dist/VoxBar.app\""
