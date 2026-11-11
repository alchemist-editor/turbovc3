import type { DecodePixelFormat } from "./core/codec.js";
import {
  DNX_SAMPLE_ENTRIES,
  dnxFrameMetadataForHeader,
  parseDnxFrameHeader,
  type DnxFourCc,
  type DnxFrameHeader,
  type DnxScanType
} from "./dnxFrame.js";
import {
  analyzeDnxPixelReconstruction,
  type DnxFrameLayout,
  type DnxReconstructionState
} from "./dnxReconstruction.js";
import { createDnxIdctKernel, type DnxIdctKernel, type DnxIdctMode } from "./dnxIdctKernel.js";
import { decodeDnxScalarFrame, supportsDnxScalarCid } from "./dnxScalarDecoder.js";
import { convertDnxFrameLayout, selectDnxOutputFormat } from "./dnxPixelConversion.js";
import { DnxSharedRowDecoder } from "./dnxSharedRowDecoder.js";
import { createDnxZigRowDecoder, type DnxRowDecoder } from "./dnxZigRowDecoder.js";
import { DnxDecoderWorkerPool } from "./dnxDecoderWorkerPool.js";
import type {
  DnxWasmUrls,
  DnxWorkerFactory,
  DnxWorkerStartError,
  DnxWorkerUrls
} from "./dnxWorker.js";

export type DnxPixelFormat = Extract<
  DecodePixelFormat,
  | "yuv420p8"
  | "yuv420p10"
  | "yuv420p12"
  | "yuv422p8"
  | "yuv422p10"
  | "yuv422p12"
  | "yuv444p8"
  | "yuv444p10"
  | "yuv444p12"
  | "gbrp10"
  | "gbrp12"
>;

export interface DecoderOptions {
  dnxFourCc: DnxFourCc;
  useSharedMemory: boolean;
  concurrency?: number;
  allowedOutputFormats?: readonly DnxPixelFormat[];
  workerFactory?: DnxWorkerFactory;
  /** Where to fetch the WebAssembly modules from (see {@link DnxWasmUrls}). */
  wasmUrls?: DnxWasmUrls;
  /** Worker module URLs (see {@link DnxWorkerUrls}). */
  workerUrls?: DnxWorkerUrls;
  /**
   * Called when a worker backend fails to start. The decoder still falls back
   * (shared-row workers, then packet workers, then the calling thread); this
   * reports why instead of swallowing it.
   */
  onWorkerStartError?: (error: DnxWorkerStartError) => void;
}

interface ResolvedDecoderOptions {
  dnxFourCc: DnxFourCc;
  useSharedMemory: boolean;
  concurrency: number;
  allowedOutputFormats: readonly DnxPixelFormat[];
  workerFactory: DnxWorkerFactory | null;
}

export interface DecodeOptions {
  transfer?: boolean;
}

export interface DnxPlaneCopyLayout {
  offset: number;
  stride: number;
}

export interface DnxResolvedPlaneCopyLayout extends DnxPlaneCopyLayout {
  label: string;
  width: number;
  height: number;
  rowBytes: number;
  byteLength: number;
}

export interface DnxVideoFrameOptions {
  timestamp: number;
  duration?: number;
  displayWidth?: number;
  displayHeight?: number;
  colorSpace?: VideoColorSpaceInit;
}

export type FilledFrame = {
  [K in keyof Frame]: NonNullable<Frame[K]>;
};

export class DnxDecoderError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DnxDecoderError";
  }
}

export class DnxInvalidDataError extends DnxDecoderError {
  constructor(message = "Invalid DNx packet data.") {
    super(message);
    this.name = "DnxInvalidDataError";
  }
}

export class DnxUnexpectedEofError extends DnxInvalidDataError {
  constructor(message = "DNx packet ended before the frame could be decoded.") {
    super(message);
    this.name = "DnxUnexpectedEofError";
  }
}

export class DnxOutOfMemoryError extends DnxDecoderError {
  constructor(message = "The DNx decoder could not allocate its output frame.") {
    super(message);
    this.name = "DnxOutOfMemoryError";
  }
}

