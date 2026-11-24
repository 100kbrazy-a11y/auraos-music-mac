#!/bin/bash
# Fetches ONNX Runtime for the word-timing model (Sources/COnnx) into vendor/onnxruntime. Safe to run again.
#   - the library: the universal (Apple silicon + Intel) macOS build from the official `onnxruntime` wheel on PyPI.
#     1.22.1 is the newest release that still has an Intel slice.
#   - the C header: from the conda-forge build of ONNX Runtime. Any release's header works with this library,
#     because the C API only ever grows (the code asks the library for API version 22).
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${ORT_VERSION:-1.22.1}"
HEADERS_PKG="https://conda.anaconda.org/conda-forge/osx-arm64/onnxruntime-cpp-1.31.1-h24e3756_0_cpu.conda"
DEST="vendor/onnxruntime"
if [ -f "$DEST/lib/libonnxruntime.$VER.dylib" ] && [ -f "$DEST/include/onnxruntime_c_api.h" ]; then exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 -m pip download "onnxruntime==$VER" --only-binary=:all: --platform macosx_13_0_universal2 --python-version 3.12 --no-deps -d "$TMP/whl" -q
unzip -j -q "$TMP"/whl/onnxruntime-*.whl "onnxruntime/capi/libonnxruntime.$VER.dylib" -d "$TMP/lib"

curl -fsSL --retry 3 -o "$TMP/h.conda" "$HEADERS_PKG"
mkdir -p "$TMP/h"
unzip -q "$TMP/h.conda" 'pkg-*.tar.zst' -d "$TMP/h"
if command -v zstd >/dev/null 2>&1; then
  zstd -dc "$TMP"/h/pkg-*.tar.zst | tar -x -C "$TMP/h" include/onnxruntime/core/session
else
  tar -xf "$TMP"/h/pkg-*.tar.zst -C "$TMP/h" include/onnxruntime/core/session
fi

rm -rf "$DEST"; mkdir -p "$DEST/lib" "$DEST/include"
cp "$TMP/lib/libonnxruntime.$VER.dylib" "$DEST/lib/"
ln -s "libonnxruntime.$VER.dylib" "$DEST/lib/libonnxruntime.dylib"
cp "$TMP"/h/include/onnxruntime/core/session/*.h "$DEST/include/"
ls -la "$DEST/lib" "$DEST/include" | head -30
