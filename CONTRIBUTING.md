# Contributing to turbovc3

Thanks for helping improve browser-based DNx support. This project is experimental, so focused bug reports,
reproducible media cases, compatibility fixes, tests, and documentation are especially useful.

## Before opening an issue

- Search existing issues first.
- Use the bug or feature issue form and include browser, bundler, package version, container, DNx profile, dimensions,
  bit depth, and whether the page is cross-origin isolated.
- Do not attach confidential media. Prefer a minimal synthetic reproduction or describe how maintainers can generate
  one with FFmpeg.
- Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Development setup

The standard workflow requires Node.js 22 or newer:

```sh
npm ci
npm run check
npm run build
npm run api:report
npm test
npm run test:package
```

Run a larger deterministic malformed-input campaign before parser or reconstruction changes:

```sh
npm run test:fuzz
```

The committed fixtures are one-frame synthetic patterns. Their checksums and expected formats live in
`tests/fixtures/manifest.json`; regenerate them only with FFmpeg 8.x:

```sh
scripts/generate-ci-fixtures.sh
npm run fixtures:verify
```

Native backend changes require Zig 0.17.0 and Emscripten 6.0.2:

```sh
npm run build:wasm
npm run test:native
npm run test:native:sanitizers
REQUIRE_WASM_ASSETS=1 npm run test:package
npx playwright install chromium firefox webkit
npm run test:browser
npm run test:runtimes # when Deno and Bun are installed
```

Generated WASM is deliberately not committed. GitHub Actions builds it for native verification and release packages.

## Extended codec testing

The normal test suite requires the committed corpus. Additional ignored fixtures can be generated from a source video:

```sh
scripts/generate-dnx-samples.sh path/to/source.mov samples 1
npm run test:extended
```

The 12-bit HQX case uses FFmpeg's external FATE fixture. Follow the download command in `research/README.md`; do not
commit external or personally owned media.

## Pull requests

- Keep changes focused and explain observable behavior.
- Add or update tests for codec, demuxer, packaging, or fallback behavior.
- Call out changes to the exported API, browser requirements, generated assets, or fixture provenance.
- Run the standard workflow before requesting review; run native checks when touching native code, reconstruction,
  tables, workers, or release packaging.
- Do not commit `dist/`, `wasm/generated/`, arbitrary media under `samples/`, or toolchain caches.

By contributing, you agree that your contribution is licensed under MPL-2.0.
