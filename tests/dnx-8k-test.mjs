#!/usr/bin/env node
// 8K DNxHR (issue #24) on both WebAssembly paths: the shared-memory row
// workers and the packet workers (whole frames through the Zig decoder's
// on-demand packet and frame buffers). Each 8K fixture must decode on the
// backend it started on, match the other path byte for byte, and match
// FFmpeg's decode.
//
// 7680x4320 HQX: the 8K UHD case from the issue (480 macroblocks, 14.6 MB
// packets). 8192x4320 HQ and 4:4:4: 8K DCI, the decoder's limit, 512
// macroblocks by 270 rows; the 4:4:4 packet (about 31 MB) and frame
// (8192x4320x3 16-bit samples) are the largest the buffers hold.
//
// Needs the built WebAssembly modules (npm run build:wasm) and FFmpeg; runs
// in test:native.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { Frame, inspectDnxContainer, parseDnxFrameHeader } from "../dist/index.js";
import { demuxMxf } from "../dist/mxf/index.js";
import { createNodeDecoder } from "../dist/node.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ffmpeg = process.env.FFMPEG ?? "ffmpeg";

const server = createServer(async (request, response) => {
  try {
    const bytes = await readFile(path.join(repoRoot, "wasm/generated", path.basename(request.url ?? "")));
    response.writeHead(200, { "content-type": "application/wasm" });
    response.end(bytes);
  } catch {
    response.writeHead(404);
    response.end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const wasmUrls = {
  rowDecoder: `${origin}/dnx_row_decoder.wasm`,
  idctKernel: `${origin}/dnx_idct_kernel.wasm`
};

const tmp = await mkdtemp(path.join(tmpdir(), "dnx-8k-"));
try {
  for (const [fixture, fourCc, pixelFormat, ffmpegFormat, width] of [
    ["dnxhr_hqx_4320p30_smptehdbars.mov.gz", "AVdh", "yuv422p10", "yuv422p10le", 7680],
    ["dnxhr_hq_8192x4320_smptehdbars.mxf.gz", "AVdh", "yuv422p8", "yuv422p", 8192],
    ["dnxhr_444_8192x4320_smptehdbars.mov.gz", "AVdh", "yuv444p10", "yuv444p10le", 8192]
  ]) {
    const container = gunzipSync(await readFile(path.join(repoRoot, "tests/fixtures", fixture)));
    const packet = fixture.includes(".mxf")
      ? await firstMxfVideoPacket(new Uint8Array(container))
      : (await inspectDnxContainer(new Uint8Array(container))).dnxTracks[0].firstPacket.data;
    const header = parseDnxFrameHeader(packet);
    assert.equal(header.width, width, `${fixture}: width`);
    assert.equal(header.height, 4320, `${fixture}: height`);
    assert.equal(header.macroblockWidth, width / 16, `${fixture}: macroblock width`);
    assert.equal(header.macroblockHeight, 270, `${fixture}: macroblock rows`);

    const rowPlanes = await decodeWith(fixture, fourCc, packet, true);
    const packetPlanes = await decodeWith(fixture, fourCc, packet, false);
    assert.equal(rowPlanes.pixelFormat, pixelFormat);
    assert.equal(packetPlanes.pixelFormat, pixelFormat);
    assert.ok(Buffer.from(rowPlanes.bytes).equals(Buffer.from(packetPlanes.bytes)), `${fixture}: row and packet output differ`);

    const source = path.join(tmp, fixture.replace(/\.gz$/, ""));
    await writeFile(source, container);
    const oracle = spawnSync(ffmpeg, [
      "-v", "error", "-i", source, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", ffmpegFormat, "-"
    ], { maxBuffer: 512 * 1024 * 1024 });
    assert.equal(oracle.status, 0, `${fixture}: FFmpeg decode: ${oracle.stderr}`);
    assert.equal(rowPlanes.bytes.byteLength, oracle.stdout.byteLength, `${fixture}: size against FFmpeg`);
    // The oracle suite's bar: within one code value of FFmpeg everywhere
    // (the inverse DCTs round differently).
    const maxDiff = maxAbsDiff(rowPlanes.bytes, oracle.stdout, pixelFormat.endsWith("p8") ? 1 : 2);
    assert.ok(maxDiff <= 1, `${fixture}: differs from FFmpeg by up to ${maxDiff}`);
    console.log(`ok - ${fixture}: row and packet workers agree, within ${maxDiff} of FFmpeg (${rowPlanes.bytes.byteLength} bytes)`);
  }
  console.log("8K DNxHR decode passed.");
} finally {
  server.close();
  await rm(tmp, { recursive: true, force: true });
}

async function firstMxfVideoPacket(bytes) {
  const { packets } = await demuxMxf(bytes);
  const video = packets.find((packet) => packet.track.kind === "video") ?? packets[0];
  return bytes.subarray(video.byteOffset, video.byteOffset + video.byteLength);
}

function maxAbsDiff(actual, expected, bytesPerSample) {
  const a = bytesPerSample === 1 ? actual : new Uint16Array(actual.buffer, actual.byteOffset, actual.byteLength / 2);
  const b = bytesPerSample === 1
    ? expected
    : new Uint16Array(expected.buffer, expected.byteOffset, expected.byteLength / 2);
  let max = 0;
  for (let index = 0; index < a.length; index += 1) {
    const diff = Math.abs(a[index] - b[index]);
    if (diff > max) max = diff;
  }
  return max;
}

async function decodeWith(fixture, dnxFourCc, packet, useSharedMemory) {
  const startErrors = [];
  const decoder = await createNodeDecoder({
    dnxFourCc,
    useSharedMemory,
    concurrency: 2,
    wasmUrls,
    onWorkerStartError: (error) => startErrors.push(error)
  });
  assert.ok(!(decoder instanceof Error), String(decoder));
  const backend = useSharedMemory ? "shared-row-workers/zig-wasm-row" : "worker-pool/zig-wasm-frame";
  try {
    assert.equal(decoder.idctMode, backend, `${fixture}: backend`);
    const result = await decoder.decode(packet, new Frame());
    assert.ok(!(result instanceof Error), `${fixture} (${useSharedMemory ? "row" : "packet"} workers): ${result?.message}`);
    assert.deepEqual(startErrors.map(String), [], `${fixture}: no start error`);
    assert.equal(decoder.idctMode, backend, `${fixture}: backend after decode`);
    const bytes = new Uint8Array(result.allocationSize());
    result.copyTo(bytes);
    return { pixelFormat: result.pixelFormat, bytes };
  } finally {
    await decoder.close();
  }
}
