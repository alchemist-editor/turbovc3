import type { DecodeColorSpace, DecodePixelFormat } from "./core/codec.js";

export const DNX_SAMPLE_ENTRIES = ["AVdn", "AVdh"] as const;

/**
 * The widest frame turbovc3 decodes: 8K DCI, 512 macroblocks. The Zig/WASM
 * decoder's row and frame buffers are sized for it.
 */
export const DNX_MAX_DECODE_WIDTH = 8192;

/** The tallest frame turbovc3 decodes: 8K, 270 macroblock rows. */
export const DNX_MAX_DECODE_HEIGHT = 4320;
export type DnxFourCc = (typeof DNX_SAMPLE_ENTRIES)[number];

export type DnxProfile =
  | "dnxhd"
  | "dnxhr_lb"
  | "dnxhr_sq"
  | "dnxhr_hq"
  | "dnxhr_hqx"
  | "dnxhr_444";

export interface DnxCidEntry {
  cid: number;
  profile: DnxProfile;
  width: number | null;
  height: number | null;
  frameSize: number | null;
  codingUnitSize: number | null;
  bitDepth: 8 | 10 | 12 | null;
  flags: readonly DnxCidFlag[];
  packetScale?: {
    numerator: number;
    denominator: number;
  };
}

export type DnxCidFlag = "interlaced" | "mbaff" | "444";

export interface DnxHeaderPrefix {
  kind: "classic" | "hr";
  dataOffset: number | null;
}

export interface DnxFrameHeader {
  fourCc: DnxFourCc;
  prefix: DnxHeaderPrefix;
  cid: number;
  profile: DnxProfile | "unknown";
  width: number;
  encodedWidth: number;
  height: number;
  bitDepth: 8 | 10 | 12;
  is444: boolean;
  adaptiveColorTransform: boolean;
  alpha: boolean;
  lowLatencyAlpha: boolean;
  mbaff: boolean;
  interlaced: boolean;
  fieldHeight: number;
  fieldParity: "top" | "bottom" | null;
  colorSpace: "bt709" | "bt2020-ncl" | "bt2020-cl" | "unspecified";
  macroblockWidth: number;
  macroblockHeight: number;
  dataOffset: number;
  expectedFrameSize: number | null;
  codingUnitSize: number | null;
  pixelFormat: DecodePixelFormat;
  pixelAspectRatio: { num: number; den: number };
  supported: boolean;
  unsupportedReasons: readonly string[];
}

export type DnxScanType =
  | "progressive"
  | "interlaced-top-field-first"
  | "interlaced-bottom-field-first";

export interface DnxFrameMetadata {
  pixelAspectRatio: { num: number; den: number };
  colorPrimaries: number;
  colorTransfer: number;
  colorMatrix: number;
  colorRangeFull: false;
  scanType: DnxScanType;
}

export interface DnxFramePacket {
  offset: number;
  bytes: Uint8Array;
  header: DnxFrameHeader;
}

const DNXHD_INTERLACED = "interlaced" as const;
const DNXHD_MBAFF = "mbaff" as const;
const DNXHD_444 = "444" as const;

const DNX_CID_TABLE: readonly DnxCidEntry[] = [
  cid(1235, "dnxhd", 1920, 1080, 917504, 917504, 10, []),
  cid(1237, "dnxhd", 1920, 1080, 606208, 606208, 8, []),
  cid(1238, "dnxhd", 1920, 1080, 917504, 917504, 8, []),
  cid(1241, "dnxhd", 1920, 1080, 917504, 458752, 10, [DNXHD_INTERLACED]),
  cid(1242, "dnxhd", 1920, 1080, 606208, 303104, 8, [DNXHD_INTERLACED]),
  cid(1243, "dnxhd", 1920, 1080, 917504, 458752, 8, [DNXHD_INTERLACED]),
  cid(1244, "dnxhd", 1440, 1080, 606208, 303104, 8, [DNXHD_INTERLACED]),
  cid(1250, "dnxhd", 1280, 720, 458752, 458752, 10, []),
  cid(1251, "dnxhd", 1280, 720, 458752, 458752, 8, []),
  cid(1252, "dnxhd", 1280, 720, 303104, 303104, 8, []),
  cid(1253, "dnxhd", 1920, 1080, 188416, 188416, 8, []),
  cid(1256, "dnxhd", 1920, 1080, 1835008, 1835008, 10, [DNXHD_444]),
  cid(1258, "dnxhd", 960, 720, 212992, 212992, 8, []),
  cid(1259, "dnxhd", 1440, 1080, 417792, 417792, 8, []),
  cid(1260, "dnxhd", 1440, 1080, 835584, 417792, 8, [DNXHD_INTERLACED, DNXHD_MBAFF]),
  cid(1270, "dnxhr_444", null, null, null, null, null, [DNXHD_444], { numerator: 57344, denominator: 255 }),
  cid(1271, "dnxhr_hqx", null, null, null, null, null, [], { numerator: 28672, denominator: 255 }),
  cid(1272, "dnxhr_hq", null, null, null, null, 8, [], { numerator: 28672, denominator: 255 }),
  cid(1273, "dnxhr_sq", null, null, null, null, 8, [], { numerator: 18944, denominator: 255 }),
  cid(1274, "dnxhr_lb", null, null, null, null, 8, [], { numerator: 5888, denominator: 255 })
];

