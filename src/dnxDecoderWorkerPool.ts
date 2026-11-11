import type { DecodeOptions, DnxPixelFormat, FilledFrame, Frame } from "./dnxDecoder.js";
import type {
  DnxPacketWorkerRequest,
  DnxPacketWorkerResponse,
  DnxWorkerFrameContents
} from "./dnxDecoderWorkerProtocol.js";
import { dnxFrameMetadataForHeader } from "./dnxFrame.js";
import type { DnxWorker, DnxWorkerFactory } from "./dnxWorker.js";
import type { DnxFourCc } from "./dnxFrame.js";

interface DnxWorkerPoolOptions {
  dnxFourCc: DnxFourCc;
  concurrency: number;
  allowedOutputFormats: readonly DnxPixelFormat[];
  workerFactory: DnxWorkerFactory | null;
  /** The worker module (default `./workers/dnxPacketDecode.worker.js` beside this file). */
  workerUrl?: URL;
  /** Absolute URLs the workers load the WebAssembly modules from. */
  wasmUrls?: { rowDecoder?: string; idctKernel?: string };
}

interface WorkerSlot {
  worker: DnxWorker;
  load: number;
  failed: boolean;
}

interface PendingDecode {
  slot: WorkerSlot;
  frame: Frame;
  resolve(frame: FilledFrame): void;
  reject(error: Error): void;
  outcome?:
    | { ok: true; response: Extract<DnxPacketWorkerResponse, { type: "decoded" }> }
    | { ok: false; error: Error };
}

export class DnxDecoderWorkerPool {
  readonly concurrency: number;
  private readonly slots: WorkerSlot[];
  private readonly pending = new Map<number, PendingDecode>();
  private nextRequestId = 1;
  private nextSettlementId = 1;
  private queueSize = 0;
  private closed = false;
  private closePromise: Promise<void> | null = null;
  private drainResolve: (() => void) | null = null;
  private dequeuedResolve: (() => void) | null = null;
  private dequeuedPromise = new Promise<void>((resolve) => {
    this.dequeuedResolve = resolve;
  });
  private currentMode = "worker-pool/initializing";

  private constructor(slots: WorkerSlot[]) {
    this.slots = slots;
    this.concurrency = slots.length;
  }

