import type { DnxFrameHeader } from "./dnxFrame.js";

export type DnxSharedRowWorkerRequest =
  | {
      type: "init";
      /** Absolute URL of dnx_row_decoder.wasm; the worker's default when absent. */
      rowDecoderWasmUrl?: string;
    }
  | {
      type: "decode-row";
      requestId: number;
      packet: SharedArrayBuffer;
      frame: SharedArrayBuffer;
      rowStart: number;
      rowEnd: number;
      row: number;
      header: DnxFrameHeader;
    }
  | { type: "close" };

export type DnxSharedRowWorkerResponse =
  | { type: "ready"; mode: string }
  | { type: "decoded-row"; requestId: number }
  | { type: "error"; requestId?: number; message: string };