export function getDnxCidEntry(cidValue: number): DnxCidEntry | null {
  return DNX_CID_TABLE.find((entry) => entry.cid === cidValue) ?? null;
}

export function parseDnxFrameHeader(
  packet: Uint8Array,
  options: { declaredPacketLength?: number } = {}
): DnxFrameHeader | null {
  if (packet.length < 0x280) {
    return null;
  }

  const prefix = parseDnxHeaderPrefix(packet);
  if (!prefix) {
    return null;
  }

  const fieldHeight = readU16BE(packet, 0x18);
  const encodedWidth = readU16BE(packet, 0x1a);
  const bitDepth = parseBitDepth(packet[0x21] >> 5);
  if (!bitDepth || encodedWidth <= 0 || fieldHeight <= 0) {
    return null;
  }

  const cidValue = readU32BE(packet, 0x28);
  const cidEntry = getDnxCidEntry(cidValue);
  const width = cidEntry?.width ?? encodedWidth;
  const is444 = ((packet[0x2c] >> 6) & 1) === 1;
  const macroblockWidth = Math.ceil(width / 16);
  const macroblockHeight = readU16BE(packet, 0x16c);
  const dataOffset =
    prefix.kind === "hr" && macroblockHeight > 68
      ? 0x170 + (macroblockHeight << 2)
      : 0x280;

  const interlaced = (packet[5] & 2) !== 0;
  const height = interlaced && cidEntry?.height !== null && cidEntry?.height !== undefined
    ? cidEntry.height
    : fieldHeight;
  const mbaff = ((packet[0x06] >> 5) & 1) === 1;
  const expectedFrameSize = cidEntry
    ? mbaff
      ? cidEntry.codingUnitSize
      : expectedDnxFrameSize(cidEntry, width, height)
    : null;
  const aspectDivisor = greatestCommonDivisor(encodedWidth, width);
  const pixelAspectRatio = { num: encodedWidth / aspectDivisor, den: width / aspectDivisor };
  const alpha = (packet[0x07] & 1) === 1;
  const lowLatencyAlpha = ((packet[0x07] >> 1) & 1) === 1;
  const adaptiveColorTransform = (packet[0x2c] & 1) === 1;
  const pixelFormat = pixelFormatFor({ bitDepth, is444, adaptiveColorTransform });
  const unsupportedReasons = unsupportedReasonsFor({
    alpha,
    bitDepth,
    cidEntry,
    expectedFrameSize,
    height,
    interlaced,
    is444,
    lowLatencyAlpha,
    macroblockHeight,
    mbaff,
    packetLength: options.declaredPacketLength ?? packet.length,
    pixelFormat,
    width
  });

  return {
    fourCc: cidValue >= 1270 && cidValue <= 1274 ? "AVdh" : "AVdn",
    prefix,
    cid: cidValue,
    profile: cidEntry?.profile ?? "unknown",
    width,
    encodedWidth,
    height,
    bitDepth,
    is444,
    adaptiveColorTransform,
    alpha,
    lowLatencyAlpha,
    mbaff,
    interlaced,
    fieldHeight,
    fieldParity: interlaced ? ((packet[5] & 1) === 0 ? "top" : "bottom") : null,
    colorSpace: colorSpaceFor((packet[0x2c] >> 1) & 3),
    macroblockWidth,
    macroblockHeight,
    dataOffset,
    expectedFrameSize,
    codingUnitSize: cidEntry?.codingUnitSize ?? null,
    pixelFormat,
    pixelAspectRatio,
    supported: unsupportedReasons.length === 0,
    unsupportedReasons
  };
}

