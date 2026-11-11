import type { DnxFrameHeader } from "./dnxFrame.js";
import {
  createDnxFrameLayout,
  dnxFrameByteLength,
  parseDnxRowSpans,
  type DnxFrameLayout
} from "./dnxReconstruction.js";
import type {
  DnxSharedRowWorkerRequest,
  DnxSharedRowWorkerResponse
} from "./dnxSharedRowWorkerProtocol.js";
import type { DnxWorker, DnxWorkerFactory } from "./dnxWorker.js";

interface WorkerSlot {
  worker: DnxWorker;
  failed: boolean;
}

interface PendingRow {
  row: number;
  resolve(): void;
  reject(error: Error): void;
}

interface DnxSharedRowDecodeResult {
  layout: DnxFrameLayout;
  frameBuffer: SharedArrayBuffer;
}

export class DnxSharedRowDecoder {
  readonly mode = "shared-row-workers/zig-wasm-row";
  readonly concurrency: number;
  private readonly pendingRows = new Map<number, PendingRow>();
  private nextRequestId = 1;
  private queueSize = 0;
  private closed = false;
  private packetBuffer: SharedArrayBuffer | null = null;
  private closePromise: Promise<void> | null = null;
  private tail: Promise<void> = Promise.resolve();
  private dequeuedResolve: (() => void) | null = null;
  private dequeuedPromise = new Promise<void>((resolve) => {
    this.dequeuedResolve = resolve;
  });

  private constructor(
    private readonly slots: WorkerSlot[],
    private readonly rowDecoderWasmUrl?: string
  ) {
    this.concurrency = slots.length;
  }

  /**
   * `options.workerUrl` overrides the worker module (default
   * `./workers/dnxSharedRowDecode.worker.js` beside this file);
   * `options.rowDecoderWasmUrl` is the absolute URL the workers load the row
   * decoder from (their default when absent).
   */
  static async create(
    concurrency: number,
    workerFactory: DnxWorkerFactory,
    options: { workerUrl?: URL; rowDecoderWasmUrl?: string } = {}
  ): Promise<DnxSharedRowDecoder> {
    const workerUrl = options.workerUrl ?? new URL("./workers/dnxSharedRowDecode.worker.js", import.meta.url);
    const slots = Array.from({ length: Math.max(1, concurrency) }, () => ({
      worker: workerFactory("shared-row", workerUrl),
      failed: false
    }));
    const pool = new DnxSharedRowDecoder(slots, options.rowDecoderWasmUrl);
    try {
      await Promise.all(slots.map((slot) => pool.initializeSlot(slot)));
      return pool;
    } catch (error) {
      pool.destroy();
      throw error;
    }
  }

  get decodeQueueSize(): number {
    return this.queueSize;
  }

  get desiredSize(): number {
    return this.closed ? 0 : 1 - this.queueSize;
  }

  get dequeued(): Promise<void> {
    return this.dequeuedPromise;
  }

  /** False once closed or once every row worker has failed. */
  get isUsable(): boolean {
    return !this.closed && this.slots.some((slot) => !slot.failed);
  }

  decode(
    packet: Uint8Array,
    header: DnxFrameHeader,
    reusableFrameBuffer?: SharedArrayBuffer
  ): Promise<DnxSharedRowDecodeResult> {
    if (this.closed) {
      return Promise.reject(new Error("DNx shared row decoder is closed."));
    }

    this.queueSize += 1;
    const preceding = this.tail;
    let releaseTail!: () => void;
    this.tail = new Promise<void>((resolve) => {
      releaseTail = resolve;
    });

    return preceding
      .then(() => this.decodeNow(packet, header, reusableFrameBuffer))
      .finally(() => {
        this.queueSize -= 1;
        releaseTail();
        this.signalDequeued();
      });
  }

  async close(): Promise<void> {
    if (this.closed) {
      return this.closePromise ?? Promise.resolve();
    }
    this.closed = true;
    this.closePromise = this.tail.then(() => {
      this.terminateWorkers();
    });
    return this.closePromise;
  }

  destroy(): void {
    if (this.closed && this.pendingRows.size === 0) {
      this.terminateWorkers();
      return;
    }
    this.closed = true;
    const error = new Error("DNx shared row decoder was closed during decode.");
    for (const pending of this.pendingRows.values()) {
      pending.reject(error);
    }
    this.pendingRows.clear();
    this.terminateWorkers();
    this.queueSize = 0;
    this.signalDequeued();
  }

