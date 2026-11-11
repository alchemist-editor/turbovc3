#!/usr/bin/env bash
# Build experimental DNx standalone WASM kernels.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_ROOT="$ROOT/src/native"
SRC="$NATIVE_ROOT/dnx_idct_kernel.c"
OUT_DIR="$ROOT/wasm/generated"

mkdir -p "$OUT_DIR" "$NATIVE_ROOT/build"

if ! command -v emcc >/dev/null 2>&1; then
  echo "emcc not found; install with: brew install emscripten" >&2
  exit 1
fi

# Homebrew emscripten can default to /usr/bin/clang, which has no WASM backend.
EMSCRIPTEN_CELLAR="$(brew --prefix emscripten 2>/dev/null || true)"
if [[ -n "$EMSCRIPTEN_CELLAR" && -x "$EMSCRIPTEN_CELLAR/libexec/llvm/bin/clang" ]]; then
  export EM_LLVM_ROOT="$EMSCRIPTEN_CELLAR/libexec/llvm/bin"
fi
if [[ -n "$EMSCRIPTEN_CELLAR" && -x "$EMSCRIPTEN_CELLAR/libexec/binaryen/bin/wasm-opt" ]]; then
  export EM_BINARYEN_ROOT="$EMSCRIPTEN_CELLAR/libexec/binaryen"
fi

export EM_CACHE="${EM_CACHE:-$NATIVE_ROOT/build/.emscripten-cache}"
mkdir -p "$EM_CACHE"

emcc "$SRC" \
  -O3 \
  -msimd128 \
  -s STANDALONE_WASM=1 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s EXPORTED_FUNCTIONS='["_dnx_idct_i32_blocks","_dnx_idct_kernel_version","_malloc","_free"]' \
  -Wl,--no-entry \
  -o "$OUT_DIR/dnx_idct_kernel.wasm"

echo "Wrote $OUT_DIR/dnx_idct_kernel.wasm"
