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
  assert.deepEqual(module.sharedDecoderPoolStats(), { decoders: 0, leases: 0, idle: 0 });
} finally {
  seekInput.dispose();
}

console.log("Mediabunny compatibility preflight and DNx decode passed.");

async function loadModule() {
  const entry = JSON.stringify(path.join(repoRoot, "src/dnxMediabunny.ts"));
  const result = await build({
    stdin: {
      contents: `
        export { registerDnxDecoder } from ${entry};
        export { sharedDecoderPoolStats } from ${JSON.stringify(path.join(repoRoot, "src/dnxSharedDecoderPool.ts"))};
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
