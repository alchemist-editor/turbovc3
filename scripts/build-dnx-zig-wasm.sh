#!/usr/bin/env bash
# Build the complete DNx macroblock-row decoder as standalone Zig/WASM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/native/dnx_row_decoder.zig"
OUT_DIR="$ROOT/wasm/generated"
EXPECTED_ZIG_VERSION="0.17.0-dev.2375+d8aab4878"

if [[ -n "${ZIG:-}" ]]; then
  ZIG_BIN="$ZIG"
elif command -v zig >/dev/null 2>&1; then
  ZIG_BIN="$(command -v zig)"
else
  echo "Zig $EXPECTED_ZIG_VERSION is required; see https://ziglang.org/download/" >&2
  exit 1
fi

ACTUAL_ZIG_VERSION="$($ZIG_BIN version)"
if [[ "$ACTUAL_ZIG_VERSION" != "$EXPECTED_ZIG_VERSION" ]]; then
  echo "Expected Zig $EXPECTED_ZIG_VERSION, found $ACTUAL_ZIG_VERSION at $ZIG_BIN" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

"$ZIG_BIN" build-exe "$SRC" \
  -target wasm32-freestanding \
  -mcpu=generic+simd128 \
  -O ReleaseSmall \
  -fno-entry \
  -rdynamic \
  --export-memory \
  --stack 65536 \
  -femit-bin="$OUT_DIR/dnx_row_decoder.wasm"

echo "Wrote $OUT_DIR/dnx_row_decoder.wasm"
