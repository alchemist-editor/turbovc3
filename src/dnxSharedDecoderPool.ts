import { Decoder, type DecoderOptions, type DnxNotSupportedError } from "./dnxDecoder.js";

/**
 * Reference-counted {@link Decoder}s shared by every caller that asks for the
 * same configuration. Mediabunny builds a new custom decoder for each
 * `VideoSampleSink.getSample()` call (and each `samples()` session), and a
 * turbovc3 `Decoder` owns a worker pool and its WebAssembly instances, so
 * without sharing every paused seek started and tore down a pool of workers.
 *
 * Leases of the same configuration share one `Decoder` (its worker pool
 * serves their decodes concurrently). When the last lease is released the
 * decoder is closed after `idleCloseMs`, so a run of seeks keeps one pool
 * warm; a lease taken in that window cancels the close.
 */

export interface SharedDecoderOptions extends DecoderOptions {
  /** How long an unused decoder stays open for the next lease, in ms (default 1000; 0 closes at once). */
  idleCloseMs?: number;
}

export interface SharedDecoderLease {
  readonly decoder: Decoder;
  /** Give the decoder back. Idempotent; the decoder closes once no lease holds it. */
  release(): void;
}

/** Live shared decoders, for diagnostics and tests. */
export interface SharedDecoderPoolStats {
  /** Decoders created and not yet closed (including ones still starting). */
  decoders: number;
  /** Leases currently held. */
  leases: number;
}

export const DEFAULT_SHARED_DECODER_IDLE_CLOSE_MS = 1000;

type DecoderCreate = (options: DecoderOptions) => Promise<Decoder | DnxNotSupportedError>;

interface Entry {
  key: string;
  created: Promise<Decoder | DnxNotSupportedError>;
  leases: number;
  closeTimer: ReturnType<typeof setTimeout> | null;
}

const entries = new Map<string, Entry>();
let createDecoder: DecoderCreate = (options) => Decoder.create(options);

/**
 * A lease on the shared decoder for `options`, creating it if needed. Returns
 * the decoder's creation error (and caches nothing) when it cannot be built.
 */
export async function acquireSharedDecoder(
  options: SharedDecoderOptions
): Promise<SharedDecoderLease | DnxNotSupportedError> {
  const key = keyFor(options);
  let entry = entries.get(key);
  if (!entry) {
    const { idleCloseMs: _idle, ...decoderOptions } = options;
    entry = { key, created: createDecoder(decoderOptions), leases: 0, closeTimer: null };
    entries.set(key, entry);
  }
  entry.leases += 1;
  if (entry.closeTimer !== null) {
    clearTimeout(entry.closeTimer);
    entry.closeTimer = null;
  }
  const current = entry;
  const created = await current.created;
  if (created instanceof Error || created.isClosed) {
    current.leases -= 1;
    if (entries.get(key) === current) {
      entries.delete(key);
    }
    if (created instanceof Error) {
      return created;
    }
    // Closed under us (for example by closeSharedDecoders): start over.
    return acquireSharedDecoder(options);
  }
  let released = false;
  return {
    decoder: created,
    release: () => {
      if (released) {
        return;
      }
      released = true;
      releaseEntry(current, options.idleCloseMs ?? DEFAULT_SHARED_DECODER_IDLE_CLOSE_MS);
    }
  };
}

function releaseEntry(entry: Entry, idleCloseMs: number): void {
  entry.leases -= 1;
  if (entry.leases > 0) {
    return;
  }
  if (idleCloseMs <= 0) {
    void closeEntry(entry);
    return;
  }
  entry.closeTimer = setTimeout(() => {
    entry.closeTimer = null;
    if (entry.leases === 0) {
      void closeEntry(entry);
    }
  }, idleCloseMs);
  // Never keep a Node process alive for an idle decoder.
  (entry.closeTimer as { unref?: () => void }).unref?.();
}

async function closeEntry(entry: Entry): Promise<void> {
  if (entries.get(entry.key) === entry) {
    entries.delete(entry.key);
  }
  const created = await entry.created;
  if (!(created instanceof Error)) {
    await created.close();
  }
}

/** Close every shared decoder now, leased or not (page teardown, tests). */
export async function closeSharedDecoders(): Promise<void> {
  const all = [...entries.values()];
  entries.clear();
  await Promise.all(
    all.map(async (entry) => {
      if (entry.closeTimer !== null) {
        clearTimeout(entry.closeTimer);
      }
      const created = await entry.created;
      if (!(created instanceof Error)) {
        await created.close();
      }
    })
  );
}

export function sharedDecoderPoolStats(): SharedDecoderPoolStats {
  let leases = 0;
  for (const entry of entries.values()) {
    leases += entry.leases;
  }
  return { decoders: entries.size, leases };
}

/** Tests only: build decoders with `create` instead of `Decoder.create`. */
export function setSharedDecoderFactoryForTests(create: DecoderCreate | null): void {
  createDecoder = create ?? ((options) => Decoder.create(options));
}

// Configuration identity. Functions (worker factory, error hook) are keyed by
// object identity, so different hooks never share a decoder.
const functionIds = new WeakMap<object, number>();
let nextFunctionId = 1;

function functionId(fn: object | undefined): number {
  if (!fn) {
    return 0;
  }
  let id = functionIds.get(fn);
  if (id === undefined) {
    id = nextFunctionId++;
    functionIds.set(fn, id);
  }
  return id;
}

function href(url: string | URL | undefined): string | null {
  return url === undefined ? null : String(url);
}

function keyFor(options: SharedDecoderOptions): string {
  return JSON.stringify([
    options.dnxFourCc,
    options.useSharedMemory,
    options.concurrency ?? null,
    options.allowedOutputFormats ?? null,
    href(options.wasmUrls?.rowDecoder),
    href(options.wasmUrls?.idctKernel),
    href(options.workerUrls?.sharedRow),
    href(options.workerUrls?.packet),
    functionId(options.workerFactory),
    functionId(options.onWorkerStartError)
  ]);
}
