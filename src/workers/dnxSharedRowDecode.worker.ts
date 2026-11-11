import { createDnxFrameLayout } from "../dnxReconstruction.js";
import { getDnxRowTableSet, putDnxDecodedRow } from "../dnxScalarDecoder.js";
import { createDnxZigRowDecoder, type DnxRowDecoder } from "../dnxZigRowDecoder.js";
import type {
  DnxSharedRowWorkerRequest,
  DnxSharedRowWorkerResponse
} from "../dnxSharedRowWorkerProtocol.js";

let decoder: DnxRowDecoder | null = null;
const workerScope = globalThis as unknown as {
  onmessage: ((event: MessageEvent<DnxSharedRowWorkerRequest>) => void) | null;
  postMessage(message: DnxSharedRowWorkerResponse): void;
};

workerScope.onmessage = (event) => {
  void handleRequest(event.data);
};

async function handleRequest(request: DnxSharedRowWorkerRequest): Promise<void> {
  if (request.type === "init") {
    decoder = await createDnxZigRowDecoder(request.rowDecoderWasmUrl);
    if (!decoder) {
      post({ type: "error", message: "The Zig/WASM DNx row decoder could not be initialized." });
      return;
    }
    post({ type: "ready", mode: decoder.mode });
    return;
  }

  if (request.type === "close") {
    decoder?.destroy();
    decoder = null;
    return;
  }

  if (!decoder) {
    post({ type: "error", requestId: request.requestId, message: "DNx shared row worker is not initialized." });
    return;
  }

  try {
    const tables = getDnxRowTableSet(request.header.cid, request.header.bitDepth, request.header.is444);
    if (!tables) {
      throw new Error(`No progressive row tables exist for DNx CID ${request.header.cid}.`);
    }
    const rowBytes = new Uint8Array(
      request.packet,
      request.rowStart,
      request.rowEnd - request.rowStart
    );
    const samples = decoder.decodeRow(
      rowBytes,
      request.header.macroblockWidth,
      request.header.bitDepth,
      request.header.is444,
      tables
    );
    const layout = createDnxFrameLayout(request.header, request.frame);
    putDnxDecodedRow(
      layout,
      request.row,
      request.header.macroblockWidth,
      request.header.is444,
      samples
    );
    post({ type: "decoded-row", requestId: request.requestId });
  } catch (error) {
    post({
      type: "error",
      requestId: request.requestId,
      message: error instanceof Error ? error.message : String(error)
    });
  }
}

function post(response: DnxSharedRowWorkerResponse): void {
  workerScope.postMessage(response);
}
