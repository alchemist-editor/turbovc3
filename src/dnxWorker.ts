export type DnxWorkerKind = "packet" | "shared-row";

export interface DnxWorker {
  addEventListener(type: "message", listener: (event: MessageEvent) => void): void;
  addEventListener(type: "error", listener: (event: ErrorEvent) => void): void;
  removeEventListener(type: "message", listener: (event: MessageEvent) => void): void;
  removeEventListener(type: "error", listener: (event: ErrorEvent) => void): void;
  postMessage(message: unknown, transfer?: Transferable[]): void;
  terminate(): void;
}

export type DnxWorkerFactory = (kind: DnxWorkerKind, moduleUrl: URL) => DnxWorker;

/**
 * Where the WebAssembly modules are fetched from. Defaults are the files in
 * `../wasm/generated/` beside dist; relative URLs resolve against the page
 * (or the calling worker), and workers receive them as absolute URLs.
 */
export interface DnxWasmUrls {
  rowDecoder?: string | URL;
  idctKernel?: string | URL;
}

/** Worker module URLs; defaults are the worker files beside dist. */
export interface DnxWorkerUrls {
  sharedRow?: string | URL;
  packet?: string | URL;
}

/** A worker backend that failed to start; the decoder fell back to the next one. */
export interface DnxWorkerStartError {
  backend: DnxWorkerKind;
  error: Error;
}
