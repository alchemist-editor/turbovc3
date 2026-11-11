import {
  BufferSource,
  CustomVideoDecoder,
  EncodedPacketSink,
  Input,
  InputVideoTrack,
  LogLevel,
  Logging,
  Mp4InputFormat,
  QuickTimeInputFormat,
  VIDEO_CODECS,
  VideoSample,
  registerDecoder,
  type EncodedPacket,
  type VideoCodec
} from "mediabunny";
import { Decoder, Frame, type FilledFrame } from "./dnxDecoder.js";
import { acquireSharedDecoder, type SharedDecoderLease } from "./dnxSharedDecoderPool.js";
import type { DnxWasmUrls, DnxWorkerStartError, DnxWorkerUrls } from "./dnxWorker.js";
import {
  DNX_SAMPLE_ENTRIES,
  parseDnxFrameHeader,
  type DnxFourCc,
  type DnxFrameHeader
} from "./dnxFrame.js";

export interface DnxPacketSummary {
  data: Uint8Array;
  byteLength: number;
  timestamp: number;
  duration: number;
  sequenceNumber: number;
  header: DnxFrameHeader | null;
}

export interface DnxTrackInspection {
  trackNumber: number;
  codec: string | null;
  internalCodecId: string | null;
  codedWidth: number;
  codedHeight: number;
  displayWidth: number;
  displayHeight: number;
  colorSpace: {
    primaries: string | null;
    transfer: string | null;
    matrix: string | null;
    fullRange: boolean | null;
  };
  isDnx: boolean;
  packets: DnxPacketSummary[];
  firstPacket: DnxPacketSummary | null;
}

export interface DnxContainerInspection {
  tracks: DnxTrackInspection[];
  dnxTracks: DnxTrackInspection[];
}

export async function inspectDnxContainer(bytes: Uint8Array): Promise<DnxContainerInspection> {
  installDnxLoggingShim();
  const input = new Input({
    formats: [new QuickTimeInputFormat(), new Mp4InputFormat()],
    source: new BufferSource(bytes)
  });

  try {
    const tracks = await Promise.all(
      (await input.getVideoTracks()).map(async (track): Promise<DnxTrackInspection> => {
        const internalCodecId = normalizeInternalCodecId(await track.getInternalCodecId());
        const isDnx = isDnxInternalCodecId(internalCodecId);
        const packets = isDnx ? await readPackets(track) : [];
        const [codec, codedWidth, codedHeight, displayWidth, displayHeight, colorSpace] = await Promise.all([
          track.getCodec(),
          track.getCodedWidth(),
          track.getCodedHeight(),
          track.getDisplayWidth(),
          track.getDisplayHeight(),
          track.getColorSpace()
        ]);

        return {
          trackNumber: track.number,
          codec,
          internalCodecId,
          codedWidth,
          codedHeight,
          displayWidth,
          displayHeight,
          colorSpace: {
            primaries: colorSpace.primaries ?? null,
            transfer: colorSpace.transfer ?? null,
            matrix: colorSpace.matrix ?? null,
            fullRange: colorSpace.fullRange ?? null
          },
          isDnx,
          packets,
          firstPacket: packets[0] ?? null
        };
      })
    );

    return {
      tracks,
      dnxTracks: tracks.filter((track) => track.isDnx)
    };
  } finally {
    input.dispose();
  }
}

export function isDnxInternalCodecId(codecId: string | null): codecId is DnxFourCc {
  return codecId !== null && (DNX_SAMPLE_ENTRIES as readonly string[]).includes(codecId);
}

async function readPackets(track: Awaited<ReturnType<Input["getVideoTracks"]>>[number]): Promise<DnxPacketSummary[]> {
  const sink = new EncodedPacketSink(track);
  const packets: DnxPacketSummary[] = [];

  for await (const packet of sink.packets()) {
    packets.push({
      data: packet.data,
      byteLength: packet.byteLength,
      timestamp: packet.timestamp,
      duration: packet.duration,
      sequenceNumber: packet.sequenceNumber,
      header: parseDnxFrameHeader(packet.data)
    });
  }

  return packets;
}

