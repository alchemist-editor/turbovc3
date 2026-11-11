#!/usr/bin/env node
// The shared, reference-counted decoder pool behind registerDnxDecoder
// (src/dnxSharedDecoderPool.ts), with fake workers so worker lifetimes are visible.
import assert from "node:assert/strict";
import { setTimeout as sleep } from "node:timers/promises";
import {
  acquireSharedDecoder,
  closeSharedDecoders,
  sharedDecoderPoolStats
} from "../dist/index.js";
import { setSharedDecoderFactoryForTests } from "../dist/dnxSharedDecoderPool.js";

/** Packet workers that answer init and count how many are alive. */
function fakeWorkers() {
  const live = new Set();
  let created = 0;
  const urls = [];
  const factory = (kind, url) => {
    created += 1;
    urls.push(String(url));
    const listeners = { message: new Set(), error: new Set() };
    const worker = {
      kind,
      addEventListener(type, fn) {
        listeners[type].add(fn);
      },
      removeEventListener(type, fn) {
        listeners[type].delete(fn);
      },
      postMessage(message) {
        if (message.type === "init") {
          worker.init = message;
          queueMicrotask(() => {
            for (const fn of [...listeners.message]) fn({ data: { type: "ready", mode: "fake" } });
          });
        }
      },
      terminate() {
        live.delete(worker);
      }
    };
    live.add(worker);
    return worker;
  };
  return { factory, live, urls, created: () => created };
}

const base = { dnxFourCc: "AVdh", useSharedMemory: false, concurrency: 2 };

async function run(name, fn) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } finally {
    await closeSharedDecoders();
    setSharedDecoderFactoryForTests(null);
  }
}

await run("N decoders of one configuration share one decoder and one worker pool", async () => {
  const workers = fakeWorkers();
  const options = { ...base, workerFactory: workers.factory, idleCloseMs: 0 };
  const leases = await Promise.all(Array.from({ length: 5 }, () => acquireSharedDecoder(options)));
  assert.ok(leases.every((lease) => !(lease instanceof Error)));
  assert.equal(new Set(leases.map((lease) => lease.decoder)).size, 1);
  assert.equal(workers.created(), 2, "one pool of two packet workers");
  assert.deepEqual(sharedDecoderPoolStats(), { decoders: 1, leases: 5 });
  for (const lease of leases) lease.release();
  await sleep(0);
  assert.equal(workers.live.size, 0);
  assert.deepEqual(sharedDecoderPoolStats(), { decoders: 0, leases: 0 });
});

await run("close order does not leak workers, and releases are idempotent", async () => {
  for (const order of [[0, 1, 2], [2, 1, 0], [1, 2, 0]]) {
    const workers = fakeWorkers();
    const options = { ...base, workerFactory: workers.factory, idleCloseMs: 0 };
    const leases = [];
    for (let i = 0; i < 3; i += 1) leases.push(await acquireSharedDecoder(options));
    for (const index of order) {
      leases[index].release();
      leases[index].release();
      await sleep(0);
      const remaining = leases.length - order.indexOf(index) - 1;
      assert.equal(workers.live.size, remaining > 0 ? 2 : 0, `order ${order} after ${index}`);
      assert.equal(leases[0].decoder.isClosed, remaining === 0);
    }
    assert.equal(workers.created(), 2);
  }
});

await run("an idle decoder stays warm for the next lease, then closes", async () => {
  const workers = fakeWorkers();
  const options = { ...base, workerFactory: workers.factory, idleCloseMs: 40 };
  const first = await acquireSharedDecoder(options);
  first.release();
  await sleep(5);
  // A seek right after: same decoder, no new workers.
  const second = await acquireSharedDecoder(options);
  assert.equal(second.decoder, first.decoder);
  assert.equal(workers.created(), 2);
  second.release();
  await sleep(80);
  assert.equal(workers.live.size, 0);
  assert.equal(first.decoder.isClosed, true);
  // After the close, a new lease builds a new pool.
  const third = await acquireSharedDecoder(options);
  assert.notEqual(third.decoder, first.decoder);
  assert.equal(workers.created(), 4);
  third.release();
});

await run("different configurations get different decoders", async () => {
  const workers = fakeWorkers();
  const a = await acquireSharedDecoder({ ...base, workerFactory: workers.factory, idleCloseMs: 0 });
  const b = await acquireSharedDecoder({
    ...base,
    workerFactory: workers.factory,
    allowedOutputFormats: ["yuv422p8"],
    idleCloseMs: 0
  });
  assert.notEqual(a.decoder, b.decoder);
  assert.deepEqual(sharedDecoderPoolStats(), { decoders: 2, leases: 2 });
  a.release();
  b.release();
  await sleep(0);
  assert.equal(workers.live.size, 0);
});

await run("a creation error is returned and not cached", async () => {
  let calls = 0;
  setSharedDecoderFactoryForTests(async () => {
    calls += 1;
    return new Error("no decoder today");
  });
  const first = await acquireSharedDecoder({ ...base, idleCloseMs: 0 });
  assert.ok(first instanceof Error);
  const second = await acquireSharedDecoder({ ...base, idleCloseMs: 0 });
  assert.ok(second instanceof Error);
  assert.equal(calls, 2);
  assert.deepEqual(sharedDecoderPoolStats(), { decoders: 0, leases: 0 });
});

await run("worker and wasm URL options reach the workers as absolute URLs", async () => {
  const workers = fakeWorkers();
  const lease = await acquireSharedDecoder({
    ...base,
    workerFactory: workers.factory,
    workerUrls: { packet: "https://example.test/assets/packet-worker.js" },
    wasmUrls: {
      rowDecoder: "https://example.test/assets/row.wasm",
      idctKernel: new URL("https://example.test/assets/idct.wasm")
    },
    idleCloseMs: 0
  });
  assert.ok(!(lease instanceof Error));
  assert.deepEqual(workers.urls, [
    "https://example.test/assets/packet-worker.js",
    "https://example.test/assets/packet-worker.js"
  ]);
  const init = [...workers.live][0].init;
  assert.deepEqual(init.wasmUrls, {
    rowDecoder: "https://example.test/assets/row.wasm",
    idctKernel: "https://example.test/assets/idct.wasm"
  });
  lease.release();
});

await run("worker start failures reach onWorkerStartError and the decoder still falls back", async () => {
  const errors = [];
  const failing = () => {
    throw new Error("worker blocked");
  };
  const lease = await acquireSharedDecoder({
    ...base,
    workerFactory: failing,
    onWorkerStartError: (error) => errors.push(error),
    idleCloseMs: 0
  });
  assert.ok(!(lease instanceof Error));
  assert.equal(errors.length, 1);
  assert.equal(errors[0].backend, "packet");
  assert.match(errors[0].error.message, /worker blocked/);
  // The calling-thread backend: no worker prefix.
  assert.ok(!lease.decoder.idctMode.startsWith("worker-pool/"));
  lease.release();
});

console.log("Shared decoder pool tests passed.");
