#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const module = await loadModule();
const decoder = await module.createDnxWasmRowDecoder(
  await readFile(path.join(repoRoot, "wasm/generated/dnx_row_decoder.wasm"))
);
try {
  // 8K DCI: 8192x4320 is 512 macroblocks by 270 rows; the frame buffer holds
  // it at 4:4:4 with 16-bit samples, and the packet buffer its largest
  // (4:4:4) packet of about 31.1 MB.
  assert.deepEqual(decoder.capacities, {
    rowBytes: 2 * 1024 * 1024,
    packetBytes: 32 * 1024 * 1024,
    frameBytes: 8192 * 4320 * 3 * 2,
    macroblocksPerRow: 512,
    rows: 270
  });
  assert.equal(Math.ceil((512 * 270 * 57344) / 255) <= decoder.capacities.packetBytes, true);
  assert.throws(
    () => decoder.decodeRow(new Uint8Array(), decoder.capacities.macroblocksPerRow + 1, 8, false, null),
    /macroblock width 513 exceeds.*capacity of 512/
  );
  assert.throws(
    () => decoder.decodeFrame(
      new Uint8Array(),
      Array.from({ length: decoder.capacities.rows + 1 }, () => ({ start: 0, end: 0 })),
      1,
      decoder.capacities.rows + 1,
      8,
      false,
      false,
      null
    ),
    /row count 271 exceeds.*capacity of 270/
  );
  assert.throws(
    () => decoder.decodeFrame(
      new Uint8Array(decoder.capacities.packetBytes + 1),
      [{ start: 0, end: 0 }],
      1,
      1,
      8,
      false,
      false,
      null
    ),
    /exceeding the Zig buffer capacity of 33554432 bytes/
  );
  assert.throws(
    () => decoder.decodeFrame(
      new Uint8Array(1024),
      Array.from({ length: 271 }, () => ({ start: 0, end: 0 })),
      512,
      271,
      12,
      true,
      false,
      null
    ),
    /row count 271 exceeds/
  );
} finally {
  decoder.destroy();
}

// The packet and frame buffers are not static: an instance that only decodes
// rows (the shared-row workers) never commits the 8K frame size.
{
  const wasm = await WebAssembly.instantiate(
    await WebAssembly.compile(await readFile(path.join(repoRoot, "wasm/generated/dnx_row_decoder.wasm"))),
    {}
  );
  const exports = wasm.exports;
  const initialBytes = exports.memory.buffer.byteLength;
  assert.ok(initialBytes < 16 * 1024 * 1024, `a fresh instance holds ${initialBytes} bytes`);
  assert.equal(exports.dnx_packet_buffer_length(), 0);
  assert.equal(exports.dnx_frame_buffer_length(), 0);
  // Past the limits: invalid arguments, and nothing is allocated.
  assert.equal(exports.dnx_reserve_frame(exports.dnx_packet_capacity() + 1, 0), 1);
  assert.equal(exports.dnx_reserve_frame(0, exports.dnx_frame_capacity() + 1), 1);
  assert.equal(exports.memory.buffer.byteLength, initialBytes);
  // At the limits: the buffers grow to hold them, and a smaller reserve after
  // keeps them where they are.
  assert.equal(exports.dnx_reserve_frame(exports.dnx_packet_capacity(), exports.dnx_frame_capacity()), 0);
  assert.ok(exports.dnx_packet_buffer_length() >= exports.dnx_packet_capacity());
  assert.ok(exports.dnx_frame_buffer_length() >= exports.dnx_frame_capacity());
  const packetPointer = exports.dnx_packet_buffer_ptr();
  const framePointer = exports.dnx_frame_buffer_ptr();
  assert.equal(exports.dnx_reserve_frame(1024, 1024), 0);
  assert.equal(exports.dnx_packet_buffer_ptr(), packetPointer);
  assert.equal(exports.dnx_frame_buffer_ptr(), framePointer);
  // A decode past the reserved packet length is refused, not read out of bounds.
  assert.equal(exports.dnx_decode_frame(exports.dnx_packet_buffer_length() + 1, 1, 1, 8, 0, 0, 0, 0, 0, 0, 0, 0), 1);
}

console.log("DNx Zig native capacity boundaries passed.");

async function loadModule() {
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