  private async decodeNow(
    packet: Uint8Array,
    header: DnxFrameHeader,
    reusableFrameBuffer?: SharedArrayBuffer
  ): Promise<DnxSharedRowDecodeResult> {
    const availableSlots = this.slots.filter((slot) => !slot.failed);
    if (availableSlots.length === 0) {
      throw new Error("No DNx shared row workers are available.");
    }

    const rows = parseDnxRowSpans(packet, header);
    const packetBuffer = this.packetBuffer && this.packetBuffer.byteLength >= packet.byteLength
      ? this.packetBuffer
      : new SharedArrayBuffer(packet.byteLength);
    this.packetBuffer = packetBuffer;
    new Uint8Array(packetBuffer).set(packet);
    const frameByteLength = dnxFrameByteLength(header);
    const frameBuffer = reusableFrameBuffer && reusableFrameBuffer.byteLength >= frameByteLength
      ? reusableFrameBuffer
      : new SharedArrayBuffer(frameByteLength);
    const layout = createDnxFrameLayout(header, frameBuffer);

    // Wait for every row, not just the first failure: the next frame may reuse
    // this frame buffer and overwrites the shared packet buffer, so none of
    // this frame's rows may still be running when the queue moves on.
    const settled = await Promise.allSettled(rows.map((row, index) => {
      const slot = availableSlots[index % availableSlots.length];
      const requestId = this.nextRequestId++;
      return new Promise<void>((resolve, reject) => {
        this.pendingRows.set(requestId, { row: row.row, resolve, reject });
        const request: DnxSharedRowWorkerRequest = {
          type: "decode-row",
          requestId,
          packet: packetBuffer,
          frame: frameBuffer,
          rowStart: row.start,
          rowEnd: row.end,
          row: row.row,
          header
        };
        try {
          slot.worker.postMessage(request);
        } catch (error) {
          this.pendingRows.delete(requestId);
          reject(toError(error, "Failed to schedule a DNx row decode."));
        }
      });
    }));
    const failure = settled.find((result) => result.status === "rejected");
    if (failure) {
      throw failure.reason;
    }

    return { layout, frameBuffer };
  }

  private initializeSlot(slot: WorkerSlot): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const onReady = (event: MessageEvent<DnxSharedRowWorkerResponse>) => {
        if (event.data.type === "ready") {
          cleanup();
          resolve();
        } else if (event.data.type === "error" && event.data.requestId === undefined) {
          cleanup();
          reject(new Error(event.data.message));
        }
      };
      const onInitialError = (event: ErrorEvent) => {
        cleanup();
        reject(new Error(event.message || "DNx shared row worker initialization failed."));
      };
      const cleanup = () => {
        slot.worker.removeEventListener("message", onReady);
        slot.worker.removeEventListener("error", onInitialError);
      };
      slot.worker.addEventListener("message", onReady);
      slot.worker.addEventListener("error", onInitialError);
      slot.worker.addEventListener("message", (event: MessageEvent<DnxSharedRowWorkerResponse>) => {
        this.handleResponse(event.data);
      });
      slot.worker.addEventListener("error", (event) => {
        this.failSlot(slot, new Error(event.message || "DNx shared row worker failed."));
      });
      const request: DnxSharedRowWorkerRequest = this.rowDecoderWasmUrl
        ? { type: "init", rowDecoderWasmUrl: this.rowDecoderWasmUrl }
        : { type: "init" };
      slot.worker.postMessage(request);
    });
  }

  private handleResponse(response: DnxSharedRowWorkerResponse): void {
    if (response.type === "ready" || response.requestId === undefined) {
      return;
    }
    const pending = this.pendingRows.get(response.requestId);
    if (!pending) {
      return;
    }
    this.pendingRows.delete(response.requestId);
    if (response.type === "decoded-row") {
      pending.resolve();
    } else {
      pending.reject(new Error(
        `DNx shared row ${pending.row} request ${response.requestId}: ${response.message}`
      ));
    }
  }

  private failSlot(slot: WorkerSlot, error: Error): void {
    if (slot.failed) {
      return;
    }
    slot.failed = true;
    slot.worker.terminate();
    for (const pending of this.pendingRows.values()) {
      pending.reject(error);
    }
    this.pendingRows.clear();
  }

  private signalDequeued(): void {
    this.dequeuedResolve?.();
    this.dequeuedPromise = new Promise<void>((resolve) => {
      this.dequeuedResolve = resolve;
    });
  }

  private terminateWorkers(): void {
    for (const slot of this.slots) {
      const request: DnxSharedRowWorkerRequest = { type: "close" };
      try {
        slot.worker.postMessage(request);
      } catch {
        // A failed worker may already have terminated.
      } finally {
        slot.worker.terminate();
      }
    }
  }
}

function toError(value: unknown, fallback: string): Error {
  return value instanceof Error ? value : new Error(fallback);
}
