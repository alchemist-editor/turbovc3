#!/usr/bin/env bash
# Puts a static FFmpeg 8.1 on CI's PATH. The tests use it for one remux
# (tests/dnx-oracle-test.mjs tags a committed fixture with container colour
# metadata).
#
# This replaced `apt-get install ffmpeg`, which pulled a few hundred packages
# (FFmpeg 6.1) from Ubuntu's mirrors and once hung a run for over ten minutes.
# The build is BtbN's static linux64 FFmpeg, the 8.1 release branch, from
# GitHub's release storage. That asset is rebuilt as 8.1 point releases and
# fixes land, so it carries no checksum; the version check below fails the
# step if it ever stops being 8.x.
set -euo pipefail

series="8.1"
url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n${series}-latest-linux64-gpl-${series}.tar.xz"
dir="${RUNNER_TEMP:-/tmp}/ffmpeg-static"

mkdir -p "$dir"
curl --fail --location --silent --show-error \
  --retry 5 --retry-all-errors --connect-timeout 15 --max-time 180 \
  --output "$dir/ffmpeg.tar.xz" "$url"
tar -xJf "$dir/ffmpeg.tar.xz" -C "$dir" --strip-components=2 --wildcards '*/bin/ffmpeg' '*/bin/ffprobe'
rm "$dir/ffmpeg.tar.xz"

version="$("$dir/ffmpeg" -hide_banner -version | head -n 1)"
echo "$version"
case "$version" in
  "ffmpeg version n8."*|"ffmpeg version 8."*) ;;
  *) echo "Expected FFmpeg 8.x from $url" >&2; exit 1 ;;
esac

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dir" >> "$GITHUB_PATH"
fi
