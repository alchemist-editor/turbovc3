import { Worker as NodeWorker } from "node:worker_threads";
import {
  Decoder,
  type DecoderOptions,
  type DnxNotSupportedError
} from "./dnxDecoder.js";
import type {
  DnxWorker,
  DnxWorkerFactory,
  DnxWorkerKind,
  DnxWorkerUrls
} from "./dnxWorker.js";

export * from "./index.js";

/**
 * {@link DecoderOptions} without `workerFactory`: workers are
 * `node:worker_threads` workers running the package's Node wrappers. A
 * `workerUrls` entry replaces that kind's wrapper; it must be a
 * `worker_threads` module, like `dist/workers/dnxNodePacketDecode.worker.js`.
 */
export type NodeDecoderOptions = Omit<DecoderOptions, "workerFactory">;

export function createNodeDecoder(
  options: NodeDecoderOptions
): Promise<DnxNotSupportedError | Decoder> {
  return Decoder.create({ ...options, workerFactory: nodeWorkerFactory(options.workerUrls) });
}

/** The Node wrappers, except for a kind `workerUrls` overrides: that one runs the URL the decoder resolved. */
function nodeWorkerFactory(workerUrls: DnxWorkerUrls | undefined): DnxWorkerFactory {
  return (kind, moduleUrl) => {
    const override = kind === "packet" ? workerUrls?.packet : workerUrls?.sharedRow;
    return override === undefined
      ? createNodeWorker(kind, moduleUrl)
      : new NodeWorkerAdapter(kind, new NodeWorker(moduleUrl));
  };
}

export const createNodeWorker: DnxWorkerFactory = (kind) => {
  const moduleUrl = new URL(
    kind === "packet"
      ? "./workers/dnxNodePacketDecode.worker.js"
      : "./workers/dnxNodeSharedRowDecode.worker.js",
    import.meta.url
  );
  return new NodeWorkerAdapter(kind, new NodeWorker(moduleUrl));
};

class NodeWorkerAdapter implements DnxWorker {
  private readonly listeners = new Map<Function, (value: unknown) => void>();

  constructor(
    readonly kind: DnxWorkerKind,
    private readonly worker: NodeWorker
  ) {}

  addEventListener(type: "message", listener: (event: MessageEvent) => void): void;
  addEventListener(type: "error", listener: (event: ErrorEvent) => void): void;
  addEventListener(
    type: "message" | "error",
    listener: ((event: MessageEvent) => void) | ((event: ErrorEvent) => void)
  ): void {
    const wrapped = type === "message"
      ? (value: unknown) => (listener as (event: MessageEvent) => void)({ data: value } as MessageEvent)
      : (value: unknown) => {
          const error = value instanceof Error ? value : new Error(String(value));
          (listener as (event: ErrorEvent) => void)({ error, message: error.message } as ErrorEvent);
        };
    this.listeners.set(listener, wrapped);
    this.worker.on(type, wrapped);
  }

  removeEventListener(type: "message", listener: (event: MessageEvent) => void): void;
  removeEventListener(type: "error", listener: (event: ErrorEvent) => void): void;
  removeEventListener(
    type: "message" | "error",
    listener: ((event: MessageEvent) => void) | ((event: ErrorEvent) => void)
  ): void {
    const wrapped = this.listeners.get(listener);
    if (!wrapped) {
      return;
    }
    this.worker.off(type, wrapped);
    this.listeners.delete(listener);
  }

  postMessage(message: unknown, transfer: Transferable[] = []): void {
    this.worker.postMessage(message, transfer as never[]);
  }

  terminate(): void {
    void this.worker.terminate();
  }
}