export class DnxNotSupportedError extends DnxDecoderError {
  constructor(message = "DNx feature is not supported by this decoder yet.") {
    super(message);
    this.name = "DnxNotSupportedError";
  }
}

export class DnxReconstructionPendingError extends DnxNotSupportedError {
  constructor(
    message: string,
    readonly state: unknown
  ) {
    super(message);
    this.name = "DnxReconstructionPendingError";
  }
}

export class DnxDecoderClosedError extends DnxDecoderError {
  constructor(message = "DNx decoder is closed.") {
    super(message);
    this.name = "DnxDecoderClosedError";
  }
}

export class DnxFrameLockedError extends DnxDecoderError {
  constructor(message = "DNx output frame is already in use by another decode.") {
    super(message);
    this.name = "DnxFrameLockedError";
  }
}

const sharedFrameBuffers = new WeakMap<Frame, SharedArrayBuffer>();

export class Frame implements Disposable {
  frameData: Uint8Array | null = null;
  codedWidth: number | null = null;
  codedHeight: number | null = null;
  visibleWidth: number | null = null;
  visibleHeight: number | null = null;
  pixelFormat: DnxPixelFormat | null = null;
  originalPixelFormat: DnxPixelFormat | null = null;
  colorSpace: DnxFrameHeader["colorSpace"] | null = null;
  pixelAspectRatio: { num: number; den: number } | null = null;
  colorPrimaries: number | null = null;
  colorTransfer: number | null = null;
  colorMatrix: number | null = null;
  colorRangeFull: false | null = null;
  scanType: DnxScanType | null = null;
  header: DnxFrameHeader | null = null;
  layout: DnxFrameLayout | null = null;
  private locked = false;

  get isLocked(): boolean {
    return this.locked;
  }

  get isFilled(): boolean {
    return this.frameData !== null
      && this.codedWidth !== null
      && this.codedHeight !== null
      && this.visibleWidth !== null
      && this.visibleHeight !== null
      && this.pixelFormat !== null
      && this.originalPixelFormat !== null
      && this.colorSpace !== null
      && this.header !== null
      && this.layout !== null
      && this.pixelAspectRatio !== null
      && this.colorPrimaries !== null
      && this.colorTransfer !== null
      && this.colorMatrix !== null
      && this.colorRangeFull !== null
      && this.scanType !== null;
  }

  toFilled(): FilledFrame | null {
    return this.isFilled ? this as FilledFrame : null;
  }

  copyLayout(layout?: readonly DnxPlaneCopyLayout[]): readonly DnxResolvedPlaneCopyLayout[] {
    return resolveFrameCopyLayout(this, layout);
  }

  allocationSize(layout?: readonly DnxPlaneCopyLayout[]): number {
    const resolved = resolveFrameCopyLayout(this, layout);
    return resolved.reduce(
      (maximum, plane) => Math.max(maximum, plane.offset + plane.byteLength),
      0
    );
  }

  copyTo(
    destination: Uint8Array,
    layout?: readonly DnxPlaneCopyLayout[]
  ): readonly DnxResolvedPlaneCopyLayout[] {
    const sourceLayout = copyableFrameLayout(this);
    const resolved = resolveFrameCopyLayout(this, layout);
    const requiredBytes = resolved.reduce(
      (maximum, plane) => Math.max(maximum, plane.offset + plane.byteLength),
      0
    );
    if (destination.byteLength < requiredBytes) {
      throw new RangeError(
        `DNx frame copy requires ${requiredBytes} destination bytes, got ${destination.byteLength}.`
      );
    }
    for (let planeIndex = 0; planeIndex < resolved.length; planeIndex += 1) {
      const source = sourceLayout.planes[planeIndex];
      const target = resolved[planeIndex];
      for (let row = 0; row < target.height; row += 1) {
        const sourceOffset = row * source.stride;
        const destinationOffset = target.offset + row * target.stride;
        destination.set(
          source.bytes.subarray(sourceOffset, sourceOffset + target.rowBytes),
          destinationOffset
        );
      }
    }
    return resolved;
  }

