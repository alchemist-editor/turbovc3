# Decode benchmarks

Run the committed decode benchmark after a build:

```sh
npm run bench:decode
```

Use `-- --iterations N --compact` to change the sample count or emit single-line JSON. The report includes:

- synchronous decode FPS and p50/p95 latency;
- Node packet-worker throughput at concurrency 1, 2, and 4;
- Emscripten IDCT and Zig frame-decode results when `wasm/generated` exists;
- close-under-load drain latency;
- source-backed MXF open, cold-seek, and cached warm-seek latency and bytes read;
- process RSS before and after the run.

The harness uses committed, checksummed 1080p DNxHR LB and OPAtom fixtures. It verifies allocation reuse, draining of
accepted work, and zero packet rereads on cached warm seeks before emitting a report. Set `REQUIRE_NATIVE_BENCH=1`
to make missing WASM assets an error.

CI runs a two-iteration structural smoke test. It deliberately does not impose wall-clock thresholds on shared
GitHub runners. Performance comparisons are meaningful only on the same machine, power mode, runtime version, and
iteration count. Capture those fields with the JSON result when investigating a regression; named baseline hardware
and release-blocking budgets remain future qualification work.

## WebAssembly build flags

`scripts/build-dnx-zig-wasm.sh` builds the Zig row decoder with `-O ReleaseFast -fstrip` and
`scripts/build-dnx-wasm.sh` builds the IDCT kernel with `-O3 -msimd128`. Both were chosen from one comparison
(Apple M4 Pro, Chromium, DNxHR HQ 1080p30, medians of three runs on a machine under load, 2026-11-11); every
variant passed `npm run test:native`.

| Row decoder build | Size | Decode fps per layer at 1 / 2 / 4 / 8 concurrent layers | Node frame decode fps |
| --- | --- | --- | --- |
| `-O ReleaseFast -fstrip` | 29 KB | 176.6 / 169.3 / 110.8 / 49.0 | 231 |
| `-O ReleaseSmall` | 20 KB | 141.7 / 139.8 / 88.2 / 45.2 | 205 |

Without `-fstrip`, ReleaseFast keeps its debug sections and the file is 834 KB. The row decoder build is
reproducible: Zig 0.17.0 on macOS and on Linux produce the same bytes. The IDCT kernel, which runs only when the
row decoder is unavailable, measured 41.2 fps with `-msimd128` and 39.2 without in Node.
