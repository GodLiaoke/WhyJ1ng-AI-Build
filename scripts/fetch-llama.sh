#!/usr/bin/env bash
#
# Downloads the pinned llama.cpp XCFramework into frameworks/.
#
# The version is pinned deliberately: llama.cpp's C API changes between builds
# (e.g. `llama_model_params.use_mmap` was replaced by the `load_mode` enum), so
# the shipped framework and the Swift code must agree.
#
# Usage:  scripts/fetch-llama.sh [destination-dir]
# Env:    LLAMA_TAG   override the pinned release tag

set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-b11612}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT/${1:-frameworks}"

if [ -d "$DEST_DIR/llama.xcframework" ]; then
  echo "already present: $DEST_DIR/llama.xcframework"
  exit 0
fi

mkdir -p "$DEST_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-xcframework.zip"
echo "downloading $URL"
curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$TMP/llama.zip" "$URL"

unzip -q "$TMP/llama.zip" -d "$TMP"

SRC="$TMP/build-apple/llama.xcframework"
if [ ! -d "$SRC" ]; then
  echo "error: unexpected archive layout, expected build-apple/llama.xcframework"
  find "$TMP" -maxdepth 3 -type d
  exit 1
fi

rm -rf "$DEST_DIR/llama.xcframework"
mv "$SRC" "$DEST_DIR/llama.xcframework"

# dSYMs are ~65MB of debug symbols for the C++ core. They are not needed to
# build or run the app, and they blow up the checkout size.
find "$DEST_DIR/llama.xcframework" -name '*.dSYM' -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "installed: $DEST_DIR/llama.xcframework"
du -sh "$DEST_DIR/llama.xcframework" 2>/dev/null || true
ls "$DEST_DIR/llama.xcframework"
