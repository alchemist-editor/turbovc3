#!/usr/bin/env node
// 2160p DNxHR on the shared-memory row-worker path (issue #23). DNxHR frames
// are padded to a fixed size and the row-span parser runs the last row to the
// end of the payload, so a 4K frame's last row spans 2-7 MB of mostly padding,
// past the 1 MiB Zig row buffer. Each frame must decode on the row workers and
// match the packet-worker output byte for byte.
//
// Needs the built WebAssembly modules (npm run build:wasm): Node workers load
// them over HTTP, since Node's fetch does not read file: URLs. Runs in
// test:native.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { Frame, inspectDnxContainer, parseDnxFrameHeader } from "../dist/index.js";
import { createNodeDecoder } from "../dist/node.js";
import { parseDnxRowSpans } from "../dist/dnxReconstruction.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ROW_BUFFER_BYTES = 1024 * 1024;

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

try {
  for (const [fixture, fourCc, pixelFormat] of [
    ["dnxhr_hqx_2160p30_testsrc.mov.gz", "AVdh", "yuv422p10"],
    ["dnxhr_hq_2160p30_testsrc.mov.gz", "AVdh", "yuv422p8"],
    ["dnxhr_444_2160p30_testsrc.mov.gz", "AVdh", "yuv444p10"]
  ]) {
    const container = gunzipSync(await readFile(path.join(repoRoot, "tests/fixtures", fixture)));
    const packet = (await inspectDnxContainer(new Uint8Array(container))).dnxTracks[0].firstPacket.data;
    const header = parseDnxFrameHeader(packet);
    const rows = parseDnxRowSpans(packet, header);
    // The case this test exists for: padding pushes the last row past the buffer.
    assert.ok(rows.at(-1).byteLength > ROW_BUFFER_BYTES, `${fixture}: last row spans ${rows.at(-1).byteLength} bytes`);

    const rowPlanes = await decodeWith(fixture, fourCc, packet, true);
    const packetPlanes = await decodeWith(fixture, fourCc, packet, false);
    assert.equal(rowPlanes.pixelFormat, pixelFormat);
    assert.equal(packetPlanes.pixelFormat, pixelFormat);
    assert.equal(rowPlanes.bytes.byteLength, packetPlanes.bytes.byteLength);
    assert.ok(Buffer.from(rowPlanes.bytes).equals(Buffer.from(packetPlanes.bytes)), `${fixture}: row and packet output differ`);
    console.log(`${fixture}: shared-row output matches packet workers (${rowPlanes.bytes.byteLength} bytes)`);
  }
  console.log("2160p DNxHR shared-row decode passed.");
} finally {
  server.close();
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
  try {
    assert.deepEqual(startErrors.map(String), []);
    assert.equal(
      decoder.idctMode,
      useSharedMemory ? "shared-row-workers/zig-wasm-row" : "worker-pool/zig-wasm-frame",
      `${fixture}: backend`
    );
    const frame = new Frame();
    const result = await decoder.decode(packet, frame);
    assert.ok(!(result instanceof Error), `${fixture} (${useSharedMemory ? "row" : "packet"} workers): ${result?.message}`);
    // Still on the backend it started on: no fallback for a frame that fits.
    assert.deepEqual(startErrors.map(String), []);
    assert.equal(
      decoder.idctMode,
      useSharedMemory ? "shared-row-workers/zig-wasm-row" : "worker-pool/zig-wasm-frame",
      `${fixture}: backend after decode`
    );
    const bytes = new Uint8Array(result.allocationSize());
    result.copyTo(bytes);
    return { pixelFormat: result.pixelFormat, bytes };
  } finally {
    await decoder.close();
  }
}
