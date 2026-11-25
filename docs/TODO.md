# turbovc3 Roadmap

Last updated: 2026-07-17

This roadmap starts from the `0.1.0` implementation. turbovc3 already decodes progressive DNxHD/DNxHR through
TypeScript and Zig/WASM backends, integrates with Mediabunny for MOV/QuickTime, demuxes DNx from OP1a and OPAtom
MXF, renders planar output with WebGPU, and exposes audio and random-access helpers.

Priorities are ordered by user impact and by how much they reduce risk for downstream applications. Items marked
P0 should land before broad production use; P1 expands the supported media surface; P2 improves adoption and
maintainability.

## TurboRes Parity Progress (Decode Only)

Completed in the current `0.2` work:

- [x] Settle concurrent packet-worker decodes in submission order and drain accepted work during `close()`.
- [x] Cover frame locking, reuse, explicit packet transfer, close-during-decode, and multiple backend fallback paths.
- [x] Add `Frame.isFilled()`, `Frame.toFilled()`, pixel aspect ratio, numeric color metadata, range, scan type, and
  WebCodecs-style color string getters.
- [x] Support the planar 8/10/12-bit 4:2:0, 4:2:2, and 4:4:4 conversion/render matrix where a conversion from the
  decoded DNx source format is defined.

Remaining parity work is intentionally not marked complete without codec fixtures and oracle evidence:

- [x] Reuse the serialized shared-row packet buffer and retain a frame-sized shared buffer for each reusable `Frame`,
  with allocation-identity contract coverage.
- [ ] Replace per-worker WASM instances with a measured shared-runtime design, then prove the throughput improvement.
- [x] Cover worker/backend startup in Chromium, Firefox, WebKit, Node, Deno, and Bun. Node ships through
  `@jhodges10/turbovc3/node`; Deno and Bun exercise direct ESM plus injected packet workers.
- [x] Implement two-field interlaced DNxHD decode and field-order metadata for CIDs 1241-1244 across scalar, Zig/WASM,
  packet-worker, shared-memory fallback, and rendering-compatible planar output.
- [x] Decode FFmpeg's experimental field-coded CID 1260 subset.
- [x] Implement adaptive-macroblock MBAFF entropy and field/frame block placement with a checksum-pinned FFmpeg FATE
  oracle and Mediabunny contract.
- [ ] Add alpha/low-latency-alpha decode, rendering, and lifetime contracts.
- [ ] Expand verified CID and 12-bit 4:4:4 coverage, malformed/fuzz coverage, and bit-exact oracle comparisons.
- [ ] Add benchmark gates for concurrency scaling, buffer reuse, sustained playback, and teardown under load.
- [x] Add a reproducible local/CI-smoke benchmark report for synchronous/native decode, worker concurrency, retained
  frame allocations, close-under-load draining, and cold/warm source-backed seeks without runner-specific thresholds.

## P0: Source-Backed Decode and Fast Seeking

- [x] Let `demuxDnxMxf()` and `DnxRandomAccessDecoder.create()` accept `Blob`, `File`, and `MxfSource`, not only a
  whole-file `Uint8Array`.
- [x] Keep MXF packet locators in the index and read only the requested compressed frame during random access.
- [x] Avoid eagerly validating and retaining every DNx packet when opening long or UHD clips.
- [x] Add cancellation with `AbortSignal` for open, index, decode, seek, and prefetch operations.
- [x] Coalesce rapid seek requests so only one decode and the newest requested target remain in flight.
- [x] Add a small, bounded compressed-packet cache and optional adjacent-frame prefetch without retaining decoded
  clips in memory.
- [x] Expose indexing progress and byte-read counters for large local and remote sources.

Acceptance criteria:

- Opening the 2,285-frame HD and UHD MXF fixtures does not read or copy the complete file.
- A random seek reads the target packet plus a documented, bounded amount of metadata and prefetch data.
- Repeated scrub cancellation does not leak workers, WASM memory, frames, or file handles.
- Benchmarks report cold and warm seek p50/p95 latency separately.

## P0: Browser and Performance Gates

- [x] Add Playwright integration tests for current Chromium, Firefox, and WebKit browser engines.
- [x] Exercise cross-origin-isolated shared-row workers, ordinary packet workers, synchronous WASM, and TypeScript
  fallback paths in CI.
