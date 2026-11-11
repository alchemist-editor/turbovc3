#!/usr/bin/env node
// A frame that fails on the shared-row path must not corrupt the next one.
// When one row of frame A fails, A's other rows may still be queued on the
// row workers. If the next decode starts before they finish, those stale A
// rows can write into a frame buffer B is using: a Frame keeps its shared
// buffer across decodes, so reusing the Frame of a failed A hands B the
// buffer A's rows still write to. Per-worker FIFO only protects B when A and
// B share a row layout; here they do not (2160p, then 1080p).
//
// Fake shared-row workers make the timing deterministic: worker 0 is slow,
// worker 1 fails A's row 1 at once. A "decode" fills the row's luma rows with
// a tag byte (0xaa for A, 0xbb for B) through the real frame layout.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { gunzipSync } from "node:zlib";
import { Decoder, Frame, inspectDnxContainer } from "../dist/index.js";
import { createDnxFrameLayout } from "../dist/dnxReconstruction.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const frameA = await firstPacket("dnxhr_hq_2160p30_testsrc.mov.gz");
const frameB = await firstPacket("oracle_dnxhr_hq_1080p30_8bit_cid1272.mov");

let failRowOfA = false;
const workers = [];
const factory = (kind) => {
  const index = workers.length;
  const listeners = { message: new Set(), error: new Set() };
  let queue = Promise.resolve();
  const emit = (data) => {
    for (const fn of [...listeners.message]) fn({ data });
  };
  const worker = {
    kind,
    addEventListener: (type, fn) => listeners[type].add(fn),
    removeEventListener: (type, fn) => listeners[type].delete(fn),
    terminate() {},
    postMessage(request) {
      if (request.type === "init") {
        queueMicrotask(() => emit({ type: "ready", mode: "fake" }));
        return;
      }
      if (request.type !== "decode-row") return;
      // One request at a time, in order, like a real worker.
      queue = queue.then(async () => {
        const isA = request.header.width === 3840;
        if (isA && failRowOfA && request.row === 1) {
          emit({ type: "error", requestId: request.requestId, message: "corrupt row" });
          return;
        }
        if (isA && index === 0) await sleep(3);
        const layout = createDnxFrameLayout(request.header, request.frame);
        const luma = layout.planes[0];
        for (let y = request.row * 16; y < Math.min((request.row + 1) * 16, luma.height); y += 1) {
          luma.bytes.fill(isA ? 0xaa : 0xbb, y * luma.stride, y * luma.stride + luma.width * layout.bytesPerSample);
        }
        emit({ type: "decoded-row", requestId: request.requestId });
      });
    }
  };
  workers.push(worker);
  return worker;
};

const decoder = await Decoder.create({
  dnxFourCc: "AVdh",
  useSharedMemory: true,
  concurrency: 2,
  workerFactory: factory,
  allowedOutputFormats: ["yuv422p8"]
});
assert.ok(!(decoder instanceof Error), String(decoder));
try {
  const frame = new Frame();
  // A healthy 2160p decode leaves the Frame holding a 2160p-sized shared buffer.
  assert.ok(!((await decoder.decode(frameA, frame)) instanceof Error));
  // Frame A fails at row 1 while worker 0 still has most of A's rows queued.
  failRowOfA = true;
  const failed = await decoder.decode(frameA, frame);
  assert.ok(failed instanceof Error, "frame A fails");
  // Frame B reuses the Frame, as Mediabunny's decoder does after a failure.
  const decoded = await decoder.decode(frameB, frame);
  assert.ok(!(decoded instanceof Error), decoded?.message);
  const luma = decoded.layout.planes[0];
  let stale = 0;
  for (let y = 0; y < luma.height; y += 1) {
    for (let x = 0; x < luma.width; x += 1) {
      if (luma.bytes[y * luma.stride + x] !== 0xbb) stale += 1;
    }
  }
  assert.equal(stale, 0, `${stale} luma samples of frame B were overwritten by frame A's leftover rows`);
  console.log("ok - a failed frame's leftover rows do not write into the next frame");
} finally {
  await decoder.close();
}
console.log("Shared-row failure isolation passed.");

async function firstPacket(fixture) {
  let bytes = await readFile(path.join(repoRoot, "tests/fixtures", fixture));
  if (fixture.endsWith(".gz")) bytes = gunzipSync(bytes);
  return (await inspectDnxContainer(new Uint8Array(bytes))).dnxTracks[0].firstPacket.data;
}
