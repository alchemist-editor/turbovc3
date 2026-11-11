#!/usr/bin/env node
// The shared-row path copies at most the Zig row buffer (1 MiB) of a row.
// That is only safe if (1) no valid row needs more, (2) the Zig bit reader
// fails at the end of the bytes it is given instead of reading past them, and
// (3) a row whose coded data is corrupt or does not end within the buffer is
// an ordinary decode error that leaves the decoder on the row workers. 8K
// frames, over the Zig limits, are refused up front with an error naming the
// supported size.
//
// Needs the built WebAssembly modules (npm run build:wasm); runs in test:native.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { build } from "esbuild";
import { DnxInvalidDataError, DnxNotSupportedError, Frame, inspectDnxContainer, parseDnxFrameHeader } from "../dist/index.js";
import { createNodeDecoder } from "../dist/node.js";
import { parseDnxRowSpans } from "../dist/dnxReconstruction.js";
import { getDnxRowTableSet, supportsDnxScalarCid } from "../dist/dnxScalarDecoder.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fixtures = path.join(repoRoot, "tests/fixtures");
const zig = await loadZigModule();
const rowDecoder = await zig.createDnxWasmRowDecoder(
  await readFile(path.join(repoRoot, "wasm/generated/dnx_row_decoder.wasm"))
);
const ROW_BUFFER = rowDecoder.capacities.rowBytes;
const MAX_MACROBLOCKS = rowDecoder.capacities.macroblocksPerRow;

// (1) The largest row any supported CID can code fits the row buffer, so
// capping a span at the buffer only ever drops padding.
{
  let worstRowBytes = 0;
  for (let cid = 1235; cid <= 1274; cid += 1) {
    if (!supportsDnxScalarCid(cid)) continue;
    for (const [bitDepth, is444] of [[8, false], [10, false], [10, true], [12, false], [12, true]]) {
      const tables = getDnxRowTableSet(cid, bitDepth, is444);
      const longest = (table) => Math.max(...table.entries.map((entry) => entry.bits));
      const largestDcLength = Math.max(...tables.dcTable.entries.map((entry) => entry.symbol));
      // Per AC coefficient: VLC, sign, level extension bits, run VLC; at most 63 of them, then EOB.
      const acBits = longest(tables.acTable) + 1 + tables.indexBits + longest(tables.runTable);
      const blockBits = longest(tables.dcTable) + largestDcLength + 63 * acBits + longest(tables.acTable);
      // Macroblock header: field flag (MBAFF), 11-bit qscale, reserved/ACT bit.
      const macroblockBits = 13 + (is444 ? 12 : 8) * blockBits;
      worstRowBytes = Math.max(worstRowBytes, Math.ceil(MAX_MACROBLOCKS * macroblockBits / 8));
    }
  }
  assert.ok(worstRowBytes < ROW_BUFFER, `worst-case coded row ${worstRowBytes} bytes fits ${ROW_BUFFER}`);
  console.log(`ok - worst-case coded row (${worstRowBytes} bytes) fits the ${ROW_BUFFER}-byte row buffer`);
}

// (2) The Zig bit reader stops with an error at the end of the bytes it is
// given: a truncated row fails near its truncated length, it does not decode.
{
  const packet = await firstPacket("dnxhr_hqx_2160p30_testsrc.mov.gz");
  const header = parseDnxFrameHeader(packet);
  const tables = getDnxRowTableSet(header.cid, header.bitDepth, header.is444);
  const row = parseDnxRowSpans(packet, header)[0];
  const full = packet.subarray(row.start, row.end);
  assert.equal(rowDecoder.decodeRow(full, header.macroblockWidth, header.bitDepth, header.is444, tables).length > 0, true);
  const truncated = full.subarray(0, Math.floor(full.byteLength / 2));
  let failure = null;
  try {
    rowDecoder.decodeRow(truncated, header.macroblockWidth, header.bitDepth, header.is444, tables);
  } catch (error) {
    failure = error;
  }
  assert.ok(failure, "a truncated row must not decode");
  assert.match(failure.message, /Zig row decode failed/);
  // It read up to the end of the truncated bytes (within one block's worth),
  // and not past them.
  const bit = Number(/bit (\d+)/.exec(failure.message)[1]);
  assert.ok(bit <= truncated.byteLength * 8, `stopped at bit ${bit} of ${truncated.byteLength * 8}`);
  assert.ok(bit > truncated.byteLength * 8 - 8 * 4096, `failed at bit ${bit}, well before the end`);
  console.log(`ok - a truncated row fails at bit ${bit} of ${truncated.byteLength * 8}`);
}

// (3) and 8K, through Decoder with Node workers.
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
const wasmUrls = { rowDecoder: `${origin}/dnx_row_decoder.wasm`, idctKernel: `${origin}/dnx_idct_kernel.wasm` };

