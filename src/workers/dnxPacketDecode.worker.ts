import { Decoder, Frame } from "../dnxDecoder.js";
import type {
  DnxPacketWorkerRequest,
  DnxPacketWorkerResponse,
  DnxWorkerFrameContents
} from "../dnxDecoderWorkerProtocol.js";

let decoder: Decoder | null = null;
const workerScope = globalThis as unknown as {
  onmessage: ((event: MessageEvent<DnxPacketWorkerRequest>) => void) | null;
  postMessage(message: DnxPacketWorkerResponse, transfer: Transferable[]): void;
};

workerScope.onmessage = (event) => {
  void handleRequest(event.data);
};

async function handleRequest(request: DnxPacketWorkerRequest): Promise<void> {
  if (request.type === "init") {
    const created = await Decoder.create({
      dnxFourCc: request.dnxFourCc,
      allowedOutputFormats: request.allowedOutputFormats,
      useSharedMemory: false,
      concurrency: 0,
      wasmUrls: request.wasmUrls
    });
    if (created instanceof Error) {
      post({ type: "error", message: created.message });
      return;
    }
    decoder = created;
    post({ type: "ready", mode: decoder.idctMode });
    return;
  }

  if (request.type === "close") {
    await decoder?.close();
    decoder = null;
    return;
  }

  if (!decoder) {
    post({ type: "error", requestId: request.requestId, message: "DNx packet worker is not initialized." });
    return;
  }

  const frame = new Frame();
  try {
    const result = await decoder.decode(new Uint8Array(request.packet), frame);
    if (result instanceof Error) {
      post({
        type: "error",
        requestId: request.requestId,
        errorName: result.name,
        message: result.message
      });
      return;
    }
    const contents: DnxWorkerFrameContents = {
      codedWidth: result.codedWidth,
      codedHeight: result.codedHeight,
      visibleWidth: result.visibleWidth,
      visibleHeight: result.visibleHeight,
      pixelFormat: result.pixelFormat,
      originalPixelFormat: result.originalPixelFormat,
      colorSpace: result.colorSpace,
      header: result.header,
      layout: result.layout
    };
    const response: DnxPacketWorkerResponse = {
      type: "decoded",
      requestId: request.requestId,
      mode: decoder.idctMode,
      frame: contents
    };
    const transfers = result.layout.planes
      .map((plane) => plane.bytes.buffer)
      .filter((buffer): buffer is ArrayBuffer => buffer instanceof ArrayBuffer);
    workerScope.postMessage(response, [...new Set(transfers)]);
  } catch (error) {
    post({
      type: "error",
      requestId: request.requestId,
      errorName: error instanceof Error ? error.name : undefined,
      message: error instanceof Error ? error.message : String(error)
    });
  }
}

function post(response: DnxPacketWorkerResponse): void {
  workerScope.postMessage(response, []);
}