function normalizeInternalCodecId(codecId: string | number | Uint8Array | null): string | null {
  if (typeof codecId === "string") {
    return codecId;
  }
  if (codecId instanceof Uint8Array) {
    return String.fromCharCode(...codecId);
  }
  if (typeof codecId === "number") {
    return codecId.toString(16);
  }
  return null;
}

const DNX_TRACK_SHIM = Symbol.for("@wasm-codecs/dnx Mediabunny track shim");
const trackDecodability = new WeakMap<InputVideoTrack, Promise<boolean>>();

/** Options for {@link registerDnxDecoder}; every field is optional. */
export interface RegisterDnxDecoderOptions {
  /**
   * Decoder backend: `true` for shared-memory row workers (one frame split
   * across workers; needs cross-origin isolation), `false` for packet workers
   * (a frame per worker). Default: row workers when `Decoder.canUseSharedMemory()`.
   */
  useSharedMemory?: boolean;
  /** Where the WebAssembly modules are fetched from. */
  wasmUrls?: DnxWasmUrls;
  /** Worker module URLs, for bundlers that emit the workers elsewhere. */
  workerUrls?: DnxWorkerUrls;
  /** Called when a worker backend fails to start (the decoder still falls back). */
  onWorkerStartError?: (error: DnxWorkerStartError) => void;
  /**
   * How long a released decoder waits for the next Mediabunny decoder, in ms
   * (default 1000). Mediabunny builds a decoder per `getSample()` call, so
   * this keeps one worker pool across a run of seeks.
   */
  idleCloseMs?: number;
}

let registeredOptions: RegisterDnxDecoderOptions = {};

class MediabunnyDnxDecoder extends CustomVideoDecoder {
  private decoder: Decoder | null = null;
  private lease: SharedDecoderLease | null = null;
  private readonly framePool: Frame[] = [];
  private emissionTail: Promise<void> = Promise.resolve();

  static override supports(codec: VideoCodec, config: VideoDecoderConfig): boolean {
    const dnxFourCc = normalizeDnxFourCc(config.codec);
    return (
      (codec as string) === "dnx" &&
      dnxFourCc !== null &&
      (config.codedWidth ?? 1920) <= 4096 &&
      (config.codedHeight ?? 1080) <= 2160
    );
  }

  async init(): Promise<void> {
    const dnxFourCc = normalizeDnxFourCc(this.config.codec);
    if (!dnxFourCc) {
      throw new Error(`Unsupported DNx decoder configuration codec "${this.config.codec}".`);
    }

    const options = registeredOptions;
    // A pooled decoder: reused across getSample() calls, never shared by two at once.
    const lease = await acquireSharedDecoder({
      dnxFourCc,
      useSharedMemory: options.useSharedMemory ?? Decoder.canUseSharedMemory(),
      allowedOutputFormats: ["yuv422p8", "yuv422p10", "yuv422p12", "yuv444p10", "yuv444p12"],
      wasmUrls: options.wasmUrls,
      workerUrls: options.workerUrls,
      onWorkerStartError: options.onWorkerStartError,
      idleCloseMs: options.idleCloseMs
    });
    if (lease instanceof Error) {
      throw lease;
    }
    this.lease = lease;
    this.decoder = lease.decoder;
  }

  async decode(packet: EncodedPacket): Promise<void> {
    const decoder = this.requireDecoder();
    while (decoder.desiredSize <= 0) {
      await decoder.dequeued;
    }

    const outcome = this.decodeSample(packet).then(
      (sample) => ({ sample, error: null }),
      (error: unknown) => ({ sample: null, error })
    );
    this.emissionTail = this.emissionTail
      .then(async () => {
        const result = await outcome;
        if (result.error) {
          throw result.error;
        }
        if (result.sample) {
          this.onSample(result.sample);
        }
      })
      .catch((error) => {
        this.onError(error);
      });
  }