- [x] Test the Canvas2D non-WebGPU rendering fallback with deterministic unit and real-browser pixel comparisons.
- [ ] Test real WebGPU output with browser pixel comparisons, not only mocked GPU contracts.
- [ ] Add sustained playback tests for 1080p60 and UHD60 fixtures, including play, pause, backward seek, rapid scrub,
  end-of-stream, and decoder teardown.
- [ ] Establish benchmark hardware and publish decode FPS, render FPS, dropped frames, memory high-water mark,
  startup latency, and seek p50/p95.
- [ ] Add regression budgets for the Zig/WASM frame path, worker scheduling overhead, and YUV upload/render time.
- [x] Replace fixed native capacity limits with dimensions derived from validated frame headers where practical, and
  test maximum supported rows, packets, macroblocks, and frame allocations (8K DCI, issue #24: the packet and frame
  buffers grow on demand; `tests/dnx-8k-test.mjs` decodes 8192×4320 4:4:4 on both WASM paths).
- [x] Export and validate the complete versioned Zig capacity envelope before native memory access, including packet,
  row, frame, macroblock-width, and row-count boundary contracts for the declared 4096×2160 scope.
- [ ] Profile packet copies and plane uploads; pool reusable buffers and GPU resources where measurements justify it.

Initial performance target:

- Sustain 1920x1080 progressive DNxHR playback at 60 FPS on documented baseline hardware with zero steady-state
  drops.
- Measure UHD60 honestly before making it a release guarantee; track decode, upload, and presentation bottlenecks
  independently.

## P0: Correctness and Input Hardening

- [x] Add a committed, manifest-driven malformed DNx corpus for header, row-offset/span, VLC, quantization-header,
  macroblock-count, payload-tail, and frame-size boundaries.
- [x] Add malformed MXF coverage for BER lengths, KLV resynchronization, primer entries, local sets, short partition
  packs, index arrays, random index packs, and out-of-range random-index offsets.
- [x] Validate partition-link/footer chains, KAG alignment, random-index membership/BodySID, and index-table
  IndexSID/BodySID ownership across committed multi-partition fixtures.
- [x] Add deterministic mutation targets for DNx frame parsing/reconstruction and MXF KLV/local-set parsing to PR
  CI, with a larger local campaign available through `npm run test:fuzz`.
- [x] Enforce configurable MXF limits for metadata size, KLV count, track count, packet count, descriptor dimensions,
  and resynchronization work. Native frame allocation limits remain tracked under the performance gates.
- [x] Verify worker and main-thread errors preserve stable typed error categories and useful packet/row context.
- [ ] Expand oracle comparisons to cover frame edges, coded padding, odd visible dimensions, and all output plane
  strides.
- [x] Cover odd visible dimensions, coded-frame edges, padded input/output strides, and the full 8/10/12-bit
  4:2:0/4:2:2/4:4:4 conversion layout matrix with deterministic synthetic contracts; real odd-dimension codec
  oracles remain dependent on a conforming source.
- [x] Run the C IDCT kernel under native ASan/UBSan and the Zig row/frame decoder under Debug safety checks in native
  CI and release verification; standalone Emscripten WASM remains covered by parity tests rather than a sanitizer
  runtime that it does not embed.

## P1: Audio and A/V Playback

- [x] Extend `DnxAudioPlayback` beyond MOV/MP4 so it can consume PCM packets and metadata from `MxfDemuxer`.
- [x] Support BWF-style little-endian 16/24/32-bit integer PCM with descriptor sample rates, channel counts, packet
  edit rates, seek offsets, and explicit unsupported-track rejection.
- [x] Distinguish MXF PCM valid sample depth from its stored 16/24/32-bit word size and mask left-aligned padding.
- [ ] Add big-endian/AES3 PCM when redistributable fixtures and authoritative essence mappings are available.
- [x] Introduce a reusable playback clock, exposed by `DnxAudioPlayback`, that lets video presentation follow the
  same Web Audio timebase across start, pause, and seek.
- [x] Add explicit pause/resume, seek, end-of-stream, and opt-in underrun recovery behavior.
- [x] Make the Web Audio context authoritative and expose `videoDecision()` so callers drop late frames, hold early
  frames, and present frames within a configurable tolerance.
