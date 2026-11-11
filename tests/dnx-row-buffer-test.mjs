#!/usr/bin/env node
// The shared-row path copies at most the Zig row buffer (1 MiB) of a row.
// That is only safe if (1) no valid row needs more, (2) the Zig bit reader
// fails at the end of the bytes it is given instead of reading past them, and
// (3) a row that still does not fit is reported and handed to packet workers,
// never decoded into garbage. 8K frames, over the Zig limits, are refused up
// front with an error naming the supported size.
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
  const valid = await firstPacket("oracle_dnxhr_hqx_1080p30_10bit_cid1271.mov");
  const validHeader = parseDnxFrameHeader(valid);
  const lastRow = parseDnxRowSpans(valid, validHeader).at(-1);

  // A last row whose coded data does not end within the row buffer: replace
  // it with more than a buffer's worth of bytes that are not valid DNx.
  {
    const packet = withLastRow(valid, lastRow.start, ROW_BUFFER + 4096);
    assert.ok(parseDnxRowSpans(packet, parseDnxFrameHeader(packet)).at(-1).byteLength > ROW_BUFFER);
    const { decoder, startErrors } = await rowWorkerDecoder();
    try {
      const result = await decoder.decode(packet, new Frame());
      // Never garbage: an error, from the packet workers it fell back to.
      assert.ok(result instanceof DnxInvalidDataError, `expected a decode error, got ${result?.constructor?.name}`);
      assert.equal(startErrors.length, 1);
      assert.equal(startErrors[0].backend, "shared-row");
      assert.match(startErrors[0].error.message, /does not end within the Zig row buffer of 1048576 bytes/);
      assert.match(decoder.idctMode, /^worker-pool\//, "moved to packet workers");
      // Later frames decode on the packet workers.
      const next = await decoder.decode(valid, new Frame());
      assert.ok(!(next instanceof Error), next?.message);
      assert.equal(startErrors.length, 1);
    } finally {
      await decoder.close();
    }
    console.log("ok - a last row that does not fit the row buffer is a decode error and moves to packet workers");
  }

  // The same corruption inside the buffer is an ordinary decode error: no fallback.
  {
    const packet = withLastRow(valid, lastRow.start, 64 * 1024);
    const { decoder, startErrors } = await rowWorkerDecoder();
    try {
      const result = await decoder.decode(packet, new Frame());
      assert.ok(result instanceof DnxInvalidDataError);
      assert.deepEqual(startErrors, []);
      assert.equal(decoder.idctMode, "shared-row-workers/zig-wasm-row");
    } finally {
      await decoder.close();
    }
    console.log("ok - a corrupt row that fits the buffer stays on the row workers");
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

/** `packet` with its last row replaced by `length` bytes of 0xff. */
function withLastRow(packet, lastRowStart, length) {
  const result = new Uint8Array(lastRowStart + length).fill(0xff);
  result.set(packet.subarray(0, lastRowStart));
  return result;
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
