export type DnxIdctMode = "wasm-idct" | "typescript-idct";

export interface DnxIdctKernel {
  readonly mode: DnxIdctMode;
  transform(coefficients: Int32Array, blockCount: number, bitDepth: 8 | 10 | 12): Uint16Array;
  destroy(): void;
}

interface DnxWasmExports {
  memory: WebAssembly.Memory;
  malloc?: (size: number) => number;
  _malloc?: (size: number) => number;
  free?: (pointer: number) => void;
  _free?: (pointer: number) => void;
  dnx_idct_i32_blocks?: (coefficients: number, samples: number, blockCount: number, bitDepth: number) => void;
  _dnx_idct_i32_blocks?: (coefficients: number, samples: number, blockCount: number, bitDepth: number) => void;
  dnx_idct_kernel_version?: () => number;
  _dnx_idct_kernel_version?: () => number;
}

interface DnxWasmFunctions {
  malloc(size: number): number;
  free(pointer: number): void;
  transform(coefficients: number, samples: number, blockCount: number, bitDepth: number): void;
}

const compiledModules = new Map<string, Promise<WebAssembly.Module>>();

/**
 * The WASM IDCT kernel, or the TypeScript one when it cannot load. `wasmUrl`
 * overrides where the module is fetched from (default `../wasm/generated/`).
 */
export async function createDnxIdctKernel(wasmUrl?: string | URL): Promise<DnxIdctKernel> {
  try {
    return await createDnxWasmIdctKernel(undefined, wasmUrl);
  } catch {
    return new DnxTypescriptIdctKernel();
  }
}

export async function createDnxWasmIdctKernel(
  wasmBytes?: BufferSource,
  wasmUrl?: string | URL
): Promise<DnxIdctKernel> {
  const module = wasmBytes ? await WebAssembly.compile(wasmBytes) : await loadCompiledModule(wasmUrl);
  const instance = await WebAssembly.instantiate(module, {
    env: {
      emscripten_notify_memory_growth() {}
    }
  });
  const exports = instance.exports as unknown as DnxWasmExports;
  const functions = readWasmFunctions(exports);
  const version = exports.dnx_idct_kernel_version ?? exports._dnx_idct_kernel_version;
  if (version && version() !== 1) {
    throw new Error(`Unsupported DNx IDCT kernel version ${version()}.`);
  }

  return new DnxWasmIdctKernel(exports.memory, functions);
}

export class DnxTypescriptIdctKernel implements DnxIdctKernel {
  readonly mode = "typescript-idct" as const;
  private readonly scratch = new Float64Array(64);
  private output = new Uint16Array(0);

  transform(coefficients: Int32Array, blockCount: number, bitDepth: 8 | 10 | 12): Uint16Array {
    validateTransformInput(coefficients, blockCount);
    const sampleCount = blockCount * 64;
    if (this.output.length < sampleCount) {
      this.output = new Uint16Array(sampleCount);
    }

    for (let block = 0; block < blockCount; block += 1) {
      inverseDctBlock(
        coefficients.subarray(block * 64, (block + 1) * 64),
        this.scratch,
        this.output.subarray(block * 64, (block + 1) * 64),
        bitDepth
      );
    }

    return this.output.subarray(0, sampleCount);
  }

  destroy(): void {}
}

class DnxWasmIdctKernel implements DnxIdctKernel {
  readonly mode = "wasm-idct" as const;
  private coefficientPointer = 0;
  private samplePointer = 0;
  private blockCapacity = 0;
  private destroyed = false;

  constructor(
    private readonly memory: WebAssembly.Memory,
    private readonly functions: DnxWasmFunctions
  ) {}

  transform(coefficients: Int32Array, blockCount: number, bitDepth: 8 | 10 | 12): Uint16Array {
    if (this.destroyed) {
      throw new Error("DNx WASM IDCT kernel is destroyed.");
    }
    validateTransformInput(coefficients, blockCount);
    this.ensureCapacity(blockCount);

    const coefficientCount = blockCount * 64;
    new Int32Array(this.memory.buffer, this.coefficientPointer, coefficientCount).set(
      coefficients.subarray(0, coefficientCount)
    );
    this.functions.transform(this.coefficientPointer, this.samplePointer, blockCount, bitDepth);
    return new Uint16Array(this.memory.buffer, this.samplePointer, coefficientCount);
  }

