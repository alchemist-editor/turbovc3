#!/usr/bin/env node
// A frame that fails on the shared-row path must not corrupt the next one.
// When one row of frame A fails (a row error, or a worker dying), A's other
// rows may still be queued on the healthy row workers. If the next decode
// starts before they finish, those stale A rows can write into a frame
// buffer B is using: a Frame keeps its shared buffer across decodes, so
// reusing the Frame of a failed A hands B the buffer A's rows still write
// to. Per-worker FIFO only protects B when A and B share a row layout and
// the same workers; here neither holds.
//
// Fake shared-row workers make the timing deterministic. A "decode" fills
// the row's luma rows with a tag byte (0xaa for 2160p A, 0xbb for 1080p B)
// through the real frame layout.
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

/**
 * `concurrency` fake row workers. `plan.onRow(worker, request)` returns
 * "error" (an error response), "crash" (an error event; the worker then never
 * answers), "late-crash" (the same after 30 ms), a delay in ms, or nothing.
 */
async function createDecoder(plan, concurrency = 2) {
  const workers = [];
  const factory = (kind) => {
    const index = workers.length;
    const listeners = { message: new Set(), error: new Set() };
    let queue = Promise.resolve();
    let dead = false;
    const emit = (type, data) => {
      for (const fn of [...listeners[type]]) fn(data);
    };
    const worker = {
      kind,
      index,
      addEventListener: (type, fn) => listeners[type].add(fn),
      removeEventListener: (type, fn) => listeners[type].delete(fn),
      terminate() {
        dead = true;
      },
      postMessage(request) {
        if (request.type === "init") {
          queueMicrotask(() => emit("message", { data: { type: "ready", mode: "fake" } }));
          return;
        }
        if (request.type !== "decode-row") return;
        // One request at a time, in order, like a real worker.
        queue = queue.then(async () => {
          if (dead) return;
          const action = plan.onRow?.(index, request);
          if (action === "error") {
            emit("message", { data: { type: "error", requestId: request.requestId, message: "corrupt row" } });
            return;
          }
          if (action === "late-crash") await sleep(30);
          if (action === "crash" || action === "late-crash") {
            emit("error", { message: `fake row worker ${index} crashed` });
            dead = true;
            return;
          }
          if (typeof action === "number") await sleep(action);
          if (dead) return;
          const layout = createDnxFrameLayout(request.header, request.frame);
          const luma = layout.planes[0];
          const tag = request.header.width === 3840 ? 0xaa : 0xbb;
          for (let y = request.row * 16; y < Math.min((request.row + 1) * 16, luma.height); y += 1) {
            luma.bytes.fill(tag, y * luma.stride, y * luma.stride + luma.width * layout.bytesPerSample);
          }
          emit("message", { data: { type: "decoded-row", requestId: request.requestId } });
        });
      }
    };
    workers.push(worker);
    return worker;
  };
  const decoder = await Decoder.create({
    dnxFourCc: "AVdh",
    useSharedMemory: true,
    concurrency,
    workerFactory: factory,
    allowedOutputFormats: ["yuv422p8"]
  });
  assert.ok(!(decoder instanceof Error), String(decoder));
  return decoder;
}

