import { expect, test } from "@playwright/test";

const fixtureUrl = "/tests/fixtures/dnxhr-lb-op1a-pcm.mxf";

test("synchronous Zig/WASM frame backend decodes", async ({ page }) => {
  await page.goto("/");
  const result = await decodeFixture(page, { concurrency: 0, useSharedMemory: false });
  expect(result.mode).toBe("zig-wasm-frame");
  expect(result).toMatchObject({ width: 1280, height: 720, pixelFormat: "yuv422p8" });
});

test("packet workers start and decode", async ({ page }) => {
  await page.goto("/");
  const result = await decodeFixture(page, { concurrency: 2, useSharedMemory: false });
  expect(result.mode).toBe("worker-pool/zig-wasm-frame");
  expect(result.filled).toBe(true);
});

test("cross-origin-isolated shared-row workers start and decode", async ({ page }) => {
  await page.goto("/");
  const result = await decodeFixture(page, { concurrency: 2, useSharedMemory: true });
  expect(result.crossOriginIsolated).toBe(true);
  expect(result.canUseSharedMemory).toBe(true);
  expect(result.mode).toBe("shared-row-workers/zig-wasm-row");
  expect(result.filled).toBe(true);
});

test("interlaced DNxHD weaves fields across backend configurations", async ({ page }) => {
  await page.goto("/");
  const results = [];
  for (const options of [
    { concurrency: 0, useSharedMemory: false },
    { concurrency: 2, useSharedMemory: false },
    { concurrency: 2, useSharedMemory: true }
  ]) {
    results.push(await decodeFixture(
      page,
      options,
      "/tests/fixtures/oracle_dnxhd_1080i2997_10bit_cid1241.mxf",
      "AVdn"
    ));
  }
  for (const result of results) {
    expect(result).toMatchObject({
      filled: true,
      width: 1920,
      height: 1080,
      pixelFormat: "yuv422p10",
      scanType: "interlaced-top-field-first"
    });
  }
});

test("missing native assets fall back to TypeScript", async ({ page }) => {
  await page.route("**/wasm/generated/*.wasm", (route) => route.fulfill({ status: 404 }));
  await page.goto("/");
  const result = await decodeFixture(page, { concurrency: 0, useSharedMemory: false });
  expect(result.mode).toBe("typescript-idct");
  expect(result.filled).toBe(true);
});

test("wasm and worker URL options reach every backend", async ({ page }) => {
  const root = new URL("../..", import.meta.url);
  // The default location is gone; only the overridden URLs serve the modules.
  await page.route("**/wasm/generated/*.wasm", (route) => route.fulfill({ status: 404 }));
  await page.route("**/moved/*.wasm", (route) => {
    const name = new URL(route.request().url()).pathname.endsWith("row.wasm")
      ? "dnx_row_decoder.wasm"
      : "dnx_idct_kernel.wasm";
    return route.fulfill({
      path: new URL(`wasm/generated/${name}`, root).pathname,
      contentType: "application/wasm",
      headers: { "Cross-Origin-Resource-Policy": "same-origin" }
    });
  });
  const workerRequests = [];
  page.on("request", (request) => {
    if (request.url().includes("?moved=1")) workerRequests.push(new URL(request.url()).pathname);
  });
  await page.goto("/");
  const urls = {
    wasmUrls: { rowDecoder: "/moved/row.wasm", idctKernel: "/moved/idct.wasm" },
    workerUrls: {
      sharedRow: "/dist/workers/dnxSharedRowDecode.worker.js?moved=1",
      packet: "/dist/workers/dnxPacketDecode.worker.js?moved=1"
    }
  };
  const sync = await decodeFixture(page, { concurrency: 0, useSharedMemory: false, ...urls });
  expect(sync.mode).toBe("zig-wasm-frame");
  const packet = await decodeFixture(page, { concurrency: 2, useSharedMemory: false, ...urls });
  expect(packet.mode).toBe("worker-pool/zig-wasm-frame");
  const shared = await decodeFixture(page, { concurrency: 2, useSharedMemory: true, ...urls });
  expect(shared.mode).toBe("shared-row-workers/zig-wasm-row");
  expect(new Set(workerRequests)).toEqual(
    new Set(["/dist/workers/dnxPacketDecode.worker.js", "/dist/workers/dnxSharedRowDecode.worker.js"])
  );
});

test("worker start failures are reported and the decoder falls back", async ({ page }) => {
  await page.goto("/");
  const result = await page.evaluate(async () => {
    const { Decoder } = await import("/dist/dnxDecoder.js");
    const errors = [];
    const decoder = await Decoder.create({
      dnxFourCc: "AVdh",
      useSharedMemory: true,
      concurrency: 2,
      workerUrls: { sharedRow: "/missing/row.worker.js", packet: "/missing/packet.worker.js" },
      onWorkerStartError: ({ backend, error }) => errors.push({ backend, message: error.message })
    });
    if (decoder instanceof Error) throw decoder;
    const mode = decoder.idctMode;
    await decoder.close();
    return { mode, backends: errors.map((e) => e.backend) };
  });
  expect(result.backends).toEqual(["shared-row", "packet"]);
  expect(result.mode).toBe("zig-wasm-frame");
});

