#!/bin/bash
# Fetches ONNX Runtime's prebuilt macOS library (universal: Apple silicon and Intel) into vendor/onnxruntime.
# It runs the word-timing model (Sources/COnnx). Safe to run again; it does nothing when the files are already there.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${ORT_VERSION:-1.23.2}"
DEST="vendor/onnxruntime"
if [ -f "$DEST/lib/libonnxruntime.$VER.dylib" ] && [ -f "$DEST/include/onnxruntime_c_api.h" ]; then exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/ort.tgz" "https://github.com/microsoft/onnxruntime/releases/download/v$VER/onnxruntime-osx-universal2-$VER.tgz"
tar -xzf "$TMP/ort.tgz" -C "$TMP"
rm -rf "$DEST"; mkdir -p vendor
mv "$TMP/onnxruntime-osx-universal2-$VER" "$DEST"
ls -la "$DEST/lib" "$DEST/include" | head -20