/** decode(), or a rejection if it neither resolves nor returns within `ms`. */
function settlesWithin(promise, ms, label) {
  let timer;
  const hung = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} hung`)), ms);
  });
  return Promise.race([promise, hung]).finally(() => clearTimeout(timer));
}

/** Luma samples of a 1080p B frame that are not B's own. */
function staleSamples(decoded) {
  const luma = decoded.layout.planes[0];
  let stale = 0;
  for (let y = 0; y < luma.height; y += 1) {
    for (let x = 0; x < luma.width; x += 1) {
      if (luma.bytes[y * luma.stride + x] !== 0xbb) stale += 1;
    }
  }
  return stale;
}

// A row error: A fails at row 1 while slow worker 0 still has most of A's rows.
{
  const plan = { failA: false };
  plan.onRow = (worker, request) => {
    const isA = request.header.width === 3840;
    if (isA && plan.failA && request.row === 1) return "error";
    return isA && worker === 0 ? 3 : undefined;
  };
  const decoder = await createDecoder(plan);
  try {
    const frame = new Frame();
    // A healthy 2160p decode leaves the Frame holding a 2160p-sized shared buffer.
    assert.ok(!((await decoder.decode(frameA, frame)) instanceof Error));
    plan.failA = true;
    assert.ok((await decoder.decode(frameA, frame)) instanceof Error, "frame A fails");
    // B reuses the Frame, as Mediabunny's decoder does after a failure.
    const decoded = await decoder.decode(frameB, frame);
    assert.ok(!(decoded instanceof Error), decoded?.message);
    assert.equal(staleSamples(decoded), 0, "frame A's leftover rows wrote into frame B");
  } finally {
    await decoder.close();
  }
  console.log("ok - a failed row's frame finishes its other rows before the next frame starts");
}

// A worker dies: of three workers, worker 2 crashes at its first row of A
// while slow worker 0 still has A's rows queued and worker 1 is fast. B then
// runs on workers 0 and 1, so worker 1's B rows land before worker 0's
// leftover A rows. Only the dead worker's rows may fail at once.
{
  const plan = { crashA: false };
  plan.onRow = (worker, request) => {
    const isA = request.header.width === 3840;
    if (isA && plan.crashA && worker === 2) return "crash";
    return isA && worker === 0 ? 3 : undefined;
  };
  const decoder = await createDecoder(plan, 3);
  try {
    const frame = new Frame();
    assert.ok(!((await decoder.decode(frameA, frame)) instanceof Error));
    plan.crashA = true;
    const failed = await settlesWithin(decoder.decode(frameA, frame), 5000, "frame A");
    assert.ok(failed instanceof Error, "frame A fails");
    assert.match(failed.message, /crashed/);
    const decoded = await settlesWithin(decoder.decode(frameB, frame), 5000, "frame B");
    assert.ok(!(decoded instanceof Error), decoded?.message);
    assert.equal(staleSamples(decoded), 0, "frame A's leftover rows wrote into frame B");
    // Still usable on the one remaining worker.
    assert.equal(decoder.isUsable, true);
    const again = await settlesWithin(decoder.decode(frameB, new Frame()), 5000, "frame B on one worker");
    assert.ok(!(again instanceof Error), again?.message);
    assert.equal(staleSamples(again), 0);
  } finally {
    await decoder.close();
  }
  console.log("ok - a dead worker's frame waits for the healthy workers' rows; the decoder keeps working");
}

// No hang: the dying worker holds the only rows still outstanding (worker 0
// has finished), and later the last worker dies too.
{
  const plan = { crash: null };
  // Worker 0 answers its rows at once; worker 1 dies 30 ms later, holding the
  // only rows still outstanding.
  plan.onRow = (worker) => (plan.crash === worker ? "late-crash" : undefined);
  const decoder = await createDecoder(plan);
  try {
    plan.crash = 1;
    const failed = await settlesWithin(decoder.decode(frameB, new Frame()), 5000, "frame with a dying worker");
    assert.ok(failed instanceof Error && /crashed/.test(failed.message), failed?.message);
    plan.crash = 0;
    const lastWorker = await settlesWithin(decoder.decode(frameB, new Frame()), 5000, "frame on the last worker");
    assert.ok(lastWorker instanceof Error && /crashed/.test(lastWorker.message), lastWorker?.message);
    assert.equal(decoder.isUsable, false);
  } finally {
    await settlesWithin(decoder.close(), 5000, "close");
  }
  console.log("ok - a frame whose worker dies settles instead of waiting forever");
}

console.log("Shared-row failure isolation passed.");

async function firstPacket(fixture) {
  let bytes = await readFile(path.join(repoRoot, "tests/fixtures", fixture));
  if (fixture.endsWith(".gz")) bytes = gunzipSync(bytes);
  return (await inspectDnxContainer(new Uint8Array(bytes))).dnxTracks[0].firstPacket.data;
}