  async flush(): Promise<void> {
    this.requireDecoder();
    // Every decode this instance queued settles through emissionTail.
    await this.emissionTail;
  }

  async close(): Promise<void> {
    const decoder = this.decoder;
    if (!decoder) {
      return;
    }

    await this.flush();
    // Back to the pool: the next Mediabunny decoder reuses it, or it closes.
    this.lease?.release();
    this.lease = null;
    this.decoder = null;
    for (const frame of this.framePool) {
      frame.clear();
    }
    this.framePool.length = 0;
  }

  private async decodeSample(packet: EncodedPacket): Promise<VideoSample> {
    const decoder = this.requireDecoder();
    const lease = this.lease;
    const frame = this.framePool.pop() ?? new Frame();
    try {
      const decoded = await decoder.decode(packet.data, frame);
      if (decoded instanceof Error) {
        throw decoded;
      }
      return createVideoSample(decoded, packet, this.config);
    } catch (error) {
      // A rejected decode (a crashed or failed worker surfaces here too) may
      // leave the decoder broken: never hand it to the next Mediabunny decoder.
      lease?.markFailed();
      throw error;
    } finally {
      this.framePool.push(frame);
    }
  }

  private requireDecoder(): Decoder {
    if (!this.decoder) {
      throw new Error("DNx Mediabunny decoder is not initialized.");
    }
    return this.decoder;
  }
}

function createVideoSample(
  frame: FilledFrame,
  packet: EncodedPacket,
  config: VideoDecoderConfig
): VideoSample {
  const frameData = contiguousFrameData(frame);
  const format = frame.pixelFormat === "yuv444p12"
    ? "I444P12"
    : frame.pixelFormat === "yuv444p10"
      ? "I444P10"
      : frame.pixelFormat === "yuv422p12"
        ? "I422P12"
    : frame.pixelFormat === "yuv422p10"
      ? "I422P10"
      : "I422";
  const colorSpace = config.colorSpace ?? colorSpaceForFrame(frame);
  const displayWidth = config.displayAspectWidth ?? frame.visibleWidth;
  const displayHeight = config.displayAspectHeight ?? frame.visibleHeight;

  if (typeof VideoFrame !== "undefined") {
    try {
      const videoFrame = frame.toVideoFrame({
        displayWidth,
        displayHeight,
        timestamp: packet.microsecondTimestamp,
        duration: packet.microsecondDuration || undefined,
        colorSpace
      });
      return new VideoSample(videoFrame, {
        timestamp: packet.timestamp,
        duration: packet.duration
      });
    } catch {
      // Mediabunny's raw VideoSample path supports I422 even when the host VideoFrame does not.
    }
  }

  return new VideoSample(frameData, {
    format,
    codedWidth: frame.codedWidth,
    codedHeight: frame.codedHeight,
    visibleRect: {
      left: 0,
      top: 0,
      width: frame.visibleWidth,
      height: frame.visibleHeight
    },
    displayWidth,
    displayHeight,
    timestamp: packet.timestamp,
    duration: packet.duration,
    colorSpace
  });
}

function contiguousFrameData(frame: FilledFrame): Uint8Array {
  const planes = frame.layout.planes;
  const first = planes[0]?.bytes;
  if (!first) {
    throw new Error("Decoded DNx frame has no output planes.");
  }

  const start = first.byteOffset;
  const byteLength = planes.reduce((sum, plane) => sum + plane.bytes.byteLength, 0);
  let expectedOffset = start;
  const isContiguous = planes.every((plane) => {
    const matches = plane.bytes.buffer === first.buffer && plane.bytes.byteOffset === expectedOffset;
    expectedOffset += plane.bytes.byteLength;
    return matches;
  });
  if (isContiguous) {
    return new Uint8Array(first.buffer, start, byteLength);
  }

  const result = new Uint8Array(byteLength);
  let offset = 0;
  for (const plane of planes) {
    result.set(plane.bytes, offset);
    offset += plane.bytes.byteLength;
  }
  return result;
}