try {
  // A corrupt last row is an ordinary decode error, whatever its span: no
  // start error, the decoder stays on the row workers, and the next frame
  // decodes there exactly as on a fresh decoder.
  // 1080p HQX whose last row is 1 MiB + 4 KiB of bytes that are not valid DNx.
  {
    const valid = await firstPacket("oracle_dnxhr_hqx_1080p30_10bit_cid1271.mov");
    const lastRow = parseDnxRowSpans(valid, parseDnxFrameHeader(valid)).at(-1);
    const corrupt = new Uint8Array(lastRow.start + ROW_BUFFER + 4096).fill(0xff);
    corrupt.set(valid.subarray(0, lastRow.start));
    assert.ok(parseDnxRowSpans(corrupt, parseDnxFrameHeader(corrupt)).at(-1).byteLength > ROW_BUFFER);
    await corruptLastRowStaysOnRowWorkers("1080p HQX, 1 MiB + 4 KiB invalid last row", corrupt, valid);
  }
  // 2160p HQX, the case that used to demote: its last row is always capped.
  // Flip bytes inside the last row's coded data.
  {
    const valid = await firstPacket("dnxhr_hqx_2160p30_testsrc.mov.gz");
    const lastRow = parseDnxRowSpans(valid, parseDnxFrameHeader(valid)).at(-1);
    assert.ok(lastRow.byteLength > ROW_BUFFER);
    const corrupt = valid.slice();
    for (let offset = lastRow.start + 8; offset < lastRow.start + 72; offset += 1) corrupt[offset] ^= 0xff;
    await corruptLastRowStaysOnRowWorkers("2160p HQX, corrupted last row", corrupt, valid);
  }

  // 8K (4320p: 480 macroblocks wide, a 14.6 MB packet) is over every Zig
  // limit. The header check refuses it before any backend sees it, naming
  // the supported size; no worker backend is blamed or abandoned.
  {
    const packet = await firstPacket("dnxhr_hqx_4320p30_smptehdbars.mov.gz");
    assert.equal(parseDnxFrameHeader(packet).macroblockWidth, 480);
    const { decoder, startErrors } = await rowWorkerDecoder();
    try {
      const result = await decoder.decode(packet, new Frame());
      assert.ok(result instanceof DnxNotSupportedError, `got ${result?.constructor?.name}`);
      assert.match(result.message, /limited to 4096x2160 frames/);
      assert.deepEqual(startErrors, []);
      assert.equal(decoder.idctMode, "shared-row-workers/zig-wasm-row");
    } finally {
      await decoder.close();
    }
    console.log("ok - a 4320p frame is refused up front with an error naming the 4096x2160 limit");
  }
} finally {
  server.close();
  rowDecoder.destroy();
}

console.log("DNx row buffer tests passed.");

async function corruptLastRowStaysOnRowWorkers(label, corrupt, valid) {
  const { decoder, startErrors } = await rowWorkerDecoder();
  try {
    const result = await decoder.decode(corrupt, new Frame());
    // Never output: a decode error that says why.
    assert.ok(result instanceof DnxInvalidDataError, `${label}: expected a decode error, got ${result?.constructor?.name}`);
    assert.match(result.message, /DNx shared row \d+/);
    assert.deepEqual(startErrors, [], `${label}: no start error`);
    assert.equal(decoder.idctMode, "shared-row-workers/zig-wasm-row", `${label}: stays on row workers`);
    const next = await decoder.decode(valid, new Frame());
    assert.ok(!(next instanceof Error), `${label}: next frame: ${next?.message}`);
    assert.equal(decoder.idctMode, "shared-row-workers/zig-wasm-row");
    const expected = await freshRowWorkerBytes(valid);
    assert.ok(Buffer.from(frameBytes(next)).equals(Buffer.from(expected)), `${label}: next frame differs from a fresh decoder`);
  } finally {
    await decoder.close();
  }
  console.log(`ok - ${label}: decode error, stays on row workers, next frame byte-identical`);
}

async function freshRowWorkerBytes(packet) {
  const { decoder } = await rowWorkerDecoder();
  try {
    const result = await decoder.decode(packet, new Frame());
    assert.ok(!(result instanceof Error), result?.message);
    return frameBytes(result);
  } finally {
    await decoder.close();
  }
}

function frameBytes(frame) {
  const bytes = new Uint8Array(frame.allocationSize());
  frame.copyTo(bytes);
  return bytes;
}

async function rowWorkerDecoder() {
  const startErrors = [];
  const decoder = await createNodeDecoder({
    dnxFourCc: "AVdh",
    useSharedMemory: true,
    concurrency: 2,
    wasmUrls,
    onWorkerStartError: (error) => startErrors.push(error)
  });
  assert.ok(!(decoder instanceof Error), String(decoder));
  assert.equal(decoder.idctMode, "shared-row-workers/zig-wasm-row");
  return { decoder, startErrors };
}

async function firstPacket(fixture) {
  let bytes = await readFile(path.join(fixtures, fixture));
  if (fixture.endsWith(".gz")) bytes = gunzipSync(bytes);
  return (await inspectDnxContainer(new Uint8Array(bytes))).dnxTracks[0].firstPacket.data;
}

async function loadZigModule() {
  const result = await build({
    entryPoints: [path.join(repoRoot, "src/dnxZigRowDecoder.ts")],
    bundle: true,
    format: "esm",
    platform: "node",
    target: "node22",
    write: false
  });
  return import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString("base64")}`);
}