  static async create(options: DnxWorkerPoolOptions): Promise<DnxDecoderWorkerPool> {
    if (!options.workerFactory) {
      throw new Error("A DNx worker factory is required for packet-worker decoding.");
    }
    const workerUrl = options.workerUrl ?? new URL("./workers/dnxPacketDecode.worker.js", import.meta.url);
    const slots = Array.from({ length: options.concurrency }, () => ({
      worker: options.workerFactory!("packet", workerUrl),
      load: 0,
      failed: false
    }));
    const pool = new DnxDecoderWorkerPool(slots);
    try {
      await Promise.all(slots.map((slot) => pool.initializeSlot(slot, options)));
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
    const availableWorkers = this.slots.filter((slot) => !slot.failed).length;
    return this.closed ? 0 : availableWorkers * 2 - this.queueSize;
  }

  get dequeued(): Promise<void> {
    return this.dequeuedPromise;
  }

  get mode(): string {
    return this.currentMode;
  }

  decode(packetData: Uint8Array, frame: Frame, options: DecodeOptions): Promise<FilledFrame> {
    if (this.closed) {
      return Promise.reject(new Error("DNx decoder worker pool is closed."));
    }

    const availableSlots = this.slots.filter((slot) => !slot.failed);
    if (availableSlots.length === 0) {
      return Promise.reject(new Error("No DNx packet workers are available."));
    }

    const slot = availableSlots.reduce((best, candidate) =>
      candidate.load < best.load ? candidate : best
    );
    const packet = transferablePacket(packetData, options.transfer === true);
    const requestId = this.nextRequestId++;
    slot.load += 1;
    this.queueSize += 1;

    return new Promise<FilledFrame>((resolve, reject) => {
      this.pending.set(requestId, { slot, frame, resolve, reject });
      const request: DnxPacketWorkerRequest = {
        type: "decode",
        requestId,
        packet: packet.buffer
      };
      try {
        slot.worker.postMessage(request, [packet.buffer]);
      } catch (error) {
        this.failSlot(slot, toError(error, "Failed to send a DNx packet to its worker."));
      }
    });
  }

  async close(): Promise<void> {
    if (this.closed) {
      return this.closePromise ?? Promise.resolve();
    }
    this.closed = true;
    this.closePromise = this.waitForDrain().then(() => {
      this.terminateWorkers();
    });
    return this.closePromise;
  }

  destroy(): void {
    if (this.closed && this.pending.size === 0) {
      this.terminateWorkers();
      return;
    }
    this.closed = true;
    const error = new Error("DNx decoder worker pool was closed during decode.");
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
    this.terminateWorkers();
    this.queueSize = 0;
    this.signalDequeued();
    this.drainResolve?.();
    this.drainResolve = null;
  }

  private initializeSlot(slot: WorkerSlot, options: DnxWorkerPoolOptions): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const onMessage = (event: MessageEvent<DnxPacketWorkerResponse>) => {
        if (event.data.type === "ready") {
          this.currentMode = `worker-pool/${event.data.mode}`;
          resolve();
        } else if (event.data.type === "error" && event.data.requestId === undefined) {
          reject(new Error(event.data.message));
        } else {
          return;
        }
        slot.worker.removeEventListener("message", onMessage);
        slot.worker.removeEventListener("error", onError);
      };
      const onError = (event: ErrorEvent) => {
        reject(new Error(event.message || "DNx packet worker initialization failed."));
        slot.worker.removeEventListener("message", onMessage);
        slot.worker.removeEventListener("error", onError);
      };
      slot.worker.addEventListener("message", onMessage);
      slot.worker.addEventListener("error", onError);
      slot.worker.addEventListener("message", (event: MessageEvent<DnxPacketWorkerResponse>) => {
        this.handleResponse(event.data);
      });
      slot.worker.addEventListener("error", (event) => {
        this.failSlot(slot, new Error(event.message || "DNx packet worker failed."));
      });
      const request: DnxPacketWorkerRequest = {
        type: "init",
        dnxFourCc: options.dnxFourCc,
        allowedOutputFormats: options.allowedOutputFormats,
        ...(options.wasmUrls ? { wasmUrls: options.wasmUrls } : {})
      };
      slot.worker.postMessage(request);
    });
  }

  private handleResponse(response: DnxPacketWorkerResponse): void {
    if (response.type === "ready") {
      return;
    }
    if (response.requestId === undefined) {
      return;
    }
    const pending = this.pending.get(response.requestId);
    if (!pending) {
      return;
    }

    pending.slot.load -= 1;
    if (response.type === "decoded") {
      this.currentMode = `worker-pool/${response.mode}`;
      pending.outcome = { ok: true, response };
    } else {
      const error = new Error(
        `DNx packet worker request ${response.requestId}: ${response.message}`
      );
      error.name = response.errorName ?? "Error";
      pending.outcome = { ok: false, error };
    }
    this.settleCompletedInOrder();
  }

  private failSlot(slot: WorkerSlot, error: Error): void {
    if (slot.failed) {
      return;
    }
    slot.failed = true;
    slot.worker.terminate();
    for (const [requestId, pending] of this.pending) {
      if (pending.slot !== slot) {
        continue;
      }
      pending.outcome = { ok: false, error };
    }
    slot.load = 0;
    this.settleCompletedInOrder();
  }

  private settleCompletedInOrder(): void {
    while (true) {
      const pending = this.pending.get(this.nextSettlementId);
      if (!pending?.outcome) {
        break;
      }
      this.pending.delete(this.nextSettlementId);
      this.nextSettlementId += 1;
      this.queueSize -= 1;
      if (pending.outcome.ok) {
        populateFrame(pending.frame, pending.outcome.response.frame);
        pending.resolve(pending.frame as FilledFrame);
      } else {
        pending.reject(pending.outcome.error);
      }
      this.signalDequeued();
    }
    if (this.queueSize === 0) {
      this.drainResolve?.();
      this.drainResolve = null;
    }
  }

  private waitForDrain(): Promise<void> {
    if (this.queueSize === 0) {
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => {
      this.drainResolve = resolve;
    });
  }

  private terminateWorkers(): void {
    for (const slot of this.slots) {
      const request: DnxPacketWorkerRequest = { type: "close" };
      try {
        slot.worker.postMessage(request);
      } catch {
        // A failed worker may already have terminated.
      } finally {
        slot.worker.terminate();
      }
    }
  }

  private signalDequeued(): void {
    this.dequeuedResolve?.();
    this.dequeuedPromise = new Promise<void>((resolve) => {
      this.dequeuedResolve = resolve;
    });
  }
}

function toError(value: unknown, fallback: string): Error {
  return value instanceof Error ? value : new Error(fallback);
}

function transferablePacket(packetData: Uint8Array, transfer: boolean): Uint8Array<ArrayBuffer> {
  if (
    transfer &&
    packetData.buffer instanceof ArrayBuffer &&
    packetData.byteOffset === 0 &&
    packetData.byteLength === packetData.buffer.byteLength
  ) {
    return packetData as Uint8Array<ArrayBuffer>;
  }
  return new Uint8Array(packetData);
}

function populateFrame(frame: Frame, contents: DnxWorkerFrameContents): void {
  const metadata = dnxFrameMetadataForHeader(contents.header);
  frame.codedWidth = contents.codedWidth;
  frame.codedHeight = contents.codedHeight;
  frame.visibleWidth = contents.visibleWidth;
  frame.visibleHeight = contents.visibleHeight;
  frame.pixelFormat = contents.pixelFormat;
  frame.originalPixelFormat = contents.originalPixelFormat;
  frame.colorSpace = contents.colorSpace;
  frame.header = contents.header;
  frame.layout = contents.layout;
  frame.frameData = contents.layout.planes[0].bytes;
  frame.pixelAspectRatio = metadata.pixelAspectRatio;
  frame.colorPrimaries = metadata.colorPrimaries;
  frame.colorTransfer = metadata.colorTransfer;
  frame.colorMatrix = metadata.colorMatrix;
  frame.colorRangeFull = metadata.colorRangeFull;
  frame.scanType = metadata.scanType;
}