  toVideoFrame(options: DnxVideoFrameOptions): VideoFrame {
    if (typeof VideoFrame === "undefined") {
      throw new DnxNotSupportedError("VideoFrame is not available in this runtime.");
    }
    const format = videoPixelFormat(this.pixelFormat);
    if (!format) {
      throw new DnxNotSupportedError(
        `DNx pixel format ${this.pixelFormat ?? "unknown"} cannot be represented by a WebCodecs VideoFrame.`
      );
    }
    const layout = this.copyLayout();
    const data = videoFrameData(this, layout);
    const visibleWidth = this.visibleWidth!;
    const visibleHeight = this.visibleHeight!;
    const aspect = this.pixelAspectRatio!;
    return new VideoFrame(data, {
      format,
      codedWidth: this.codedWidth!,
      codedHeight: this.codedHeight!,
      visibleRect: { x: 0, y: 0, width: visibleWidth, height: visibleHeight },
      displayWidth: options.displayWidth ?? Math.round(visibleWidth * aspect.num / aspect.den),
      displayHeight: options.displayHeight ?? visibleHeight,
      timestamp: options.timestamp,
      duration: options.duration,
      colorSpace: options.colorSpace ?? videoColorSpace(this),
      layout: layout.map((plane) => ({ offset: plane.offset, stride: plane.stride }))
    });
  }

  get colorPrimariesString(): string | undefined {
    return this.colorPrimaries === 1 ? "bt709" : this.colorPrimaries === 9 ? "bt2020" : undefined;
  }

  get colorTransferString(): string | undefined {
    return this.colorTransfer === 1 ? "bt709" : undefined;
  }

  get colorMatrixString(): string | undefined {
    return this.colorMatrix === 1 ? "bt709" : this.colorMatrix === 9 ? "bt2020-ncl" : this.colorMatrix === 10 ? "bt2020-cl" : undefined;
  }

  acquireLock(): boolean {
    if (this.locked) {
      return false;
    }
    this.locked = true;
    return true;
  }

  releaseLock(): void {
    this.locked = false;
  }

  clear(): void {
    if (this.locked) {
      throw new DnxFrameLockedError("Cannot clear a DNx output frame while decode is in progress.");
    }
    this.frameData = null;
    this.codedWidth = null;
    this.codedHeight = null;
    this.visibleWidth = null;
    this.visibleHeight = null;
    this.pixelFormat = null;
    this.originalPixelFormat = null;
    this.colorSpace = null;
    this.pixelAspectRatio = null;
    this.colorPrimaries = null;
    this.colorTransfer = null;
    this.colorMatrix = null;
    this.colorRangeFull = null;
    this.scanType = null;
    this.header = null;
    this.layout = null;
    sharedFrameBuffers.delete(this);
  }

  [Symbol.dispose](): void {
    this.clear();
  }
}

function videoFrameData(frame: Frame, layout: readonly DnxResolvedPlaneCopyLayout[]): Uint8Array {
  const source = frame.layout!;
  const first = source.planes[0]?.bytes;
  const byteLength = frame.allocationSize(layout);
  if (
    first?.buffer instanceof ArrayBuffer &&
    source.planes.every((plane, index) =>
      plane.bytes.buffer === first.buffer &&
      plane.bytes.byteOffset - first.byteOffset === layout[index].offset &&
      plane.stride === layout[index].stride &&
      plane.bytes.byteLength >= layout[index].byteLength
    )
  ) {
    return new Uint8Array(first.buffer, first.byteOffset, byteLength);
  }
  const data = new Uint8Array(byteLength);
  frame.copyTo(data, layout);
  return data;
}

function videoPixelFormat(format: DnxPixelFormat | null): VideoPixelFormat | null {
  switch (format) {
    case "yuv420p8": return "I420";
    case "yuv422p8": return "I422";
    case "yuv444p8": return "I444";
    default: return null;
  }
}

function videoColorSpace(frame: Frame): VideoColorSpaceInit {
  return {
    primaries: frame.colorPrimariesString,
    transfer: frame.colorTransferString,
    matrix: frame.colorMatrixString,
    fullRange: frame.colorRangeFull ?? false
  } as VideoColorSpaceInit;
}

