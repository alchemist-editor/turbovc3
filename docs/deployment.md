# Deployment and lifetime guide

## Object ownership

- `Decoder` owns any workers and native decoder instances it creates. Call `await decoder.close()` after the last
  accepted decode; closing rejects new work and drains work already accepted.
- A `Frame` owns its reusable decoded-plane allocation. A decode locks it until settlement. Do not clear, copy, or
  submit the same frame concurrently. `clear()` releases retained output, while reusing a filled frame lets compatible
  backends reuse its allocation.
- Encoded packet buffers remain caller-owned unless `transferPacket: true` is passed to `decode()`. Transfer mode
  detaches the caller's `ArrayBuffer` when a worker backend is selected.
- `DnxRandomAccessDecoder` owns its underlying `Decoder`, packet cache, prefetch work, and source handle abstraction.
  Call `close()`; caller-provided `Blob`, `File`, and `MxfSource` objects otherwise remain caller-owned.
- Renderers retain GPU or canvas resources but never take ownership of a `Frame`. Call `destroy()` when the target is
  removed. A frame may be reused after `render()` returns.
- `DnxAudioPlayback` owns only an `AudioContext` it created itself. A caller-provided context and destination remain
  caller-owned. Call `close()` to stop sources and dispose demux/decode state.

`AsyncDisposable` implementations can also be used with `await using` where the runtime supports explicit resource
management.

## Worker and WASM assets

The package resolves module workers relative to its installed JavaScript files and resolves both WASM binaries from
`wasm/generated/` with `import.meta.url`. Preserve the published directory layout when copying files to a CDN. If a
host rewrites module URLs, verify these four package resources in the deployed output:

- `dist/workers/dnxPacketDecode.worker.js`
- `dist/workers/dnxSharedRowDecode.worker.js`
- `wasm/generated/dnx_idct_kernel.wasm`
- `wasm/generated/dnx_row_decoder.wasm`

Missing native assets fall back to TypeScript. Missing worker assets fall back to a synchronous backend. Treat those
fallbacks as resilience, not as a deployment check; exercise the backend diagnostics in a production-like build.

When the bundler emits these files elsewhere, pass their URLs instead of rewriting the package: `Decoder.create` takes
`wasmUrls` (`rowDecoder`, `idctKernel`) and `workerUrls` (`sharedRow`, `packet`), and `registerDnxDecoder` takes the
same options for Mediabunny decoding. Relative URLs resolve against the page; workers receive absolute URLs. Pass
`onWorkerStartError` to learn why a worker backend did not start; the decoder still falls back.

```ts
registerDnxDecoder({
  useSharedMemory: false, // packet workers; default: row workers when cross-origin isolated
  wasmUrls: { rowDecoder: rowWasmUrl, idctKernel: idctWasmUrl },
  workerUrls: { sharedRow: sharedRowWorkerUrl, packet: packetWorkerUrl },
  onWorkerStartError: ({ backend, error }) => console.warn(`DNx ${backend} workers did not start`, error)
});
```

## Reused decoders

Mediabunny builds a new custom decoder for each `VideoSampleSink.getSample()` call and each `samples()` session.
`registerDnxDecoder` hands each Mediabunny DNx decoder a turbovc3 `Decoder` from a pool: a released decoder waits
`idleCloseMs` (default 1000 ms) for the next one of the same configuration, so a run of seeks reuses one worker pool,
then closes and terminates its workers. At most `maxIdleDecoders` (default 4) wait per configuration. Decoders in use
at the same time are never shared: a shared-memory row decoder decodes one frame at a time, so several players on one
would fall below real time. `acquireSharedDecoder` exposes the same pool to callers that manage decoders themselves;
`sharedDecoderPoolStats` and `closeSharedDecoders` support diagnostics and teardown.

## Vite

Vite's native `new URL(..., import.meta.url)` and module-worker handling work without a plugin. Import the package
from browser code and allow the four package assets above to be emitted. Do not mark `mediabunny` as a separate CDN
external unless the application guarantees the same module instance is used by both packages.

## Webpack 5

Webpack 5 understands module workers and `new URL(..., import.meta.url)`. Ensure `.wasm` resources are emitted as
files rather than imported as synchronous WebAssembly modules:

```js
export default {
  module: {
    rules: [{ test: /dnx_(?:idct_kernel|row_decoder)\.wasm$/, type: "asset/resource" }]
  }
};
```

Do not transpile `import.meta.url` away before Webpack processes dependencies.

## Next.js

Decoder, renderer, worker, and Web Audio APIs are browser-only. Create them in a Client Component or a dynamically
imported module after hydration; do not instantiate them during server rendering. The `/node` entry point is for
Node packet decoding and is not a replacement for browser rendering.

## CSP and cross-origin isolation

The default workers are same-origin module workers. A restrictive policy generally needs `worker-src 'self'` and a
`script-src` policy that permits WebAssembly compilation (commonly `'wasm-unsafe-eval'` in browsers that support it).
Applications with stricter URL rules can provide `DecoderOptions.workerFactory` and host reviewed worker entry files
at approved URLs.

Shared-row decoding additionally requires a cross-origin-isolated page. Serve the document with:

```http
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Every cross-origin subresource must then opt in through CORS or an appropriate `Cross-Origin-Resource-Policy` header.
Ordinary packet workers, synchronous WASM, and TypeScript fallback do not require cross-origin isolation.