- [x] Add bit-exact OP1a fixtures spanning 24/30 fps, mono/stereo, 16/24-bit PCM, and non-zero material/source
  timecode.
- [ ] Add real OP1a PCM fixtures at sample rates other than 48 kHz; FFmpeg 8's MXF muxer rejects them, so this needs
  another redistributable authoring source.
- [x] Keep unsupported compressed or otherwise incompatible MXF audio explicit with a `DnxNotSupportedError` that
  reports track IDs, essence ULs, bit depths, sample rates, and channel counts.

## P1: Codec Coverage

- [x] Implement interlaced DNxHD CIDs 1241-1244 with top/bottom field weaving and FFmpeg-oracle coverage.
- [x] Cover FFmpeg's experimental CID 1260 field-coded output with committed oracles.
- [x] Implement genuine CID 1260 MBAFF packets whose headers carry per-macroblock field-mode bits; normalize the
  encoded 1920-wide header to the CID's 1440-pixel output and expose its 4:3 sample aspect ratio.
- [x] Add field-order, field-height, line-placement, timing, and bob-deinterlacing integration tests.
- [ ] Implement alpha and low-latency alpha plane decode with explicit output formats and renderer support.
- [ ] Add a committed or reproducibly fetched 12-bit DNxHR 4:4:4 fixture and strict FFmpeg-oracle coverage. FFmpeg
  8 accepts 12-bit input but its DNx encoder emits 10-bit HQX/444, so this requires a genuine external sample.
- [x] Make FFmpeg's public 12-bit CID 1271 HQX FATE sample reproducibly fetchable with byte-length/SHA-256 pinning
  and retain its strict TypeScript, native, and Mediabunny extended-oracle path; it is 4:2:2, not the 4:4:4 gap above.
- [x] Expand committed oracle coverage to progressive DNxHD CIDs 1250, 1252, 1253, 1258, and 1259.
- [x] Commit bit-exact FFmpeg oracles for progressive DNxHD CIDs 1235/1237/1238 and DNxHR LB/SQ/HQ CIDs
  1274/1273/1272,
  so every progressive profile FFmpeg 8 can emit is required in CI.
- [ ] Add CID 1256 DNxHD 4:4:4 from an external source; FFmpeg 8 rejects that encoding combination.
- [x] Verify adaptive color transform selection and channel ordering against paired YUV/GBR FFmpeg oracles across
  scalar and Zig/WASM decode, with both renderer interpretations covered by pixel contracts.
- [ ] Verify Mediabunny's long-term representation of DNx 4:4:4 GBR versus YUV once it exposes first-class DNx
  codec metadata rather than the guarded extension shim.
- [x] Reject unknown CIDs before decode even when their header dimensions, packet size, and pixel format otherwise
  resemble a supported VC-3 frame.
- [x] Document the complete FFmpeg 8 reference CID matrix and distinguish implemented-but-external-oracle profiles
  from explicitly rejected alpha, low-latency-alpha, and unknown-CID inputs.

## P1: Color and Frame Interoperability

- [x] Preserve MOV color primaries, transfer, matrix, and range metadata through codec-session frame events, with DNx
  header metadata as the per-field fallback; chromaticity coordinates are not exposed by the current container API.
- [ ] Add independent shader/oracle tests for Rec. 709, Rec. 2020 non-constant luminance, Rec. 2020 constant
  luminance, GBR, 10-bit, and 12-bit paths.
- [ ] Define tone-mapping behavior for HDR-tagged content instead of relying on the destination surface implicitly.
- [x] Add frame-copy helpers with explicit strides, plane sizes, destination sizing, and overlap/range validation.
- [x] Add a `VideoFrame` bridge for portable 8-bit planar formats while preserving the reusable planar `Frame` API;
  keep high-bit-depth and GBR output on explicit `copyTo()` layouts until WebCodecs standardizes those formats.
- [x] Make GPU texture reuse, canvas resizing, device loss callbacks/state, and idempotent renderer teardown part of
  the public renderer contract.

## P1: General MXF Demuxing

- [ ] Test multiple body partitions, multiple index table segments, sparse indexes, zero `IndexDuration`, and footer
  metadata updates from real-world authoring tools.
