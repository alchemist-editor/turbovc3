#!/usr/bin/env node
// createNodeDecoder (src/node.ts) honours workerUrls overrides and keeps the
// package's Node worker wrappers as the defaults.
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createNodeDecoder } from "../dist/node.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const missingWorker = pathToFileURL(path.join(repoRoot, "dist/workers/does-not-exist.worker.js"));
const nodePacketWorker = pathToFileURL(path.join(repoRoot, "dist/workers/dnxNodePacketDecode.worker.js"));

async function create(options) {
  const errors = [];
  const decoder = await createNodeDecoder({
    dnxFourCc: "AVdh",
    useSharedMemory: false,
    concurrency: 2,
    onWorkerStartError: (error) => errors.push(error),
    ...options
  });
  assert.ok(!(decoder instanceof Error), String(decoder));
  return { decoder, errors };
}

{
  // No override: the Node packet wrapper starts.
  const { decoder, errors } = await create({});
  assert.deepEqual(errors, []);
  assert.ok(decoder.idctMode.startsWith("worker-pool/"), decoder.idctMode);
  await decoder.close();
}

{
  // A packet override that does not exist fails to start and says so; the
  // decoder falls back to the calling thread.
  const { decoder, errors } = await create({ workerUrls: { packet: missingWorker } });
  assert.equal(errors.length, 1);
  assert.equal(errors[0].backend, "packet");
  assert.ok(errors[0].error instanceof Error);
  assert.ok(!decoder.idctMode.startsWith("worker-pool/"), decoder.idctMode);
  await decoder.close();
}

{
  // A shared-row override that does not exist is reported; the packet
  // fallback still uses the default Node wrapper.
  const { decoder, errors } = await create({
    useSharedMemory: true,
    workerUrls: { sharedRow: missingWorker.href }
  });
  assert.deepEqual(errors.map((error) => error.backend), ["shared-row"]);
  assert.ok(decoder.idctMode.startsWith("worker-pool/"), decoder.idctMode);
  await decoder.close();
}

{
  // An override that is a worker_threads module runs.
  const { decoder, errors } = await create({ workerUrls: { packet: nodePacketWorker } });
  assert.deepEqual(errors, []);
  assert.ok(decoder.idctMode.startsWith("worker-pool/"), decoder.idctMode);
  await decoder.close();
}

console.log("Node decoder worker URL overrides passed.");