function colorSpaceForFrame(frame: FilledFrame): VideoColorSpaceInit {
  const isBt2020 = frame.colorSpace === "bt2020-ncl" || frame.colorSpace === "bt2020-cl";
  return {
    primaries: isBt2020 ? "bt2020" : "bt709",
    transfer: "bt709",
    matrix: isBt2020 ? "bt2020-ncl" : "bt709",
    fullRange: false
  } as VideoColorSpaceInit;
}

function normalizeDnxFourCc(value: string): DnxFourCc | null {
  switch (value.toLowerCase()) {
    case "avdn":
      return "AVdn";
    case "avdh":
      return "AVdh";
    default:
      return null;
  }
}

const DNX_LOGGING_SHIM = Symbol.for("@wasm-codecs/dnx/mediabunny-logging-shim");

/**
 * Mediabunny 1.50.8 logs AVdn/AVdh as unsupported while parsing the QuickTime
 * sample description, before InputVideoTrack's recognition methods can be
 * augmented below. Keep the warning event intact for observers, but prevent
 * these two expected messages from reaching the console once DNx support has
 * been registered. All other Mediabunny warnings retain their normal behavior.
 */
function installDnxLoggingShim(): void {
  if ((VIDEO_CODECS as readonly string[]).includes("dnx")) {
    return;
  }

  const logging = Logging as typeof Logging & {
    [DNX_LOGGING_SHIM]?: boolean;
    _warn: (...args: unknown[]) => void;
  };
  if (logging[DNX_LOGGING_SHIM]) {
    return;
  }

  const warn = logging._warn;
  logging._warn = function (...args: unknown[]) {
    const message = args[0];
    const isRegisteredDnxWarning =
      typeof message === "string" &&
      /^Unsupported video codec \(sample entry type 'AVd[nh]'\)\.$/.test(message);
    if (!isRegisteredDnxWarning || Logging.level < LogLevel.Warnings) {
      warn.call(this, ...args);
      return;
    }

    const level = Logging.level;
    try {
      Logging.level = LogLevel.Errors;
      warn.call(this, ...args);
    } finally {
      Logging.level = level;
    }
  };
  logging[DNX_LOGGING_SHIM] = true;
}

function installDnxTrackShim(): void {
  if ((VIDEO_CODECS as readonly string[]).includes("dnx")) {
    return;
  }

  const prototype = InputVideoTrack.prototype as typeof InputVideoTrack.prototype & {
    [DNX_TRACK_SHIM]?: boolean;
  };
  if (prototype[DNX_TRACK_SHIM]) {
    return;
  }

  const getCodec = prototype.getCodec;
  const getDecoderConfig = prototype.getDecoderConfig;
  const getCodecParameterString = prototype.getCodecParameterString;
  const canDecode = prototype.canDecode;
  const hasOnlyKeyPackets = prototype.hasOnlyKeyPackets;
  const determinePacketType = prototype.determinePacketType;

  prototype.getCodec = async function () {
    const codec = await getCodec.call(this);
    return codec ?? (await getTrackDnxFourCc(this) ? "dnx" as VideoCodec : null);
  };
  prototype.getDecoderConfig = async function () {
    const config = await getDecoderConfig.call(this);
    if (config) {
      return config;
    }

    const dnxFourCc = await getTrackDnxFourCc(this);
    if (!dnxFourCc) {
      return null;
    }
    const [codedWidth, codedHeight, displayWidth, displayHeight, colorSpace] = await Promise.all([
      this.getCodedWidth(),
      this.getCodedHeight(),
      this.getDisplayWidth(),
      this.getDisplayHeight(),
      this.getColorSpace()
    ]);
    return {
      codec: dnxFourCc,
      codedWidth,
      codedHeight,
      displayAspectWidth: displayWidth,
      displayAspectHeight: displayHeight,
      colorSpace
    };
  };
  prototype.getCodecParameterString = async function () {
    return (await getTrackDnxFourCc(this)) ?? getCodecParameterString.call(this);
  };
  prototype.canDecode = async function () {
    const dnxFourCc = await getTrackDnxFourCc(this);
    if (!dnxFourCc) {
      return canDecode.call(this);
    }
    let decodability = trackDecodability.get(this);
    if (!decodability) {
      decodability = canDecodeDnxTrack(this);
      trackDecodability.set(this, decodability);
    }
    return decodability;
  };
  prototype.hasOnlyKeyPackets = async function () {
    return await getTrackDnxFourCc(this) ? true : hasOnlyKeyPackets.call(this);
  };
  prototype.determinePacketType = async function (packet) {
    return await getTrackDnxFourCc(this) ? "key" : determinePacketType.call(this, packet);
  };
  prototype[DNX_TRACK_SHIM] = true;
}