export class Decoder implements AsyncDisposable {
  readonly useSharedMemory: boolean;
  readonly concurrency: number;
  readonly dnxFourCc: DnxFourCc;
  readonly allowedOutputFormats: readonly DnxPixelFormat[];
  private closed = false;
  private closePromise: Promise<void> | null = null;

  private constructor(
    options: ResolvedDecoderOptions,
    private readonly idctKernel: DnxIdctKernel | null,
    private readonly rowDecoder: DnxRowDecoder | null,
    private readonly sharedRowDecoder: DnxSharedRowDecoder | null,
    private readonly workerPool: DnxDecoderWorkerPool | null
  ) {
    this.dnxFourCc = options.dnxFourCc;
    this.useSharedMemory = options.useSharedMemory;
    this.concurrency = options.concurrency;
    this.allowedOutputFormats = options.allowedOutputFormats;
  }

  get decodeQueueSize(): number {
    return this.sharedRowDecoder?.decodeQueueSize ?? this.workerPool?.decodeQueueSize ?? 0;
  }

  get desiredSize(): number {
    return this.closed ? 0 : (this.sharedRowDecoder?.desiredSize ?? this.workerPool?.desiredSize ?? 1);
  }

  get dequeued(): Promise<void> {
    return this.sharedRowDecoder?.dequeued ?? this.workerPool?.dequeued ?? Promise.resolve();
  }

  get isClosed(): boolean {
    return this.closed;
  }

  get idctMode(): string {
    return this.sharedRowDecoder?.mode ?? this.workerPool?.mode ?? this.rowDecoder?.mode ?? this.idctKernel?.mode ?? "uninitialized";
  }

  static async create(options: DecoderOptions): Promise<DnxNotSupportedError | Decoder> {
    if (!DNX_SAMPLE_ENTRIES.includes(options.dnxFourCc)) {
      return new DnxNotSupportedError(`Unsupported DNx sample entry "${options.dnxFourCc}".`);
    }
    const workerFactory = options.workerFactory ?? browserWorkerFactory();
    const resolvedOptions: ResolvedDecoderOptions = {
      dnxFourCc: options.dnxFourCc,
      useSharedMemory: options.useSharedMemory,
      concurrency: options.concurrency ?? Math.min(4, Math.max(1, globalThis.navigator?.hardwareConcurrency ?? 4)),
      allowedOutputFormats: options.allowedOutputFormats ?? [
        "yuv422p8", "yuv422p10", "yuv422p12", "yuv444p10", "yuv444p12", "gbrp10", "gbrp12"
      ],
      workerFactory
    };
    if (resolvedOptions.useSharedMemory) {
      if (!workerFactory || typeof SharedArrayBuffer === "undefined" || (!options.workerFactory && !Decoder.canUseSharedMemory())) {
        return new DnxNotSupportedError(
          "Shared-memory DNx row threading requires a worker factory, SharedArrayBuffer, and browser cross-origin isolation when applicable."
        );
      }
      try {
        const sharedRowDecoder = await DnxSharedRowDecoder.create(
          Math.max(1, resolvedOptions.concurrency),
          workerFactory,
          {
            workerUrl: absoluteUrl(options.workerUrls?.sharedRow),
            rowDecoderWasmUrl: absoluteUrl(options.wasmUrls?.rowDecoder)?.href
          }
        );
        return new Decoder(resolvedOptions, null, null, sharedRowDecoder, null);
      } catch (error) {
        reportWorkerStartError(options, "shared-row", error);
        // A page can satisfy the shared-memory capability checks while its row
        // worker module is temporarily unavailable (for example during a Vite
        // restart). Retry with the ordinary packet/scalar backends instead of
        // making shared-worker startup a hard requirement for DNx decoding.
        resolvedOptions.useSharedMemory = false;
      }
    }
    if (resolvedOptions.concurrency > 0 && workerFactory) {
      try {
        const workerPoolOptions = { ...resolvedOptions, useSharedMemory: false };
        const workerPool = await DnxDecoderWorkerPool.create({
          ...workerPoolOptions,
          workerUrl: absoluteUrl(options.workerUrls?.packet),
          wasmUrls: absoluteWasmUrls(options.wasmUrls)
        });
        return new Decoder(workerPoolOptions, null, null, null, workerPool);
      } catch (error) {
        reportWorkerStartError(options, "packet", error);
        // Fall through to the synchronous backend when nested workers are unavailable.
      }
    }

    const [idctKernel, rowDecoder] = await Promise.all([
      createDnxIdctKernel(absoluteUrl(options.wasmUrls?.idctKernel)),
      createDnxZigRowDecoder(absoluteUrl(options.wasmUrls?.rowDecoder))
    ]);
    return new Decoder(resolvedOptions, idctKernel, rowDecoder, null, null);
  }

