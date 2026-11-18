#!/usr/bin/env bash
# Puts a static FFmpeg on CI's PATH. The tests use it for one remux
# (tests/dnx-oracle-test.mjs tags a committed fixture with container colour
# metadata), so any recent FFmpeg does.
#
# This replaced `apt-get install ffmpeg`, which pulls a few hundred packages
# from Ubuntu's mirrors and once hung a run for over ten minutes. The build is
# ffmpeg-static's FFmpeg 7.0.2 (John Van Sickle's static amd64 build), a single
# file served from GitHub's release storage, pinned by SHA-256.
set -euo pipefail

url="https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-linux-x64.gz"
sha256="bfe8a8fc511530457b528c48d77b5737527b504a3797a9bc4866aeca69c2dffa"
dir="${RUNNER_TEMP:-/tmp}/ffmpeg-static"

mkdir -p "$dir"
curl --fail --location --silent --show-error \
  --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
  --output "$dir/ffmpeg.gz" "$url"
echo "$sha256  $dir/ffmpeg.gz" | sha256sum --check --strict
gunzip --force "$dir/ffmpeg.gz"
chmod +x "$dir/ffmpeg"
"$dir/ffmpeg" -hide_banner -version | head -n 1

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dir" >> "$GITHUB_PATH"
fi
