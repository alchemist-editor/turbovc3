# Changelog

All notable changes to turbovc3 will be documented here.

## [Unreleased]

### Added

- `registerDnxDecoder(options)`: the backend (`useSharedMemory`), the WebAssembly and worker URLs, an
  `onWorkerStartError` hook for worker backends that fail to start, and the shared decoder's idle time. With no options
  it behaves as before.
- Mediabunny DNx decoders reuse turbovc3 decoders and their worker pools (`acquireSharedDecoder`): a released decoder
  waits briefly for the next one of the same configuration, instead of a new pool per `getSample()` call. Decoders in
  use at the same time are never shared. A decoder whose lease saw a decode rejection is closed instead of reused.
- `Decoder.create` options `wasmUrls`, `workerUrls` and `onWorkerStartError`.

- A maintained local browser example covering MXF file open, decode, Canvas2D playback, PCM audio clocking, seeking,
  and backend/cache/I/O diagnostics.
- A release-generated JSON compatibility report containing the packed file inventory, public API hashes, dependency
  contract, distribution tag, and tarball hash, plus versioned browser/runtime/security/fixture documentation.
- A documented `0.x` compatibility policy and intended `1.0` boundary for the root, `/mxf`, and `/node` entry points.
- A checksum-pinned fetch command for FFmpeg's public 12-bit CID 1271 HQX FATE sample and its strict extended oracle.
- Genuine CID 1260 MBAFF decode with per-macroblock frame/field placement, fixed-profile width normalization, sample
  aspect metadata, a checksum-pinned FFmpeg FATE oracle, and Mediabunny coverage.
- Zig/WASM decoder ABI v4 with native MBAFF entropy and adaptive block placement, strictly compared with the scalar,
  Emscripten-IDCT, and FFmpeg outputs.
- Codec-session frame events now retain decoder scan type and fall back to bitstream sample-aspect metadata when the
  container does not declare a display aspect.
- MOV color primaries, transfer, matrix, and range metadata now flow through codec-session frame events, with
  per-field DNx header fallbacks and a tagged Rec. 2020/PQ remux contract.
- Material-package compositions with nested Sequence/SourceClip traversal and source-package/track resolution, while
  preserving alternate edits for caller selection.
- OP1a/OPAtom DNx adapter validation for required material compositions, resolvable DNx SourceClip references, and
  OPAtom's single-essence-track constraint.
- Source-backed MXF and random-access decode for `Blob`, `File`, and custom sources, with abortable indexing and
  packet reads, progress/read telemetry, bounded compressed-packet caching, adjacent prefetch, and coalesced seeks.
- Filled-frame inspection metadata and 12-bit 4:2:0 conversion/WebGPU support.
- Configurable MXF safety limits for untrusted metadata, KLV, track, packet, dimension, and resynchronization work.
- A `@jhodges10/turbovc3/node` entry point backed by `node:worker_threads`, plus an injectable worker factory for
  runtimes that do not expose the browser `Worker` global.
- Validated `Frame.copyLayout()`, `allocationSize()`, and `copyTo()` helpers for packed or explicitly strided planar
  output copies.
- A `deinterlaceDnxFrameLayout()` bob helper with real CID 1241 field parity, field-height, line-placement, and MXF
  timing integration contracts.
- Committed API Extractor reports and deterministic DNx/MXF mutation testing in CI.
- A manifest-driven malformed DNx boundary corpus covering headers, rows, VLC, quantization headers, macroblock
  counts, payload tails, and frame sizes.
- Strict rejection and tests for malformed MXF BER lengths, local sets, primer/index arrays, random index packs, and
  out-of-range random-index offsets.
- Chromium, Firefox, and WebKit integration coverage for synchronous Zig/WASM, packet workers, cross-origin-isolated
  shared-row workers, and missing-asset TypeScript fallback.
- A portable `DnxCanvasRenderer` fallback with deterministic 8/10/12-bit YUV and GBR conversion tests, including
  real Canvas2D pixel reads in all three browser engines.
- `DnxAudioPlayback.createFromMxf()` for BWF-style little-endian 16/24/32-bit PCM packet playback with descriptor
  sample-rate/channel metadata and the existing play, pause, seek, and clock contract.
- A reusable `DnxPlaybackClock`, also exposed as `DnxAudioPlayback.clock`, for synchronizing video presentation to
  the Web Audio timebase.
- SHA-pinned Deno and Bun CI smoke coverage for direct ESM, TypeScript/native fallback selection, injected packet
  workers, decode, and teardown.
- Public renderer lifetime state, WebGPU device-loss notification/failure behavior, and idempotent teardown contracts.
- Committed FFmpeg-oracle coverage for progressive DNxHD CIDs 1250, 1252, 1253, 1258, and 1259.
- Decoder contract coverage proving unknown CIDs cannot be accepted from plausible dimensions or packet sizes.
- Cross-partition MXF validation for linked partitions, footer pointers, KAG alignment, RIP entries, and SID ownership.
- MXF essence tracks are keyed by BodySID plus track number and linked through EssenceContainerData to their source
  package and descriptor, preventing same-number tracks in different source packages from being merged.