  static canUseSharedMemory(): boolean {
    return (
      typeof Worker !== "undefined" &&
      typeof SharedArrayBuffer !== "undefined" &&
      globalThis.crossOriginIsolated === true
    );
  }

  async decode(
    packetData: Uint8Array,
    frame: Frame,
    options: DecodeOptions = {}
  ): Promise<
    | DnxInvalidDataError
    | DnxNotSupportedError
    | DnxDecoderClosedError
    | DnxFrameLockedError
    | DnxOutOfMemoryError
    | FilledFrame
  > {
    if (this.closed) {
      return new DnxDecoderClosedError();
    }
    if (!frame.acquireLock()) {
      return new DnxFrameLockedError();
    }

    try {
      const header = parseDnxFrameHeader(packetData);
      if (!header) {
        return packetData.byteLength < 0x280
          ? new DnxUnexpectedEofError(
              `DNx packet ended after ${packetData.byteLength} bytes; a frame header requires at least 640 bytes.`
            )
          : new DnxInvalidDataError("Packet does not contain a valid DNx frame header.");
      }

      // An unknown CID cannot determine whether AVdn or AVdh is the correct
      // sample entry, so reject it as unsupported before comparing FourCCs.
      if (header.profile === "unknown") {
        return new DnxNotSupportedError(header.unsupportedReasons.join(" "));
      }

      if (header.fourCc !== this.dnxFourCc) {
        return new DnxInvalidDataError(`Packet sample entry ${header.fourCc} does not match decoder ${this.dnxFourCc}.`);
      }

      if (header.expectedFrameSize !== null && packetData.byteLength < header.expectedFrameSize) {
        return new DnxUnexpectedEofError(
          `DNx packet ended after ${packetData.byteLength} bytes; CID ${header.cid} requires ${header.expectedFrameSize} bytes.`
        );
      }

      if (!header.supported) {
        return new DnxNotSupportedError(header.unsupportedReasons.join(" "));
      }

      const sourcePixelFormat = header.pixelFormat as DnxPixelFormat;
      const outputPixelFormat = selectDnxOutputFormat(sourcePixelFormat, this.allowedOutputFormats);
      if (!outputPixelFormat) {
        return new DnxNotSupportedError(
          `No allowed output pixel format can be produced from ${header.pixelFormat}.`
        );
      }

      if (this.sharedRowDecoder && !header.interlaced && !header.mbaff) {
        try {
          const decoded = await this.sharedRowDecoder.decode(
            packetData,
            header,
            sharedFrameBuffers.get(frame)
          );
          sharedFrameBuffers.set(frame, decoded.frameBuffer);
          const layout = convertDnxFrameLayout(
            decoded.layout,
            sourcePixelFormat,
            outputPixelFormat,
            header.colorSpace
          );
          populateDecodedFrame(frame, header, layout, outputPixelFormat);
          return frame as FilledFrame;
        } catch (error) {
          return decodeErrorFrom(error);
        }
      }

      if (this.workerPool) {
        try {
          return await this.workerPool.decode(packetData, frame, options);
        } catch (error) {
          return decodeErrorFrom(error);
        }
      }

      try {
        const backingBuffer = reusableScalarFrameBuffer(frame, header, sourcePixelFormat, outputPixelFormat);
        populateFrameHeader(frame, header);
        if (supportsDnxScalarCid(header.cid)) {
          const decoded = decodeDnxScalarFrame(
            packetData,
            header,
            this.idctKernel ?? undefined,
            this.rowDecoder,
            backingBuffer
          );
          const layout = convertDnxFrameLayout(decoded.layout, sourcePixelFormat, outputPixelFormat, header.colorSpace);
          frame.pixelFormat = outputPixelFormat;
          frame.layout = layout;
          frame.frameData = layout.planes[0].bytes;
          return frame as FilledFrame;
        }

        const reconstruction = analyzeDnxPixelReconstruction(packetData, header);
        frame.layout = reconstruction.layout;
        return new DnxReconstructionPendingError(
          "DNx frame layout, row spans, and first macroblock header were reconstructed; coefficient VLC and IDCT decode are not implemented yet.",
          reconstruction
        );
      } catch (error) {
        return decodeErrorFrom(error);
      }
    } finally {
      frame.releaseLock();
    }
  }