test("Mediabunny decoders share one worker pool across getSample calls", async ({ page }) => {
  // dist imports the bare "mediabunny" specifier: map it for this page.
  await page.route("**/", async (route) => {
    const response = await route.fetch();
    const html = (await response.text()).replace(
      "<head>",
      '<head><script type="importmap">{"imports":{"mediabunny":"/node_modules/mediabunny/dist/bundles/mediabunny.mjs"}}</script>'
    );
    await route.fulfill({ response, body: html });
  });
  await page.goto("/");
  const workersStarted = [];
  page.on("request", (request) => {
    if (request.url().includes("/dist/workers/")) workersStarted.push(request.url());
  });
  const result = await page.evaluate(async () => {
    const [{ registerDnxDecoder }, { sharedDecoderPoolStats }] = await Promise.all([
      import("/dist/dnxMediabunny.js"),
      import("/dist/dnxSharedDecoderPool.js")
    ]);
    const mediabunny = await import("mediabunny");
    registerDnxDecoder({ useSharedMemory: false, idleCloseMs: 2000 });
    const response = await fetch("/tests/fixtures/oracle_dnxhr_lb_1080p30_8bit_cid1274.mov");
    const input = new mediabunny.Input({
      formats: [new mediabunny.QuickTimeInputFormat()],
      source: new mediabunny.BufferSource(new Uint8Array(await response.arrayBuffer()))
    });
    const track = await input.getPrimaryVideoTrack();
    const sink = new mediabunny.VideoSampleSink(track);
    const decoders = [];
    for (let i = 0; i < 4; i += 1) {
      const sample = await sink.getSample(0);
      sample.close();
      decoders.push(sharedDecoderPoolStats().decoders);
    }
    input.dispose();
    return { decoders, concurrency: Math.min(4, Math.max(1, navigator.hardwareConcurrency ?? 4)) };
  });
  // Four getSample calls, four Mediabunny decoders, one shared turbovc3 decoder.
  expect(Math.max(...result.decoders)).toBe(1);
  // One pool's workers, not one pool per call (Cache-Control: no-store, so each start is a request).
  expect(workersStarted.length).toBe(result.concurrency);
});

test("Canvas2D fallback renders deterministic pixels", async ({ page }) => {
  await page.goto("/");
  const pixels = await page.evaluate(async () => {
    const { DnxCanvasRenderer } = await import("/dist/dnxCanvasRenderer.js");
    const canvas = document.createElement("canvas");
    const renderer = DnxCanvasRenderer.create(canvas);
    if (!renderer) throw new Error("Canvas2D is unavailable.");
    const plane = (label, samples) => ({
      label,
      width: 2,
      height: 1,
      stride: 2,
      bytes: Uint8Array.from(samples)
    });
    renderer.render({
      index: 0,
      timestampUs: 0,
      width: 2,
      height: 1,
      format: "yuv444p8",
      planes: [
        plane("Y", [16, 235]),
        plane("Cb", [128, 128]),
        plane("Cr", [128, 128])
      ]
    });
    const result = Array.from(canvas.getContext("2d").getImageData(0, 0, 2, 1).data);
    renderer.destroy();
    return result;
  });
  expect(pixels).toEqual([0, 0, 0, 255, 255, 255, 255, 255]);
});

async function decodeFixture(page, options, url = fixtureUrl, fourCc = "AVdh") {
  return page.evaluate(async ({ fixtureUrl: inputUrl, decoderOptions, dnxFourCc }) => {
    const [{ Decoder, Frame }, { demuxDnxMxf }] = await Promise.all([
      import("/dist/dnxDecoder.js"),
      import("/dist/dnxMxf.js")
    ]);
    const response = await fetch(inputUrl);
    if (!response.ok) {
      throw new Error(`Fixture request failed with HTTP ${response.status}.`);
    }
    const demuxed = await demuxDnxMxf(new Uint8Array(await response.arrayBuffer()));
    if (!demuxed) {
      throw new Error("Committed MXF fixture did not contain DNx essence.");
    }
    const packet = await demuxed.demuxer.readPacket(demuxed.packets[0]);
    const decoder = await Decoder.create({ dnxFourCc, ...decoderOptions });
    if (decoder instanceof Error) {
      throw decoder;
    }
    try {
      const frame = new Frame();
      const decoded = await decoder.decode(packet, frame);
      if (decoded instanceof Error) {
        throw decoded;
      }
      return {
        mode: decoder.idctMode,
        filled: frame.isFilled,
        width: frame.visibleWidth,
        height: frame.visibleHeight,
        pixelFormat: frame.pixelFormat,
        scanType: frame.scanType,
        crossOriginIsolated: globalThis.crossOriginIsolated,
        canUseSharedMemory: Decoder.canUseSharedMemory()
      };
    } finally {
      await decoder.close();
    }
  }, { fixtureUrl: url, decoderOptions: options, dnxFourCc: fourCc });
}
