#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/tests/fixtures}"
FFMPEG="${FFMPEG:-ffmpeg}"

if ! "$FFMPEG" -version | head -n 1 | grep -q "ffmpeg version 8\."; then
  echo "FFmpeg 8.x is required to regenerate the committed oracle corpus." >&2
  exit 1
fi

run_ffmpeg() {
  local args=("$@")
  local output_index=$((${#args[@]} - 1))
  local output="${args[$output_index]}"
  unset "args[$output_index]"
  "$FFMPEG" "${args[@]}" -fflags +bitexact "$output"
}

mkdir -p "$OUTPUT_DIR"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30000/1001:duration=1" \
  -frames:v 1 -pix_fmt yuv422p10le -vf setfield=tff -flags +ildct -top 1 \
  -c:v dnxhd -profile:v dnxhd -b:v 185M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1080i2997_10bit_cid1241.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30000/1001:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -vf setfield=tff -flags +ildct -top 1 \
  -c:v dnxhd -profile:v dnxhd -b:v 120M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1080i2997_8bit_cid1242.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30000/1001:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -vf setfield=tff -flags +ildct -top 1 \
  -c:v dnxhd -profile:v dnxhd -b:v 185M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1080i2997_8bit_cid1243.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1440x1080:rate=30000/1001:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -vf setfield=tff -flags +ildct -top 1 \
  -c:v dnxhd -profile:v dnxhd -b:v 120M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1440x1080i2997_8bit_cid1244.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1440x1080:rate=30000/1001:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -vf setfield=tff -flags +ildct -top 1 \
  -c:v dnxhd -profile:v dnxhd -strict -2 -b:v 80M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1440x1080i2997_8bit_cid1260.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhd -b:v 90M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_720p30_8bit_cid1251.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p10le -c:v dnxhd -profile:v dnxhd -b:v 90M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_720p30_10bit_cid1250.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhd -b:v 75M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_720p30_8bit_cid1252.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhd -b:v 45M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1080p30_8bit_cid1253.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=960x720:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhd -b:v 42M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_960x720p30_8bit_cid1258.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1440x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhd -b:v 100M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1440x1080p30_8bit_cid1259.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhd -b:v 145M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1080p30_8bit_cid1237.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhd -b:v 220M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1080p30_8bit_cid1238.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p10le -c:v dnxhd -profile:v dnxhd -b:v 175M -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhd_1080p30_10bit_cid1235.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhr_lb -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhr_lb_1080p30_8bit_cid1274.mov"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhr_sq -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhr_sq_1080p30_8bit_cid1273.mov"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhr_hq -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhr_hq_1080p30_8bit_cid1272.mov"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p10le -c:v dnxhd -profile:v dnxhr_hqx -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhr_hqx_1080p30_10bit_cid1271.mov"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv444p10le -c:v dnxhd -profile:v dnxhr_444 -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhr_444_1080p30_10bit.mov"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=1" \
  -frames:v 1 -pix_fmt gbrp10le -c:v dnxhd -profile:v dnxhr_444 -an \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/oracle_dnxhr_444_gbr_1080p30_10bit.mov"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" \
  -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=1" \
  -frames:v 1 -map 0:v:0 -map 1:a:0 -pix_fmt yuv422p \
  -c:v dnxhd -profile:v dnxhr_lb -c:a pcm_s16le -ar 48000 -ac 2 \
  -metadata creation_time=1970-01-01T00:00:00Z \
  "$OUTPUT_DIR/dnxhr-lb-op1a-pcm.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=24:duration=1" \
  -f lavfi -i "sine=frequency=750:sample_rate=48000:duration=1" \
  -frames:v 1 -map 0:v:0 -map 1:a:0 -pix_fmt yuv422p \
  -c:v dnxhd -profile:v dnxhr_lb -c:a pcm_s24le -ar 48000 -ac 1 \
  -metadata creation_time=1970-01-01T00:00:00Z -timecode 01:02:03:04 \
  "$OUTPUT_DIR/dnxhr-lb-op1a-pcm24-mono-24fps-tc.mxf"

run_ffmpeg -v error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=1" \
  -frames:v 1 -pix_fmt yuv422p -c:v dnxhd -profile:v dnxhr_lb \
  -metadata creation_time=1970-01-01T00:00:00Z -f mxf_opatom \
  "$OUTPUT_DIR/dnxhr-lb-opatom.mxf"

# 2160p DNxHR (issue #23): padded to a fixed frame size, so the last row's span
# exceeds the 1 MiB Zig row buffer. 4320p: over every Zig limit. Stored
# gzipped; the padding compresses to almost nothing.
for fixture in \
  "dnxhr_hqx_2160p30_testsrc testsrc 3840x2160 yuv422p10le dnxhr_hqx" \
  "dnxhr_hq_2160p30_testsrc testsrc 3840x2160 yuv422p dnxhr_hq" \
  "dnxhr_444_2160p30_testsrc testsrc 3840x2160 yuv444p10le dnxhr_444" \
  "dnxhr_hqx_4320p30_smptehdbars smptehdbars 7680x4320 yuv422p10le dnxhr_hqx"
do
  read -r name source size format profile <<< "$fixture"
  run_ffmpeg -v error -y \
    -f lavfi -i "$source=size=$size:rate=30:duration=1" \
    -frames:v 1 -pix_fmt "$format" -c:v dnxhd -profile:v "$profile" -an \
    -metadata creation_time=1970-01-01T00:00:00Z \
    "$OUTPUT_DIR/$name.mov"
  gzip -n -9 -f "$OUTPUT_DIR/$name.mov"
done

for fixture in \
  "oracle_dnxhd_1080i2997_10bit_cid1241.mxf yuv422p10le" \
  "oracle_dnxhd_1080i2997_8bit_cid1242.mxf yuv422p" \
  "oracle_dnxhd_1080i2997_8bit_cid1243.mxf yuv422p" \
  "oracle_dnxhd_1440x1080i2997_8bit_cid1244.mxf yuv422p" \
  "oracle_dnxhd_1440x1080i2997_8bit_cid1260.mxf yuv422p" \
  "oracle_dnxhd_720p30_8bit_cid1251.mxf yuv422p" \
  "oracle_dnxhd_720p30_10bit_cid1250.mxf yuv422p10le" \
  "oracle_dnxhd_720p30_8bit_cid1252.mxf yuv422p" \
  "oracle_dnxhd_1080p30_8bit_cid1253.mxf yuv422p" \
  "oracle_dnxhd_960x720p30_8bit_cid1258.mxf yuv422p" \
  "oracle_dnxhd_1440x1080p30_8bit_cid1259.mxf yuv422p" \
  "oracle_dnxhd_1080p30_8bit_cid1237.mxf yuv422p" \
  "oracle_dnxhd_1080p30_8bit_cid1238.mxf yuv422p" \
  "oracle_dnxhd_1080p30_10bit_cid1235.mxf yuv422p10le" \
  "oracle_dnxhr_lb_1080p30_8bit_cid1274.mov yuv422p" \
  "oracle_dnxhr_sq_1080p30_8bit_cid1273.mov yuv422p" \
  "oracle_dnxhr_hq_1080p30_8bit_cid1272.mov yuv422p" \
  "oracle_dnxhr_hqx_1080p30_10bit_cid1271.mov yuv422p10le" \
  "oracle_dnxhr_444_1080p30_10bit.mov yuv444p10le" \
  "oracle_dnxhr_444_gbr_1080p30_10bit.mov gbrp10le"
do
  file="${fixture%% *}"
  format="${fixture##* }"
  raw="$OUTPUT_DIR/${file%.*}.yuv"
  run_ffmpeg -v error -y -i "$OUTPUT_DIR/$file" \
    -frames:v 1 -f rawvideo -pix_fmt "$format" "$raw"
  gzip -n -9 -f "$raw"
done

node "$ROOT/scripts/update-fixture-manifest.mjs" "$OUTPUT_DIR"
echo "Regenerated committed fixtures in $OUTPUT_DIR"