  async close(): Promise<void> {
    if (this.closePromise) {
      return this.closePromise;
    }

    this.closed = true;
    this.closePromise = (async () => {
      await Promise.all([
        this.workerPool?.close(),
        this.sharedRowDecoder?.close()
      ]);
      this.rowDecoder?.destroy();
      this.idctKernel?.destroy();
    })();
    return this.closePromise;
  }

  [Symbol.asyncDispose](): Promise<void> {
    return this.close();
  }
}

function reusableScalarFrameBuffer(
  frame: Frame,
  header: DnxFrameHeader,
  sourcePixelFormat: DnxPixelFormat,
  outputPixelFormat: DnxPixelFormat
): ArrayBufferLike | undefined {
  if (
    sourcePixelFormat !== outputPixelFormat ||
    frame.pixelFormat !== outputPixelFormat ||
    frame.codedWidth !== Math.ceil(header.width / 16) * 16 ||
    frame.codedHeight !== Math.ceil(header.height / 16) * 16
  ) {
    return undefined;
  }
  return frame.layout?.planes[0]?.bytes.buffer;
}

/** `url` made absolute against the page (or the calling worker); undefined stays undefined. */
function absoluteUrl(url: string | URL | undefined): URL | undefined {
  if (url === undefined) {
    return undefined;
  }
  const base = (globalThis as { location?: { href?: string } }).location?.href ?? import.meta.url;
  return new URL(url, base);
}

function absoluteWasmUrls(urls: DnxWasmUrls | undefined): { rowDecoder?: string; idctKernel?: string } | undefined {
  if (!urls) {
    return undefined;
  }
  return {
    ...(urls.rowDecoder !== undefined ? { rowDecoder: absoluteUrl(urls.rowDecoder)?.href } : {}),
    ...(urls.idctKernel !== undefined ? { idctKernel: absoluteUrl(urls.idctKernel)?.href } : {})
  };
}

function reportWorkerStartError(options: DecoderOptions, backend: "shared-row" | "packet", error: unknown): void {
  if (!options.onWorkerStartError) {
    return;
  }
  try {
    options.onWorkerStartError({ backend, error: error instanceof Error ? error : new Error(String(error)) });
  } catch {
    // A reporting hook must never change which backend is chosen.
  }
}

function browserWorkerFactory(): DnxWorkerFactory | null {
  if (typeof Worker === "undefined") {
    return null;
  }
  return (_kind, moduleUrl) => new Worker(moduleUrl, { type: "module" });
}

function copyableFrameLayout(frame: Frame): DnxFrameLayout {
  if (frame.isLocked) {
    throw new DnxFrameLockedError("Cannot copy a DNx output frame while decode is in progress.");
  }
  if (!frame.layout || !frame.frameData) {
    throw new Error("Cannot copy an empty DNx output frame.");
  }
  return frame.layout;
}

