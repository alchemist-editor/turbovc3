#!/usr/bin/env node
// The reused-decoder pool behind registerDnxDecoder
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
      },
      /** The worker crashes (an uncaught error in the worker). */
      crash() {
        for (const fn of [...listeners.error]) fn({ message: "worker crashed" });
      }
    };
    live.add(worker);
    return worker;
  };
  return { factory, live, urls, created: () => created };
}

const base = { dnxFourCc: "AVdh", useSharedMemory: false, concurrency: 2 };

/** Pool counts without the cumulative discard counter. */
function live() {
  const { discarded: _discarded, ...rest } = sharedDecoderPoolStats();
  return rest;
}

async function run(name, fn) {
  try {
    await fn();
    console.log(`ok - ${name}`);
  } finally {
    await closeSharedDecoders();
    setSharedDecoderFactoryForTests(null);
  }
}

await run("N decoders one after another reuse one decoder and one worker pool", async () => {
  const workers = fakeWorkers();
  const options = { ...base, workerFactory: workers.factory, idleCloseMs: 1000 };
  const decoders = new Set();
  // Mediabunny's getSample: build a decoder, decode, close; five times.
  for (let i = 0; i < 5; i += 1) {
    const lease = await acquireSharedDecoder(options);
    assert.ok(!(lease instanceof Error));
    decoders.add(lease.decoder);
    lease.release();
  }
  assert.equal(decoders.size, 1);
  assert.equal(workers.created(), 2, "one pool of two packet workers");
  assert.deepEqual(live(), { decoders: 1, leases: 0, idle: 1 });
  await closeSharedDecoders();
  assert.equal(workers.live.size, 0);
  assert.deepEqual(live(), { decoders: 0, leases: 0, idle: 0 });
});

await run("concurrent decoders never share one (each player keeps its throughput)", async () => {
  const workers = fakeWorkers();
  const options = { ...base, workerFactory: workers.factory, idleCloseMs: 0 };
  const leases = await Promise.all(Array.from({ length: 4 }, () => acquireSharedDecoder(options)));
  assert.equal(new Set(leases.map((lease) => lease.decoder)).size, 4);
  assert.equal(workers.created(), 8);
  assert.deepEqual(live(), { decoders: 4, leases: 4, idle: 0 });
  for (const lease of leases) lease.release();
  await sleep(0);
  assert.equal(workers.live.size, 0);
});

await run("close order does not leak workers, and releases are idempotent", async () => {
  for (const order of [[0, 1, 2], [2, 1, 0], [1, 2, 0]]) {
    const workers = fakeWorkers();
    const options = { ...base, workerFactory: workers.factory, idleCloseMs: 0 };
    const leases = [];
    for (let i = 0; i < 3; i += 1) leases.push(await acquireSharedDecoder(options));
    for (const [step, index] of order.entries()) {
      leases[index].release();
      leases[index].release();
      await sleep(0);
      assert.equal(leases[index].decoder.isClosed, true);
      assert.equal(workers.live.size, 2 * (leases.length - step - 1), `order ${order} after ${index}`);
    }
    assert.equal(workers.created(), 6);
  }
});

await run("at most maxIdleDecoders wait per configuration; the rest close at once", async () => {
  const workers = fakeWorkers();
  const options = { ...base, workerFactory: workers.factory, idleCloseMs: 1000, maxIdleDecoders: 2 };
  const leases = await Promise.all(Array.from({ length: 5 }, () => acquireSharedDecoder(options)));
  for (const lease of leases) lease.release();
  await sleep(0);
  assert.deepEqual(live(), { decoders: 2, leases: 0, idle: 2 });
  assert.equal(workers.live.size, 4);
  // The next two leases take the idle decoders; the third builds a new one.
  const again = [await acquireSharedDecoder(options), await acquireSharedDecoder(options)];
  assert.equal(workers.created(), 10);
  const third = await acquireSharedDecoder(options);
  assert.equal(workers.created(), 12);
  for (const lease of [...again, third]) lease.release();
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
  assert.deepEqual(live(), { decoders: 0, leases: 0, idle: 0 });
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
  assert.deepEqual(live(), { decoders: 2, leases: 2, idle: 0 });
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
  assert.deepEqual(live(), { decoders: 0, leases: 0, idle: 0 });
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

await run("a lease marked failed closes its decoder on release; the next lease builds a new one", async () => {
  const made = [];
  setSharedDecoderFactoryForTests(async () => {
    const decoder = {
      isClosed: false,
      isUsable: true,
      closes: 0,
      async close() {
        decoder.closes += 1;
        decoder.isClosed = true;
      }
    };
    made.push(decoder);
    return decoder;
  });
  const options = { ...base, idleCloseMs: 1000 };
  const before = sharedDecoderPoolStats().discarded;
  const broken = await acquireSharedDecoder(options);
  broken.markFailed();
  broken.release();
  broken.release();
  await sleep(0);
  assert.equal(made[0].closes, 1);
  assert.equal(sharedDecoderPoolStats().discarded, before + 1);
  assert.deepEqual(live(), { decoders: 0, leases: 0, idle: 0 });
  const next = await acquireSharedDecoder(options);
  assert.notEqual(next.decoder, made[0]);
  assert.equal(made.length, 2);
  // A healthy lease is still parked and reused.
  next.release();
  const again = await acquireSharedDecoder(options);
  assert.equal(again.decoder, made[1]);
  assert.equal(made.length, 2);
  assert.equal(sharedDecoderPoolStats().discarded, before + 1);
  again.release();
});

await run("a decoder released after closeSharedDecoders closes instead of parking", async () => {
  const workers = fakeWorkers();
  const options = { ...base, workerFactory: workers.factory, idleCloseMs: 60_000 };
  const lease = await acquireSharedDecoder(options);
  assert.ok(!(lease instanceof Error));
  await closeSharedDecoders();
  lease.release();
  await sleep(0);
  assert.equal(lease.decoder.isClosed, true);
  assert.equal(workers.live.size, 0);
  assert.equal(sharedDecoderPoolStats().idle, 0);
});

for (const useSharedMemory of [false, true]) {
  const backend = useSharedMemory ? "shared-row" : "packet";
  await run(`an idle decoder whose ${backend} workers died is discarded, not handed to the next lease`, async () => {
    const workers = fakeWorkers();
    const options = { ...base, useSharedMemory, workerFactory: workers.factory, idleCloseMs: 60_000 };
    const first = await acquireSharedDecoder(options);
    assert.ok(!(first instanceof Error));
    assert.equal(first.decoder.isUsable, true);
    first.release();
    assert.equal(sharedDecoderPoolStats().idle, 1);
    // Every worker crashes while the decoder waits idle.
    for (const worker of [...workers.live]) worker.crash();
    assert.equal(first.decoder.isUsable, false);
    const before = sharedDecoderPoolStats().discarded;
    const next = await acquireSharedDecoder(options);
    assert.ok(!(next instanceof Error));
    assert.notEqual(next.decoder, first.decoder);
    assert.equal(next.decoder.isUsable, true);
    assert.equal(first.decoder.isClosed, true);
    assert.equal(sharedDecoderPoolStats().discarded, before + 1);
    assert.equal(workers.created(), 4);
    next.release();
  });
}

console.log("Shared decoder pool tests passed.");
