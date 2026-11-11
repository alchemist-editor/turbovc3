import type { DnxFourCc, DnxFrameHeader } from "./dnxFrame.js";
import type { DnxPixelFormat } from "./dnxDecoder.js";
import type { DnxFrameLayout } from "./dnxReconstruction.js";

export interface DnxPacketWorkerInitRequest {
  type: "init";
  dnxFourCc: DnxFourCc;
  allowedOutputFormats: readonly DnxPixelFormat[];
  /** Absolute URLs of the WebAssembly modules; the worker's defaults when absent. */
  wasmUrls?: { rowDecoder?: string; idctKernel?: string };
}

export interface DnxPacketWorkerDecodeRequest {
  type: "decode";
  requestId: number;
  packet: ArrayBuffer;
}

export interface DnxPacketWorkerCloseRequest {
  type: "close";
}

export type DnxPacketWorkerRequest =
  | DnxPacketWorkerInitRequest
  | DnxPacketWorkerDecodeRequest
  | DnxPacketWorkerCloseRequest;

export interface DnxWorkerFrameContents {
  codedWidth: number;
  codedHeight: number;
  visibleWidth: number;
  visibleHeight: number;
  pixelFormat: DnxPixelFormat;
  originalPixelFormat: DnxPixelFormat;
  colorSpace: DnxFrameHeader["colorSpace"];
  header: DnxFrameHeader;
  layout: DnxFrameLayout;
}

export type DnxPacketWorkerResponse =
  | {
      type: "ready";
      mode: string;
    }
  | {
      type: "decoded";
      requestId: number;
      mode: string;
      frame: DnxWorkerFrameContents;
    }
  | {
      type: "error";
      requestId?: number;
      errorName?: string;
      message: string;
    };
