#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const module = await loadModule();
const originalGetCodec = module.InputVideoTrack.prototype.getCodec;
try {
  module.InputVideoTrack.prototype.getCodec = undefined;
  assert.throws(
    () => module.registerDnxDecoder(),
    /Incompatible Mediabunny API: missing getCodec.*supports Mediabunny \^1\.50\.8/
  );
} finally {
  module.InputVideoTrack.prototype.getCodec = originalGetCodec;
}

module.registerDnxDecoder();
module.registerDnxDecoder();
const bytes = new Uint8Array(
  await readFile(path.join(repoRoot, "tests/fixtures/oracle_dnxhr_lb_1080p30_8bit_cid1274.mov"))
);
const input = new module.Input({
  formats: [new module.QuickTimeInputFormat()],
  source: new module.BufferSource(bytes)
});
try {
  const track = await input.getPrimaryVideoTrack();
  assert.ok(track);
  assert.equal(await track.getCodec(), "dnx");
  assert.equal(await track.getCodecParameterString(), "AVdh");
  assert.equal(await track.canDecode(), true);
  let sample = null;
  for await (const candidate of new module.VideoSampleSink(track).samples()) {
    sample = candidate;
    break;
  }
  assert.ok(sample);
  try {
    assert.equal(sample.format, "I422");
    assert.equal(sample.visibleRect.width, 1920);
    assert.equal(sample.visibleRect.height, 1080);
  } finally {
    sample.close();
  }
} finally {
  input.dispose();
}

// Options: a later call replaces them. Every getSample() builds a Mediabunny
// decoder; they reuse one turbovc3 decoder, which closes when they are done.
module.registerDnxDecoder({ useSharedMemory: false, idleCloseMs: 0 });
const seekInput = new module.Input({
  formats: [new module.QuickTimeInputFormat()],
  source: new module.BufferSource(bytes)
});
try {
  const track = await seekInput.getPrimaryVideoTrack();
  const sink = new module.VideoSampleSink(track);
  for (let i = 0; i < 3; i += 1) {
    const sample = await sink.getSample(0);
    assert.ok(sample);
    sample.close();
  }
  // Mediabunny closes its decoder asynchronously after the sample is out.
  for (let i = 0; i < 50 && module.sharedDecoderPoolStats().decoders > 0; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  const { discarded: _discarded, ...pool } = module.sharedDecoderPoolStats();
  assert.deepEqual(pool, { decoders: 0, leases: 0, idle: 0 });
} finally {
  seekInput.dispose();
}

// A decode that rejects marks the lease failed: the decoder is closed on
// release, not parked for the next getSample().
{
  const broken = [];
  module.setSharedDecoderFactoryForTests(async () => {
    const decoder = {
      isClosed: false,
      isUsable: true,
      desiredSize: 1,
      decodeQueueSize: 0,
      dequeued: Promise.resolve(),
      async decode() {
        throw new Error("row worker crashed");
      },
      async close() {
        decoder.isClosed = true;
      }
    };
    broken.push(decoder);
    return decoder;
  });
  module.registerDnxDecoder({ useSharedMemory: false, idleCloseMs: 60_000 });
  const before = module.sharedDecoderPoolStats().discarded;
  const failInput = new module.Input({
    formats: [new module.QuickTimeInputFormat()],
    source: new module.BufferSource(bytes)
  });
  try {
    const track = await failInput.getPrimaryVideoTrack();
    const sink = new module.VideoSampleSink(track);
    await assert.rejects(sink.getSample(0), /row worker crashed/);
    for (let i = 0; i < 50 && module.sharedDecoderPoolStats().discarded === before; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(module.sharedDecoderPoolStats().discarded, before + 1);
    assert.equal(broken[0].isClosed, true);
    assert.equal(module.sharedDecoderPoolStats().idle, 0);
  } finally {
    failInput.dispose();
    module.setSharedDecoderFactoryForTests(null);
    module.registerDnxDecoder({});
  }
}

// A decoder whose workers die mid-lease never frees capacity: decode() must
// report the failure (and close the decoder) instead of waiting forever, and
// must not reject, which would surface as an unhandled rejection when a later
// Mediabunny releases close() through its poisoned call serializer.
{
  const dying = [];
  module.setSharedDecoderFactoryForTests(async () => {
    let died = null;
    const decoder = {
      isClosed: false,
      isUsable: true,
      // Full, and capacity never returns once the workers are gone.
      desiredSize: 0,
      decodeQueueSize: 0,
      get dequeued() {
        // The first wait ends when the last worker dies; later waits never end,
        // like a worker pool with no workers left.
        died ??= new Promise((resolve) => setTimeout(() => {
          decoder.isUsable = false;
          resolve();
        }, 10));
        return decoder.isUsable ? died : new Promise(() => {});
      },
      async decode() {
        throw new Error("decode should not be reached");
      },
      async close() {
        decoder.isClosed = true;
      }
    };
    dying.push(decoder);
    return decoder;
  });
  module.registerDnxDecoder({ useSharedMemory: false, idleCloseMs: 60_000 });
  const before = module.sharedDecoderPoolStats().discarded;
  const dyingInput = new module.Input({
    formats: [new module.QuickTimeInputFormat()],
    source: new module.BufferSource(bytes)
  });
  let guard;
  const unhandled = [];
  const onUnhandled = (reason) => unhandled.push(reason);
  process.on("unhandledRejection", onUnhandled);
  try {
    const track = await dyingInput.getPrimaryVideoTrack();
    const sink = new module.VideoSampleSink(track);
    const hung = new Promise((_, reject) => {
      guard = setTimeout(() => reject(new Error("decode() hung on a decoder whose workers died")), 2000);
    });
    await assert.rejects(Promise.race([sink.getSample(0), hung]), /can no longer decode/);
    for (let i = 0; i < 50 && module.sharedDecoderPoolStats().discarded === before; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    // The lease is back at once, closed as failed: nothing leased or idle.
    assert.equal(module.sharedDecoderPoolStats().discarded, before + 1);
    assert.equal(dying[0].isClosed, true);
    const { discarded: _d, ...pool } = module.sharedDecoderPoolStats();
    assert.deepEqual(pool, { decoders: 0, leases: 0, idle: 0 });
    // Let Mediabunny finish closing its decoder, then check nothing escaped.
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.deepEqual(unhandled.map(String), []);
  } finally {
    process.off("unhandledRejection", onUnhandled);
    clearTimeout(guard);
    dyingInput.dispose();
    module.setSharedDecoderFactoryForTests(null);
    module.registerDnxDecoder({});
  }
}

console.log("Mediabunny compatibility preflight and DNx decode passed.");

async function loadModule() {
  const entry = JSON.stringify(path.join(repoRoot, "src/dnxMediabunny.ts"));
  const result = await build({
    stdin: {
      contents: `
        export { registerDnxDecoder } from ${entry};
        export { sharedDecoderPoolStats, setSharedDecoderFactoryForTests } from ${JSON.stringify(path.join(repoRoot, "src/dnxSharedDecoderPool.ts"))};
        export { BufferSource, Input, InputVideoTrack, QuickTimeInputFormat, VideoSampleSink } from "mediabunny";
      `,
      resolveDir: repoRoot,
      sourcefile: "mediabunny-compat-test-entry.ts"
    },
    bundle: true,
    format: "esm",
    platform: "node",
    target: "node22",
    write: false
  });
  return import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString("base64")}`);
}