export function findDnxFrameHeader(
  bytes: Uint8Array,
  options: { start?: number; limit?: number } = {}
): { offset: number; header: DnxFrameHeader } | null {
  const start = Math.max(0, options.start ?? 0);
  const limit = Math.min(bytes.length, options.limit ?? bytes.length);
  const maxOffset = limit - 0x280;

  for (let offset = start; offset <= maxOffset; offset += 1) {
    const header = parseDnxFrameHeader(bytes.subarray(offset));
    if (header) {
      return { offset, header };
    }
  }

  return null;
}

export function findDnxFramePackets(
  bytes: Uint8Array,
  options: { start?: number; limit?: number; maxFrames?: number } = {}
): DnxFramePacket[] {
  const packets: DnxFramePacket[] = [];
  const start = Math.max(0, options.start ?? 0);
  const limit = Math.min(bytes.length, options.limit ?? bytes.length);
  const maxFrames = options.maxFrames ?? Infinity;

  for (let offset = start; offset <= limit - 0x280 && packets.length < maxFrames;) {
    const header = parseDnxFrameHeader(bytes.subarray(offset, limit));
    if (!header || !header.expectedFrameSize || offset + header.expectedFrameSize > limit) {
      offset += 1;
      continue;
    }

    packets.push({
      offset,
      bytes: bytes.subarray(offset, offset + header.expectedFrameSize),
      header
    });
    offset += header.expectedFrameSize;
  }

  return packets;
}

export function summarizeDnxFrameHeader(header: DnxFrameHeader): string {
  return `${header.profile} CID ${header.cid} ${header.width}x${header.height} ${header.bitDepth}-bit ${header.is444 ? "4:4:4" : "4:2:2"}`;
}

export function dnxColorSpaceForHeader(header: DnxFrameHeader): DecodeColorSpace {
  const isBt2020 = header.colorSpace === "bt2020-ncl" || header.colorSpace === "bt2020-cl";
  return {
    primaries: isBt2020 ? "bt2020" : header.colorSpace === "unspecified" ? "unspecified" : "bt709",
    transfer: isBt2020 ? "unspecified" : header.colorSpace === "unspecified" ? "unspecified" : "bt709",
    matrix: header.colorSpace,
    fullRange: false
  };
}

export function dnxFrameMetadataForHeader(header: DnxFrameHeader): DnxFrameMetadata {
  const unspecified = header.colorSpace === "unspecified";
  const bt2020 = header.colorSpace === "bt2020-ncl" || header.colorSpace === "bt2020-cl";
  return {
    pixelAspectRatio: header.pixelAspectRatio ?? { num: 1, den: 1 },
    colorPrimaries: unspecified ? 2 : bt2020 ? 9 : 1,
    colorTransfer: unspecified || bt2020 ? 2 : 1,
    colorMatrix: unspecified ? 2 : header.colorSpace === "bt2020-ncl" ? 9 : header.colorSpace === "bt2020-cl" ? 10 : 1,
    colorRangeFull: false,
    scanType: header.interlaced
      ? header.fieldParity === "bottom"
        ? "interlaced-bottom-field-first"
        : "interlaced-top-field-first"
      : "progressive"
  };
}

function cid(
  cidValue: number,
  profile: DnxProfile,
  width: number | null,
  height: number | null,
  frameSize: number | null,
  codingUnitSize: number | null,
  bitDepth: 8 | 10 | 12 | null,
  flags: readonly DnxCidFlag[],
  packetScale?: { numerator: number; denominator: number }
): DnxCidEntry {
  return {
    cid: cidValue,
    profile,
    width,
    height,
    frameSize,
    codingUnitSize,
    bitDepth,
    flags,
    packetScale
  };
}

function parseDnxHeaderPrefix(bytes: Uint8Array): DnxHeaderPrefix | null {
  if (bytes.length < 5) {
    return null;
  }

  if (bytes[0] === 0 && bytes[1] === 0 && bytes[2] === 0x02 && bytes[3] === 0x80) {
    if (bytes[4] === 0x01 || bytes[4] === 0x02) {
      return { kind: "classic", dataOffset: null };
    }
  }

  const dataOffset = readU32BE(bytes, 0);
  if (bytes[0] === 0 && bytes[1] === 0 && bytes[4] === 0x03 && dataOffset >= 0x0280 && dataOffset <= 0x2170 && dataOffset % 4 === 0) {
    return { kind: "hr", dataOffset };
  }

  return null;
}

