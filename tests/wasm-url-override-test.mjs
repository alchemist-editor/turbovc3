#!/usr/bin/env node
// WebAssembly URL overrides from a module without a URL base. A blob: or
// data: module's import.meta.url cannot resolve the default
// ../wasm/generated/ path; an override must not need it. The library is
// bundled and imported from a data: URL, and the modules are served over HTTP
// (Node's fetch does not read file: URLs).
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const requests = [];
const server = createServer(async (request, response) => {
  requests.push(request.url);
  const name = path.basename(request.url ?? "");
  try {
    const bytes = await readFile(path.join(repoRoot, "wasm/generated", name));
    response.writeHead(200, { "content-type": "application/wasm" });
    response.end(bytes);
  } catch {
    response.writeHead(404);
    response.end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;

try {
  const module = await loadModuleFromDataUrl();

  // Absolute overrides load from where they point.
  const rowDecoder = await module.createDnxWasmRowDecoder(undefined, `${origin}/assets/dnx_row_decoder.wasm`);
  assert.equal(rowDecoder.mode, "zig-wasm-frame");
  rowDecoder.destroy();
  const idctKernel = await module.createDnxWasmIdctKernel(undefined, new URL(`${origin}/assets/dnx_idct_kernel.wasm`));
  assert.equal(idctKernel.mode, "wasm-idct");
  idctKernel.destroy();
  assert.deepEqual(requests.splice(0), ["/assets/dnx_row_decoder.wasm", "/assets/dnx_idct_kernel.wasm"]);

  // Through Decoder.create on the calling thread: the native backends load
  // from the overrides instead of quietly falling back to TypeScript.
  const decoder = await module.Decoder.create({
    dnxFourCc: "AVdh",
    useSharedMemory: false,
    concurrency: 0,
    wasmUrls: {
      rowDecoder: `${origin}/decoder/dnx_row_decoder.wasm`,
      idctKernel: `${origin}/decoder/dnx_idct_kernel.wasm`
    }
  });
  assert.ok(!(decoder instanceof Error));
  assert.equal(decoder.idctMode, "zig-wasm-frame");
  assert.deepEqual(requests.splice(0).sort(), ["/decoder/dnx_idct_kernel.wasm", "/decoder/dnx_row_decoder.wasm"]);
  await decoder.close();

  // A relative override resolves against the page, not the module.
  globalThis.location = { href: `${origin}/app/index.html` };
  try {
    const relative = await module.createDnxWasmRowDecoder(undefined, "../relative/dnx_row_decoder.wasm");
    relative.destroy();
    assert.deepEqual(requests.splice(0), ["/relative/dnx_row_decoder.wasm"]);
  } finally {
    delete globalThis.location;
  }

  console.log("WebAssembly URL overrides load from a data: module.");
} finally {
  server.close();
}

async function loadModuleFromDataUrl() {
  const source = (file) => JSON.stringify(path.join(repoRoot, "src", file));
  const result = await build({
    stdin: {
      contents: `
        export { Decoder } from ${source("dnxDecoder.ts")};
        export { createDnxWasmRowDecoder } from ${source("dnxZigRowDecoder.ts")};
        export { createDnxWasmIdctKernel } from ${source("dnxIdctKernel.ts")};
      `,
      resolveDir: repoRoot,
      sourcefile: "wasm-url-override-test-entry.ts"
    },
    bundle: true,
    format: "esm",
    platform: "node",
    target: "node22",
    write: false
  });
  const module = await import(`data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString("base64")}`);
  return module;
}
