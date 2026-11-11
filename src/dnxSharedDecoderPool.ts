import { Decoder, type DecoderOptions, type DnxNotSupportedError } from "./dnxDecoder.js";

/**
 * A pool of turbovc3 {@link Decoder}s reused across callers that ask for the
 * same configuration. Mediabunny builds a new custom decoder for each
 * `VideoSampleSink.getSample()` call (and each `samples()` session), and a
 * turbovc3 `Decoder` owns a worker pool and its WebAssembly instances, so
 * without reuse every paused seek started and tore down a pool of workers.
 *
 * Each lease holds a decoder of its own: concurrent players never share one,
 * because a shared-memory row decoder decodes one frame at a time and eight
 * layers through one of them fall far below real time. A released decoder
 * waits idle for the next lease of the same configuration and closes after
 * `idleCloseMs`; at most `maxIdleDecoders` wait per configuration. A lease
 * marked failed (a decode rejected, a worker died) closes its decoder on
 * release instead of parking it, so no later caller inherits a broken one.
 */

export interface SharedDecoderOptions extends DecoderOptions {
  /** How long a released decoder waits for the next lease, in ms (default 1000; 0 closes at once). */
  idleCloseMs?: number;
  /** Released decoders kept waiting per configuration (default 4); more are closed at once. */
  maxIdleDecoders?: number;
}

export interface SharedDecoderLease {
  readonly decoder: Decoder;
  /**
   * Something went wrong while this lease held the decoder (a decode
   * rejected, a worker crashed or failed to start): release closes it rather
   * than parking it for the next lease.
   */
  markFailed(): void;
  /** Give the decoder back. Idempotent; it waits for the next lease or closes. */
  release(): void;
}

/** Live pooled decoders, for diagnostics and tests. */
export interface SharedDecoderPoolStats {
  /** Decoders open: leased, idle, or still starting. */
  decoders: number;
  /** Leases currently held. */
  leases: number;
  /** Released decoders waiting for the next lease. */
  idle: number;
  /** Decoders closed on release because their lease was marked failed, since load. */
  discarded: number;
}

export const DEFAULT_SHARED_DECODER_IDLE_CLOSE_MS = 1000;
export const DEFAULT_SHARED_DECODER_MAX_IDLE = 4;

type DecoderCreate = (options: DecoderOptions) => Promise<Decoder | DnxNotSupportedError>;

interface IdleDecoder {
  decoder: Decoder;
  timer: ReturnType<typeof setTimeout> | null;
}

interface Bucket {
  idle: IdleDecoder[];
  leased: number;
  starting: number;
}

const buckets = new Map<string, Bucket>();
let discarded = 0;
let createDecoder: DecoderCreate = (options) => Decoder.create(options);

/**
 * A lease on a decoder for `options`: an idle one of the same configuration if
 * there is one, otherwise a new one. Returns the creation error when a decoder
 * cannot be built.
 */
export async function acquireSharedDecoder(
  options: SharedDecoderOptions
): Promise<SharedDecoderLease | DnxNotSupportedError> {
  const key = keyFor(options);
  const bucket = bucketFor(key);
  let decoder: Decoder | null = null;
  while (bucket.idle.length > 0 && !decoder) {
    const idle = bucket.idle.pop() as IdleDecoder;
    if (idle.timer !== null) {
      clearTimeout(idle.timer);
    }
    if (!idle.decoder.isClosed) {
      decoder = idle.decoder;
    }
  }
  if (!decoder) {
    const { idleCloseMs: _idle, maxIdleDecoders: _max, ...decoderOptions } = options;
    bucket.starting += 1;
    let created: Decoder | DnxNotSupportedError;
    try {
      created = await createDecoder(decoderOptions);
    } finally {
      bucket.starting -= 1;
    }
    if (created instanceof Error) {
      dropIfEmpty(key, bucket);
      return created;
    }
    decoder = created;
  }
  bucket.leased += 1;
  const leased = decoder;
  let released = false;
  let failed = false;
  return {
    decoder: leased,
    markFailed: () => {
      failed = true;
    },
    release: () => {
      if (released) {
        return;
      }
      released = true;
      bucket.leased -= 1;
      if (failed) {
        discarded += 1;
        void leased.close();
        dropIfEmpty(key, bucket);
        return;
      }
      park(key, bucket, leased, options);
    }
  };
}

function park(key: string, bucket: Bucket, decoder: Decoder, options: SharedDecoderOptions): void {
  const idleCloseMs = options.idleCloseMs ?? DEFAULT_SHARED_DECODER_IDLE_CLOSE_MS;
  const maxIdle = options.maxIdleDecoders ?? DEFAULT_SHARED_DECODER_MAX_IDLE;
  if (decoder.isClosed || idleCloseMs <= 0 || bucket.idle.length >= maxIdle || buckets.get(key) !== bucket) {
    void decoder.close();
    dropIfEmpty(key, bucket);
    return;
  }
  const idle: IdleDecoder = { decoder, timer: null };
  idle.timer = setTimeout(() => {
    idle.timer = null;
    const index = bucket.idle.indexOf(idle);
    if (index >= 0) {
      bucket.idle.splice(index, 1);
      void decoder.close();
      dropIfEmpty(key, bucket);
    }
  }, idleCloseMs);
  // Never keep a Node process alive for an idle decoder.
  (idle.timer as { unref?: () => void }).unref?.();
  bucket.idle.push(idle);
}

function bucketFor(key: string): Bucket {
  let bucket = buckets.get(key);
  if (!bucket) {
    bucket = { idle: [], leased: 0, starting: 0 };
    buckets.set(key, bucket);
  }
  return bucket;
}

function dropIfEmpty(key: string, bucket: Bucket): void {
  if (bucket.idle.length === 0 && bucket.leased === 0 && bucket.starting === 0 && buckets.get(key) === bucket) {
    buckets.delete(key);
  }
}

/** Close every idle decoder now (page teardown, tests). Leased decoders close when released. */
export async function closeSharedDecoders(): Promise<void> {
  const closing: Promise<void>[] = [];
  for (const [key, bucket] of [...buckets]) {
    for (const idle of bucket.idle.splice(0)) {
      if (idle.timer !== null) {
        clearTimeout(idle.timer);
      }
      closing.push(idle.decoder.close());
    }
    dropIfEmpty(key, bucket);
  }
  await Promise.all(closing);
}

export function sharedDecoderPoolStats(): SharedDecoderPoolStats {
  let leases = 0;
  let idle = 0;
  let starting = 0;
  for (const bucket of buckets.values()) {
    leases += bucket.leased;
    idle += bucket.idle.length;
    starting += bucket.starting;
  }
  return { decoders: leases + idle + starting, leases, idle, discarded };
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