function resolveFrameCopyLayout(
  frame: Frame,
  requested?: readonly DnxPlaneCopyLayout[]
): DnxResolvedPlaneCopyLayout[] {
  const sourceLayout = copyableFrameLayout(frame);
  if (requested && requested.length !== sourceLayout.planes.length) {
    throw new RangeError(
      `DNx frame copy requires ${sourceLayout.planes.length} plane layouts, got ${requested.length}.`
    );
  }

  let defaultOffset = 0;
  const resolved = sourceLayout.planes.map((plane, index) => {
    const rowBytes = plane.width * sourceLayout.bytesPerSample;
    if (plane.stride < rowBytes || plane.bytes.byteLength < plane.stride * plane.height) {
      throw new RangeError(`DNx source plane ${index} has an invalid stride or byte length.`);
    }
    const candidate = requested?.[index] ?? { offset: defaultOffset, stride: rowBytes };
    if (
      !Number.isSafeInteger(candidate.offset) ||
      candidate.offset < 0 ||
      !Number.isSafeInteger(candidate.stride) ||
      candidate.stride < rowBytes
    ) {
      throw new RangeError(
        `DNx destination plane ${index} requires a non-negative offset and stride of at least ${rowBytes}.`
      );
    }
    const byteLength = candidate.stride * (plane.height - 1) + rowBytes;
    if (!Number.isSafeInteger(byteLength) || !Number.isSafeInteger(candidate.offset + byteLength)) {
      throw new RangeError(`DNx destination plane ${index} layout exceeds the safe integer range.`);
    }
    const result: DnxResolvedPlaneCopyLayout = {
      offset: candidate.offset,
      stride: candidate.stride,
      label: plane.label,
      width: plane.width,
      height: plane.height,
      rowBytes,
      byteLength
    };
    defaultOffset = result.offset + result.byteLength;
    return result;
  });

  const ordered = [...resolved].sort((left, right) => left.offset - right.offset);
  for (let index = 1; index < ordered.length; index += 1) {
    if (ordered[index].offset < ordered[index - 1].offset + ordered[index - 1].byteLength) {
      throw new RangeError("DNx destination plane layouts must not overlap.");
    }
  }
  return resolved;
}

function populateFrameHeader(frame: Frame, header: DnxFrameHeader): void {
  const metadata = dnxFrameMetadataForHeader(header);
  frame.header = header;
  frame.codedWidth = Math.ceil(header.width / 16) * 16;
  frame.codedHeight = Math.ceil(header.height / 16) * 16;
  frame.visibleWidth = header.width;
  frame.visibleHeight = header.height;
  frame.pixelFormat = header.pixelFormat as DnxPixelFormat;
  frame.originalPixelFormat = header.pixelFormat as DnxPixelFormat;
  frame.colorSpace = header.colorSpace;
  frame.pixelAspectRatio = metadata.pixelAspectRatio;
  frame.colorPrimaries = metadata.colorPrimaries;
  frame.colorTransfer = metadata.colorTransfer;
  frame.colorMatrix = metadata.colorMatrix;
  frame.colorRangeFull = metadata.colorRangeFull;
  frame.scanType = metadata.scanType;
}

function populateDecodedFrame(
  frame: Frame,
  header: DnxFrameHeader,
  layout: DnxFrameLayout,
  outputPixelFormat: DnxPixelFormat
): void {
  populateFrameHeader(frame, header);
  frame.pixelFormat = outputPixelFormat;
  frame.layout = layout;
  frame.frameData = layout.planes[0].bytes;
}

function decodeErrorFrom(error: unknown): DnxInvalidDataError | DnxUnexpectedEofError | DnxOutOfMemoryError {
  const message = error instanceof Error ? error.message : String(error);
  const name = error instanceof Error ? error.name : "";
  if (
    error instanceof DnxOutOfMemoryError ||
    name === "DnxOutOfMemoryError" ||
    error instanceof RangeError ||
    /out of memory|allocation failed/i.test(message)
  ) {
    return new DnxOutOfMemoryError(message);
  }
  if (
    error instanceof DnxUnexpectedEofError ||
    name === "DnxUnexpectedEofError" ||
    /unexpected end|ended before|outside the packet|smaller than/i.test(message)
  ) {
    return new DnxUnexpectedEofError(message);
  }
  return new DnxInvalidDataError(message);
}