- Audio-authoritative video sync decisions, end-of-stream clock state, and opt-in audio underrun recovery.
- Deployment and lifetime guidance for bundlers, CSP, cross-origin isolation, assets, and owned resources.
- Release-tag publication now gates on API reports plus Chromium, Firefox, WebKit, Deno, and Bun runtime tests.
- Interlaced DNxHD CIDs 1241-1244 with two-field weaving, field-order metadata, and FFmpeg/native oracle coverage.
- FFmpeg's experimental field-coded CID 1260 subset.
- Paired DNxHR 4:4:4 YUV/GBR oracles proving adaptive-color-transform selection and planar channel ordering.
- Bit-exact committed FFmpeg oracles for DNxHD CIDs 1235/1237 and DNxHR LB/SQ/HQ CIDs 1274/1273/1272, completing
  required CI coverage for every progressive DNx profile FFmpeg 8 can emit.
- Material/source MXF timecode-track exposure with edit-unit mapping and ordinary/drop-frame SMPTE formatting.
- A bit-exact 24 fps OP1a fixture covering mono 24-bit PCM playback and non-zero material/source timecode alongside
  the existing 30 fps stereo 16-bit contract.
- DNxHD CID 1238 scalar/native dispatch and a required bit-exact FFmpeg oracle, completing the FFmpeg 8 progressive
  reference CID matrix.
- Mediabunny oldest/latest compatibility CI plus an up-front registration check that names missing shim APIs and
  leaves registration retry-safe after a rejected incompatible version.
- Multi-segment MXF index resolution and deterministic packet slicing for fully indexed constant- or
  variable-byte-count clip wrapping.
- `Frame.toVideoFrame()` for standard 8-bit planar WebCodecs output with timing, display-aspect, color, and plane
  layout metadata, plus explicit rejection of non-portable high-bit-depth and GBR layouts.
- A reproducible decode benchmark covering synchronous and native backends, worker concurrency, retained frame
  allocations, close-under-load draining, and cold/warm source-backed MXF seeks.
- Deterministic 8/10/12-bit contracts for odd visible dimensions, coded-frame edges, source/destination padding,
  and every converted output plane stride across 4:2:0, 4:2:2, and 4:4:4 layouts.
- A versioned Zig/WASM capacity contract for packet, row, frame, macroblock-width, and row-count limits, with
  JavaScript-side rejection before native memory access and maximum-envelope tests.
- Native C IDCT ASan/UBSan coverage and Debug-mode Zig safety tests, including oversized-argument arithmetic checks.

### Fixed

- `closeSharedDecoders()` while a lease is out no longer lets that lease's later release park its decoder again; the
  decoder closes on release.
- `Decoder.isUsable` reports whether a decoder can still decode; it is false once closed or once every packet or
  shared-row worker has failed. The shared decoder pool closes such a decoder instead of handing it out from idle
  (counted in `sharedDecoderPoolStats().discarded`), and a Mediabunny decode waiting for capacity on one now reports
  the failure through Mediabunny's error path and gives the decoder back instead of waiting forever.
- A `wasmUrls` override no longer throws when the library runs from a `blob:` or `data:` module: the default
  `../wasm/generated/` URL is built from `import.meta.url` only when there is no override, and an override resolves on
  its own (absolute as given, relative against the page).
- `createNodeDecoder` honours `workerUrls`: an override replaces that kind's Node worker wrapper (it must be a
  `worker_threads` module), and one that fails to start is reported through `onWorkerStartError`. Without an override
  the package's Node wrappers are used, as before.

### Changed

- Random-access frames now preserve pixel aspect ratio and report woven interlaced scan state instead of always
  claiming progressive output.
- Rec. 2020 constant-luminance frames are now rejected by renderer/conversion capability checks rather than being
  silently processed with the non-constant-luminance matrix.
- The root DNx MXF adapter now rejects operational patterns outside its documented OP1a/OPAtom scope explicitly;
  the lower-level `/mxf` demuxer remains available for inspection.
- MXF audio creation now returns `null` only when audio is absent; present but unsupported tracks throw a detailed
  `DnxNotSupportedError` instead of silently appearing as a file with no audio.
- MXF Wave/BWF PCM now distinguishes descriptor quantization depth from stored word size, including deterministic
  20-in-24 and 24-in-32 signed sample conversion with low padding bits ignored.
- Packet-worker decode promises now settle in submission order while retaining concurrent execution.
- Shared-row decoding reuses its packet allocation and retains output allocations across reuse of the same `Frame`.
- Synchronous scalar and Zig frame decoding now retain compatible output allocations when a `Frame` is reused.
- 12-bit planar GBR reconstruction now labels its planes G/B/R consistently with the 10-bit path.
- Zig frame-size arithmetic now validates bounded dimensions before using widened size calculations.
- The standalone C IDCT export ignores null buffers and invalid bit depths before performing pointer access or shifts.
- Decoder teardown rejects new work and drains accepted decode/source operations before terminating workers.
- Truncated packets with valid DNx headers now report `DnxUnexpectedEofError` instead of a capability error.
- Published worker modules use direct-ESM-compatible `.js` specifiers.
- Worker failures preserve decoder error categories and include packet-request or shared-row context.
- Ambiguous MXF clip indexes with gaps, overlaps, conflicting unit sizes, or non-monotonic offsets are rejected.

## [0.1.0] - 2026-07-10

### Added

- Progressive DNxHD and DNxHR decoding with TypeScript, C/WASM IDCT, and Zig/WASM backends.
- Mediabunny decoder registration for `AVdn` and `AVdh` sample entries.
- OP1a and OPAtom MXF demuxing, random packet access, and PCM track metadata.
- Audio playback, random-access decoding, and WebGPU rendering helpers.
- Committed codec-oracle fixtures, package smoke tests, CI, and GitHub Packages release automation.

[Unreleased]: https://github.com/jhodges10/turbovc3/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jhodges10/turbovc3/releases/tag/v0.1.0
