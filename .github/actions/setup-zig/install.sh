#!/usr/bin/env bash
# Immutable Zig development snapshot; verify archive bytes before extraction.
set -euo pipefail
VERSION="0.17.0-dev.2375+d8aab4878"
case "$(uname -s)" in
  Darwin) zig_os=macos ;;
  Linux) zig_os=linux ;;
  MINGW*|MSYS*|CYGWIN*) zig_os=windows ;;
  *) echo "Unsupported Zig host: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) zig_arch=aarch64 ;;
  x86_64|amd64) zig_arch=x86_64 ;;
  *) echo "Unsupported Zig architecture: $(uname -m)" >&2; exit 1 ;;
esac
case "$zig_arch-$zig_os" in
  aarch64-macos) zig_sha=251ef0c623e52896f7e946dc104ec752f0dee4f0a17e4dc56d9afbee939aaab2 ;;
  x86_64-macos) zig_sha=3b60e1c0345578ee83e80c94646fd2615ddb13e64fa979b7bd5bd5d476072d1a ;;
  aarch64-linux) zig_sha=13681511ba44779f9c9c6340286f8933b356cd70858472a43668dfafc4b91c67 ;;
  x86_64-linux) zig_sha=f10e0586afb4a57912b92ec271f6cf5de5adb507635d53101c7b3a2713f9db27 ;;
  aarch64-windows) zig_sha=5c15b3ae4cb8fadd5f784dea054c6e0473062a5b296e91fe81c4662032365ce1 ;;
  x86_64-windows) zig_sha=d989d298c94b0ea1c94abc8cb5ba0bebafaf31b10f8ac8c4b296be570dcf1207 ;;
esac
zig_ext=tar.xz
if [[ "$zig_os" == windows ]]; then zig_ext=zip; fi
zig_name="zig-$zig_arch-$zig_os-$VERSION"
zig_root="${ZIG_INSTALL_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if [[ "$zig_os" == windows ]]; then zig_root="$(cygpath -u "$zig_root")"; fi
zig_dir="$zig_root/native-zig-$VERSION-$zig_arch-$zig_os"
mkdir -p "$zig_dir"
zig_archive="$zig_dir/$zig_name.$zig_ext"
if [[ ! -f "$zig_archive" ]]; then
  curl --fail --location --retry 3 "https://ziglang.org/builds/$zig_name.$zig_ext" --output "$zig_archive"
fi
if command -v sha256sum >/dev/null 2>&1; then
  zig_actual="$(sha256sum "$zig_archive")"
else
  zig_actual="$(shasum -a 256 "$zig_archive")"
fi
if [[ "${zig_actual%% *}" != "$zig_sha" ]]; then
  echo "Zig archive checksum mismatch: $zig_archive" >&2
  exit 1
fi
if [[ "$zig_os" == windows ]]; then
  unzip -q -o "$zig_archive" -d "$zig_dir"
else
  tar -xJf "$zig_archive" -C "$zig_dir"
fi
zig_bin="$zig_dir/$zig_name"
[[ "$("$zig_bin/zig" version)" == "$VERSION" ]]
zig_path="$zig_bin"
if [[ "$zig_os" == windows ]]; then zig_path="$(cygpath -w "$zig_bin")"; fi
if [[ -n "${GITHUB_PATH:-}" ]]; then printf '%s\n' "$zig_path" >> "$GITHUB_PATH"; fi
printf 'Installed Zig %s at %s\n' "$VERSION" "$zig_bin"