function expectedDnxFrameSize(entry: DnxCidEntry, width: number, height: number): number | null {
  if (entry.frameSize !== null) {
    return entry.frameSize;
  }

  if (!entry.packetScale) {
    return null;
  }

  const macroblockCount = Math.ceil(width / 16) * Math.ceil(height / 16);
  const unaligned = Math.trunc(
    (macroblockCount * entry.packetScale.numerator) / entry.packetScale.denominator
  );
  return Math.trunc((unaligned + 2048) / 4096) * 4096;
}

function unsupportedReasonsFor(options: {
  alpha: boolean;
  bitDepth: 8 | 10 | 12;
  cidEntry: DnxCidEntry | null;
  expectedFrameSize: number | null;
  height: number;
  interlaced: boolean;
  is444: boolean;
  lowLatencyAlpha: boolean;
  macroblockHeight: number;
  mbaff: boolean;
  packetLength: number;
  pixelFormat: DecodePixelFormat;
  width: number;
}): string[] {
  const reasons: string[] = [];

  if (!options.cidEntry) {
    reasons.push("Unknown or unsupported DNx CID.");
  }
  if (options.cidEntry) {
    const profileIsInterlaced = options.cidEntry.flags.includes(DNXHD_INTERLACED);
    const profileAllowsMbaff = options.cidEntry.flags.includes(DNXHD_MBAFF);
    if (options.mbaff && !profileAllowsMbaff) {
      reasons.push(`CID ${options.cidEntry.cid} does not permit MBAFF coding.`);
    }
    if (options.interlaced !== (profileIsInterlaced && !options.mbaff)) {
      reasons.push(
        options.interlaced
          ? `CID ${options.cidEntry.cid} does not permit interlaced coding.`
          : `CID ${options.cidEntry.cid} requires interlaced coding.`
      );
    }
  }
  if (options.width > DNX_MAX_DECODE_WIDTH || options.height > DNX_MAX_DECODE_HEIGHT) {
    reasons.push(`DNx decode is limited to ${DNX_MAX_DECODE_WIDTH}x${DNX_MAX_DECODE_HEIGHT} frames.`);
  }
  if (options.alpha || options.lowLatencyAlpha) {
    reasons.push("DNx alpha output is deferred.");
  }
  if (options.macroblockHeight <= 0) {
    reasons.push("Invalid DNx macroblock height.");
  }
  if (
    options.pixelFormat !== "yuv422p8" &&
    options.pixelFormat !== "yuv422p10" &&
    options.pixelFormat !== "yuv422p12" &&
    options.pixelFormat !== "yuv444p10" &&
    options.pixelFormat !== "yuv444p12" &&
    options.pixelFormat !== "gbrp10" &&
    options.pixelFormat !== "gbrp12"
  ) {
    reasons.push(`Pixel format ${options.pixelFormat} is not in v1 scope.`);
  }
  if (options.expectedFrameSize !== null && options.packetLength < options.expectedFrameSize) {
    reasons.push(`Packet is smaller than the expected frame size (${options.packetLength} < ${options.expectedFrameSize}).`);
  }

  return reasons;
}

function greatestCommonDivisor(left: number, right: number): number {
  let a = Math.abs(left);
  let b = Math.abs(right);
  while (b !== 0) {
    const remainder = a % b;
    a = b;
    b = remainder;
  }
  return a || 1;
}

function pixelFormatFor(options: {
  bitDepth: 8 | 10 | 12;
  is444: boolean;
  adaptiveColorTransform: boolean;
}): DecodePixelFormat {
  if (options.is444) {
    if (options.bitDepth === 10 || options.bitDepth === 12) {
      return options.adaptiveColorTransform ? `yuv444p${options.bitDepth}` : `gbrp${options.bitDepth}`;
    }
    return "unknown";
  }

  if (options.bitDepth === 8) {
    return "yuv422p8";
  }
  if (options.bitDepth === 10) {
    return "yuv422p10";
  }
  return "yuv422p12";
}

function parseBitDepth(indicator: number): 8 | 10 | 12 | null {
  switch (indicator) {
    case 1:
      return 8;
    case 2:
      return 10;
    case 3:
      return 12;
    default:
      return null;
  }
}

function colorSpaceFor(code: number): DnxFrameHeader["colorSpace"] {
  switch (code) {
    case 0:
      return "bt709";
    case 1:
      return "bt2020-ncl";
    case 2:
      return "bt2020-cl";
    default:
      return "unspecified";
  }
}

function readU16BE(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function readU32BE(bytes: Uint8Array, offset: number): number {
  return (
    bytes[offset] * 2 ** 24 +
    (bytes[offset + 1] << 16) +
    (bytes[offset + 2] << 8) +
    bytes[offset + 3]
  );
}