- [x] Support variable-byte-count clip wrapping when index entry offsets are present and reject ambiguous layouts
  deterministically.
- [x] Resolve essence tracks by BodySID and source-package EssenceContainerData links so duplicate track numbers and
  descriptor track IDs in separate source packages remain distinct.
- [x] Preserve every material package as a composition, flatten nested Sequence/SourceClip chains, and resolve clips
  to BodySID-aware source tracks without guessing which alternate composition is primary.
- [x] Expose material/source timecode tracks and a stable edit-unit mapping API with ordinary and drop-frame
  formatting, origins, duration, edit rates, and 24-hour wrapping.
- [x] Validate KAG alignment, partition-link consistency, and BodySID/IndexSID associations.
- [x] Validate the narrow adapter's operational structure: OPAtom has exactly one essence track, OP1a/OPAtom expose
  a material composition, and the selected DNx source track is reached through a resolvable SourceClip.
- [ ] Add fixtures from FFmpeg, Avid, Adobe, Resolve, and other generators where licensing permits redistribution.
- [x] Keep the root DNx adapter scoped to OP1a and OPAtom with explicit rejection for other labels; do not imply
  general OP1b or growing-file support until packet timelines are tested.
- [ ] Add an incremental/growing-file mode only after source-size changes, incomplete partitions, and index refreshes
  have explicit semantics.

## P1: Mediabunny Integration

- [ ] Track first-class DNx codec recognition in Mediabunny and remove the guarded track shim when the upstream API
  makes it unnecessary.
- [ ] Propose or contribute upstream `AVdn`/`AVdh` recognition and a supported DNx extension registration path.
- [x] Add compatibility tests against the oldest supported and newest released Mediabunny versions.
- [x] Detect incompatible Mediabunny API changes with a clear setup error instead of failing during first decode.
- [ ] Revisit an official `@mediabunny/dnx` package only when ownership, release cadence, and compatibility contracts
  are agreed upstream.

## P2: API Stability and Developer Experience

- [x] Define the intended `1.0` root, `/mxf`, and `/node` boundaries; enforce them with the package export map and API
  reports while keeping worker protocols, reconstruction tables, and native implementation details private.
- [x] Document ownership and lifetime rules for `Decoder`, `Frame`, packet buffers, workers, renderers, and audio
  contexts.
- [x] Add API Extractor reports for the root and `/mxf` entry points to CI so accidental exports and breaking type
  changes are visible.
- [x] Publish recipes for Vite, Next.js, Webpack, CSP-constrained deployments, worker URLs, WASM asset hosting, and
  COOP/COEP headers.
- [x] Add a maintained browser example for local MXF open, decode, Canvas2D playback, PCM audio-clock operation,
  seeking, cache/I/O telemetry, and backend diagnostics without moving codec behavior into the example.
- [x] Defer npmjs publication; retain the permanent scoped identity so a separate npmjs registry workflow can be
  added later without changing consumer imports.
- [x] Document browser/runtime support, Mediabunny compatibility, security limits, and fixture provenance for the
  release line.
- [x] Route semantic prereleases to `next` and attach a generated packed-file/API-hash/tarball compatibility report
  to every GitHub Packages release workflow run.

## Suggested Milestones

1. **0.2 - Lazy random access:** source-backed MXF/DNx indexing, cancellation, seek benchmarks, and bounded caching.
2. **0.3 - Playback confidence:** real-browser matrix, sustained playback gates, MXF PCM playback, and A/V clocking.
3. **0.4 - Format coverage:** dedicated 12-bit 4:4:4 coverage, wider CID fixtures, and color pipeline hardening.
4. **0.5 - Interlaced and alpha:** interlaced/MBAFF decode, alpha planes, and their renderer/Mediabunny contracts.
5. **1.0 - Stable package:** documented compatibility matrix, hardened malformed-input handling, stable API, and
   published performance guarantees on named hardware.

## Explicit Non-Goals for Now

- DNx encoding or transcoding.
- MXF muxing or metadata editing.
- A general-purpose media player UI inside the package.
- Claiming support for every MXF operational pattern or essence codec.
- Replacing Mediabunny for MOV/QuickTime parsing.

These can be reconsidered after the decoder, demuxer, playback clocks, and public API have stable production usage.