async function getTrackDnxFourCc(track: InputVideoTrack): Promise<DnxFourCc | null> {
  const internalCodecId = await track.getInternalCodecId();
  return typeof internalCodecId === "string" ? normalizeDnxFourCc(internalCodecId) : null;
}

async function canDecodeDnxTrack(track: InputVideoTrack): Promise<boolean> {
  const config = await track.getDecoderConfig();
  if (!config || !MediabunnyDnxDecoder.supports("dnx" as VideoCodec, config)) {
    return false;
  }

  const packet = await new EncodedPacketSink(track).getFirstPacket();
  const header = packet && parseDnxFrameHeader(packet.data);
  return Boolean(header?.supported && header.fourCc === normalizeDnxFourCc(config.codec));
}

let registered = false;

const REQUIRED_TRACK_SHIM_METHODS = [
  "getInternalCodecId",
  "getCodec",
  "getDecoderConfig",
  "getCodecParameterString",
  "canDecode",
  "hasOnlyKeyPackets",
  "determinePacketType",
  "getCodedWidth",
  "getCodedHeight",
  "getDisplayWidth",
  "getDisplayHeight",
  "getColorSpace"
] as const;

function assertMediabunnyCompatibility(): void {
  if ((VIDEO_CODECS as readonly string[]).includes("dnx")) {
    return;
  }
  const prototype = InputVideoTrack.prototype as unknown as Record<string, unknown>;
  const missing: string[] = REQUIRED_TRACK_SHIM_METHODS.filter((name) => typeof prototype[name] !== "function");
  const logging = Logging as typeof Logging & { _warn?: unknown };
  if (typeof logging._warn !== "function") {
    missing.push("Logging._warn");
  }
  if (missing.length > 0) {
    throw new Error(
      `Incompatible Mediabunny API: missing ${missing.join(", ")}. ` +
      "turbovc3 currently supports Mediabunny ^1.50.8; update turbovc3 or use a compatible Mediabunny release."
    );
  }
}

/**
 * Registers the DNxHD/DNxHR decoder for automatic use by Mediabunny. Call this before starting a decoding task.
 *
 * `options` choose the backend, the WebAssembly and worker URLs, a hook for
 * worker start failures and how long a released decoder idles. A later call
 * replaces them for decoders created from then on; with no options the
 * defaults apply, as before.
 */
export function registerDnxDecoder(options?: RegisterDnxDecoderOptions): void {
  if (options) {
    registeredOptions = { ...options };
  }
  if (registered) {
    return;
  }

  assertMediabunnyCompatibility();
  installDnxLoggingShim();
  installDnxTrackShim();
  registerDecoder(MediabunnyDnxDecoder);
  registered = true;
}