  destroy(): void {
    if (this.destroyed) {
      return;
    }

    this.destroyed = true;
    this.releaseBuffers();
  }

  private ensureCapacity(blockCount: number): void {
    if (blockCount <= this.blockCapacity) {
      return;
    }

    this.releaseBuffers();
    const coefficientBytes = blockCount * 64 * Int32Array.BYTES_PER_ELEMENT;
    const sampleBytes = blockCount * 64 * Uint16Array.BYTES_PER_ELEMENT;
    this.coefficientPointer = this.functions.malloc(coefficientBytes);
    this.samplePointer = this.functions.malloc(sampleBytes);
    if (!this.coefficientPointer || !this.samplePointer) {
      this.releaseBuffers();
      throw new Error("DNx WASM IDCT kernel could not allocate row buffers.");
    }
    this.blockCapacity = blockCount;
  }

  private releaseBuffers(): void {
    if (this.samplePointer) {
      this.functions.free(this.samplePointer);
    }
    if (this.coefficientPointer) {
      this.functions.free(this.coefficientPointer);
    }
    this.samplePointer = 0;
    this.coefficientPointer = 0;
    this.blockCapacity = 0;
  }
}

async function loadCompiledModule(wasmUrl?: string | URL): Promise<WebAssembly.Module> {
  // Resolved on use, not at import: a bundle without a URL base must still load.
  const defaultUrl = new URL("../wasm/generated/dnx_idct_kernel.wasm", import.meta.url);
  const url = wasmUrl === undefined ? defaultUrl : new URL(wasmUrl, defaultUrl);
  let compiled = compiledModules.get(url.href);
  if (!compiled) {
    compiled = fetch(url).then(async (response) => {
      if (!response.ok) {
        throw new Error(`DNx WASM IDCT kernel request failed with HTTP ${response.status}.`);
      }
      return WebAssembly.compile(await response.arrayBuffer());
    });
    compiled.catch(() => compiledModules.delete(url.href));
    compiledModules.set(url.href, compiled);
  }
  return compiled;
}

function readWasmFunctions(exports: DnxWasmExports): DnxWasmFunctions {
  const malloc = exports.malloc ?? exports._malloc;
  const free = exports.free ?? exports._free;
  const transform = exports.dnx_idct_i32_blocks ?? exports._dnx_idct_i32_blocks;
  if (!exports.memory || !malloc || !free || !transform) {
    throw new Error("DNx WASM IDCT kernel is missing memory, malloc, free, or transform exports.");
  }
  return { malloc, free, transform };
}

function validateTransformInput(coefficients: Int32Array, blockCount: number): void {
  if (!Number.isInteger(blockCount) || blockCount <= 0 || coefficients.length < blockCount * 64) {
    throw new Error("DNx IDCT input does not contain the requested block count.");
  }
}

const IDCT_BASIS = Array.from({ length: 8 }, (_, x) =>
  Array.from(
    { length: 8 },
    (_unused, coefficient) =>
      (coefficient === 0 ? Math.SQRT1_2 : 1) * Math.cos(((2 * x + 1) * coefficient * Math.PI) / 16)
  )
);

function inverseDctBlock(
  coefficients: Int32Array,
  scratch: Float64Array,
  output: Uint16Array,
  bitDepth: 8 | 10 | 12
): void {
  for (let v = 0; v < 8; v += 1) {
    const rowOffset = v * 8;
    for (let x = 0; x < 8; x += 1) {
      let sum = 0;
      for (let u = 0; u < 8; u += 1) {
        sum += coefficients[rowOffset + u] * IDCT_BASIS[x][u];
      }
      scratch[rowOffset + x] = sum;
    }
  }

  const maximum = (1 << bitDepth) - 1;
  for (let y = 0; y < 8; y += 1) {
    for (let x = 0; x < 8; x += 1) {
      let sum = 0;
      for (let v = 0; v < 8; v += 1) {
        sum += scratch[v * 8 + x] * IDCT_BASIS[y][v];
      }
      output[y * 8 + x] = Math.min(maximum, Math.max(0, Math.round(sum / 4)));
    }
  }
}
