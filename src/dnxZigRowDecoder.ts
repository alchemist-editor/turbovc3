export interface DnxRowHuffmanTable {
  lookup: Int32Array;
  zigLookup: Uint16Array;
}

export interface DnxRowTableSet {
  dcTable: DnxRowHuffmanTable;
  acTable: DnxRowHuffmanTable;
  runTable: DnxRowHuffmanTable;
  acInfo: readonly number[];
  run: readonly number[];
  eobIndex: number;
  indexBits: number;
  levelBias: number;
  levelShift: number;
  lumaWeight: readonly number[];
  chromaWeight: readonly number[];
}

export interface DnxRowDecoder {
  readonly mode: "zig-wasm-frame";
  readonly capacities: DnxNativeCapacities;
  decodeFrame(
    packet: Uint8Array,
    rows: readonly DnxRowSpanInput[],
    macroblockWidth: number,
    macroblockHeight: number,
    bitDepth: 8 | 10 | 12,
    is444: boolean,
    mbaff: boolean,
    tables: DnxRowTableSet
  ): Uint8Array;
  decodeRow(
    rowBytes: Uint8Array,
    macroblockWidth: number,
    bitDepth: 8 | 10 | 12,
    is444: boolean,
    tables: DnxRowTableSet
  ): Uint16Array;
  destroy(): void;
}

export interface DnxNativeCapacities {
  rowBytes: number;
  packetBytes: number;
  frameBytes: number;
  macroblocksPerRow: number;
  rows: number;
}

export interface DnxRowSpanInput {
  start: number;
  end: number;
}

interface DnxZigWasmExports {
  memory: WebAssembly.Memory;
  dnx_row_decoder_version: () => number;
  dnx_row_capacity: () => number;
  dnx_macroblock_capacity: () => number;
  dnx_rows_capacity: () => number;
  dnx_row_buffer_ptr: () => number;
  dnx_packet_capacity: () => number;
  dnx_packet_buffer_ptr: () => number;
  dnx_row_starts_ptr: () => number;
  dnx_row_ends_ptr: () => number;
  dnx_frame_capacity: () => number;
  dnx_frame_buffer_ptr: () => number;
  dnx_dc_lookup_ptr: () => number;
  dnx_ac_lookup_ptr: () => number;
  dnx_run_lookup_ptr: () => number;
  dnx_ac_info_ptr: () => number;
  dnx_run_values_ptr: () => number;
  dnx_luma_weight_ptr: () => number;
  dnx_chroma_weight_ptr: () => number;
  dnx_samples_ptr: () => number;
  dnx_diagnostic_stage: () => number;
  dnx_diagnostic_row: () => number;
  dnx_diagnostic_macroblock: () => number;
  dnx_diagnostic_block: () => number;
  dnx_diagnostic_bit_offset: () => number;
  dnx_decode_row: (
    rowLength: number,
    macroblockWidth: number,
    bitDepth: number,
    acInfoLength: number,
    runValuesLength: number,
    eobIndex: number,
    indexBits: number,
    levelBias: number,
    levelShift: number,
    is444: number
  ) => number;
  dnx_decode_frame: (
    packetLength: number,
    macroblockWidth: number,
    macroblockHeight: number,
    bitDepth: number,
    acInfoLength: number,
    runValuesLength: number,
    eobIndex: number,
    indexBits: number,
    levelBias: number,
    levelShift: number,
    is444: number,
    mbaff: number
  ) => number;
}

const HUFFMAN_LOOKUP_SIZE = 1 << 16;
const BLOCKS_PER_MACROBLOCK_422 = 8;
const BLOCKS_PER_MACROBLOCK_444 = 12;
const SAMPLES_PER_BLOCK = 64;
const ERROR_MESSAGES = [
  "ok",
  "invalid arguments",
  "unexpected end of macroblock header",
  "ACT macroblocks are unsupported",
  "invalid DC VLC",
  "unexpected end of DC delta",
  "unexpected end of AC sign",
  "unexpected end of AC level",
  "invalid run VLC",
  "AC coefficients overran the block",
  "invalid AC VLC"
] as const;

const compiledModules = new Map<string, Promise<WebAssembly.Module>>();

/**
 * The Zig/WASM row decoder, or null when it cannot load. `wasmUrl` overrides
 * where the module is fetched from (default `../wasm/generated/` beside dist).
 */
export async function createDnxZigRowDecoder(wasmUrl?: string | URL): Promise<DnxRowDecoder | null> {
  try {
    return await createDnxWasmRowDecoder(undefined, wasmUrl);
  } catch {
    return null;
  }
}

export async function createDnxWasmRowDecoder(
  wasmBytes?: BufferSource,
  wasmUrl?: string | URL
): Promise<DnxRowDecoder> {
  const module = wasmBytes ? await WebAssembly.compile(wasmBytes) : await loadCompiledModule(wasmUrl);
  const instance = await WebAssembly.instantiate(module, {});
  const exports = instance.exports as unknown as DnxZigWasmExports;
  validateExports(exports);
  if (exports.dnx_row_decoder_version() !== 4) {
    throw new Error(`Unsupported DNx Zig row decoder version ${exports.dnx_row_decoder_version()}.`);
  }

  return new DnxZigWasmRowDecoder(exports);
}

class DnxZigWasmRowDecoder implements DnxRowDecoder {
  readonly mode = "zig-wasm-frame" as const;
  readonly capacities: DnxNativeCapacities;
  private configuredTables: DnxRowTableSet | null = null;
  private destroyed = false;

  constructor(private readonly exports: DnxZigWasmExports) {
    this.capacities = Object.freeze({
      rowBytes: exports.dnx_row_capacity(),
      packetBytes: exports.dnx_packet_capacity(),
      frameBytes: exports.dnx_frame_capacity(),
      macroblocksPerRow: exports.dnx_macroblock_capacity(),
      rows: exports.dnx_rows_capacity()
    });
  }

  decodeFrame(
    packet: Uint8Array,
    rows: readonly DnxRowSpanInput[],
    macroblockWidth: number,
    macroblockHeight: number,
    bitDepth: 8 | 10 | 12,
    is444: boolean,
    mbaff: boolean,
    tables: DnxRowTableSet
  ): Uint8Array {
    if (this.destroyed) {
      throw new Error("DNx Zig row decoder is destroyed.");
    }
    if (packet.byteLength > this.capacities.packetBytes) {
      throw new Error(`DNx packet requires ${packet.byteLength} bytes, exceeding the Zig buffer capacity.`);
    }
    if (rows.length !== macroblockHeight) {
      throw new Error(`DNx frame requires ${macroblockHeight} row spans, got ${rows.length}.`);
    }
    if (
      !Number.isInteger(macroblockWidth) ||
      macroblockWidth < 1 ||
      macroblockWidth > this.capacities.macroblocksPerRow
    ) {
      throw new Error(
        `DNx frame macroblock width ${macroblockWidth} exceeds the Zig capacity of ${this.capacities.macroblocksPerRow}.`
      );
    }
    if (
      !Number.isInteger(macroblockHeight) ||
      macroblockHeight < 1 ||
      macroblockHeight > this.capacities.rows
    ) {
      throw new Error(`DNx frame row count ${macroblockHeight} exceeds the Zig capacity of ${this.capacities.rows}.`);
    }

    const frameByteLength = macroblockWidth * 16 * macroblockHeight * 16 * (is444 ? 3 : 2) * (bitDepth === 8 ? 1 : 2);
    if (frameByteLength > this.capacities.frameBytes) {
      throw new Error(`DNx frame requires ${frameByteLength} bytes, exceeding the Zig buffer capacity.`);
    }

    this.configureTables(tables);
    new Uint8Array(this.exports.memory.buffer, this.exports.dnx_packet_buffer_ptr(), packet.byteLength).set(packet);
    const starts = new Uint32Array(this.exports.memory.buffer, this.exports.dnx_row_starts_ptr(), rows.length);
    const ends = new Uint32Array(this.exports.memory.buffer, this.exports.dnx_row_ends_ptr(), rows.length);
    for (let index = 0; index < rows.length; index += 1) {
      starts[index] = rows[index].start;
      ends[index] = rows[index].end;
    }

    let result: number;
    try {
      result = this.exports.dnx_decode_frame(
        packet.byteLength,
        macroblockWidth,
        macroblockHeight,
        bitDepth,
        tables.acInfo.length,
        tables.run.length,
        tables.eobIndex,
        tables.indexBits,
        tables.levelBias,
        tables.levelShift,
        is444 ? 1 : 0,
        mbaff ? 1 : 0
      );
    } catch (error) {
      throw new Error(`Zig frame decode trapped at ${this.diagnosticSummary()}.`, { cause: error });
    }
    if (result !== 0) {
      throw new Error(
        `Zig frame decode failed: ${ERROR_MESSAGES[result] ?? `unknown error ${result}`} at ${this.diagnosticSummary()}.`
      );
    }

    return new Uint8Array(this.exports.memory.buffer, this.exports.dnx_frame_buffer_ptr(), frameByteLength);
  }

  decodeRow(
    rowBytes: Uint8Array,
    macroblockWidth: number,
    bitDepth: 8 | 10 | 12,
    is444: boolean,
    tables: DnxRowTableSet
  ): Uint16Array {
    if (this.destroyed) {
      throw new Error("DNx Zig row decoder is destroyed.");
    }
    if (rowBytes.byteLength > this.capacities.rowBytes) {
      throw new Error(`DNx row requires ${rowBytes.byteLength} bytes, exceeding the Zig buffer capacity.`);
    }
    if (
      !Number.isInteger(macroblockWidth) ||
      macroblockWidth < 1 ||
      macroblockWidth > this.capacities.macroblocksPerRow
    ) {
      throw new Error(
        `DNx row macroblock width ${macroblockWidth} exceeds the Zig capacity of ${this.capacities.macroblocksPerRow}.`
      );
    }

    this.configureTables(tables);
    new Uint8Array(this.exports.memory.buffer, this.exports.dnx_row_buffer_ptr(), rowBytes.byteLength).set(rowBytes);
    let result: number;
    try {
      result = this.exports.dnx_decode_row(
        rowBytes.byteLength,
        macroblockWidth,
        bitDepth,
        tables.acInfo.length,
        tables.run.length,
        tables.eobIndex,
        tables.indexBits,
        tables.levelBias,
        tables.levelShift,
        is444 ? 1 : 0
      );
    } catch (error) {
      throw new Error(`Zig row decode trapped at ${this.diagnosticSummary()}.`, { cause: error });
    }
    if (result !== 0) {
      throw new Error(
        `Zig row decode failed: ${ERROR_MESSAGES[result] ?? `unknown error ${result}`} at ${this.diagnosticSummary()}.`
      );
    }

    const blocksPerMacroblock = is444 ? BLOCKS_PER_MACROBLOCK_444 : BLOCKS_PER_MACROBLOCK_422;
    const sampleCount = macroblockWidth * blocksPerMacroblock * SAMPLES_PER_BLOCK;
    return new Uint16Array(this.exports.memory.buffer, this.exports.dnx_samples_ptr(), sampleCount);
  }

  destroy(): void {
    this.destroyed = true;
    this.configuredTables = null;
  }

  private configureTables(tables: DnxRowTableSet): void {
    if (tables === this.configuredTables) {
      return;
    }
    validateTables(tables);

    copyLookup(this.exports.memory, this.exports.dnx_dc_lookup_ptr(), tables.dcTable.zigLookup);
    copyLookup(this.exports.memory, this.exports.dnx_ac_lookup_ptr(), tables.acTable.zigLookup);
    copyLookup(this.exports.memory, this.exports.dnx_run_lookup_ptr(), tables.runTable.zigLookup);
    new Uint16Array(this.exports.memory.buffer, this.exports.dnx_ac_info_ptr(), tables.acInfo.length).set(tables.acInfo);
    new Uint8Array(this.exports.memory.buffer, this.exports.dnx_run_values_ptr(), tables.run.length).set(tables.run);
    new Uint16Array(this.exports.memory.buffer, this.exports.dnx_luma_weight_ptr(), 64).set(tables.lumaWeight);
    new Uint16Array(this.exports.memory.buffer, this.exports.dnx_chroma_weight_ptr(), 64).set(tables.chromaWeight);
    this.configuredTables = tables;
  }

  private diagnosticSummary(): string {
    return `stage ${this.exports.dnx_diagnostic_stage()}, row ${this.exports.dnx_diagnostic_row()}, macroblock ${this.exports.dnx_diagnostic_macroblock()}, block ${this.exports.dnx_diagnostic_block()}, bit ${this.exports.dnx_diagnostic_bit_offset()}`;
  }
}

function copyLookup(memory: WebAssembly.Memory, pointer: number, lookup: Uint16Array): void {
  new Uint16Array(memory.buffer, pointer, HUFFMAN_LOOKUP_SIZE).set(lookup);
}

function validateTables(tables: DnxRowTableSet): void {
  for (const table of [tables.dcTable, tables.acTable, tables.runTable]) {
    if (table.lookup.length !== HUFFMAN_LOOKUP_SIZE || table.zigLookup.length !== HUFFMAN_LOOKUP_SIZE) {
      throw new Error("DNx Zig row decoder requires complete 16-bit Huffman lookup tables.");
    }
  }
  if (tables.acInfo.length > 1024 || tables.run.length > 64) {
    throw new Error("DNx Zig row decoder table data exceeds the native buffer capacity.");
  }
  if (tables.lumaWeight.length !== 64 || tables.chromaWeight.length !== 64) {
    throw new Error("DNx Zig row decoder requires 64-entry quantization weight tables.");
  }
}

function validateExports(exports: Partial<DnxZigWasmExports>): asserts exports is DnxZigWasmExports {
  const requiredFunctions = [
    "dnx_row_decoder_version",
    "dnx_row_capacity",
    "dnx_macroblock_capacity",
    "dnx_rows_capacity",
    "dnx_row_buffer_ptr",
    "dnx_packet_capacity",
    "dnx_packet_buffer_ptr",
    "dnx_row_starts_ptr",
    "dnx_row_ends_ptr",
    "dnx_frame_capacity",
    "dnx_frame_buffer_ptr",
    "dnx_dc_lookup_ptr",
    "dnx_ac_lookup_ptr",
    "dnx_run_lookup_ptr",
    "dnx_ac_info_ptr",
    "dnx_run_values_ptr",
    "dnx_luma_weight_ptr",
    "dnx_chroma_weight_ptr",
    "dnx_samples_ptr",
    "dnx_diagnostic_stage",
    "dnx_diagnostic_row",
    "dnx_diagnostic_macroblock",
    "dnx_diagnostic_block",
    "dnx_diagnostic_bit_offset",
    "dnx_decode_row",
    "dnx_decode_frame"
  ] as const;
  if (!(exports.memory instanceof WebAssembly.Memory)) {
    throw new Error("DNx Zig row decoder does not export linear memory.");
  }
  for (const name of requiredFunctions) {
    if (typeof exports[name] !== "function") {
      throw new Error(`DNx Zig row decoder is missing export ${name}.`);
    }
  }
}

async function loadCompiledModule(wasmUrl?: string | URL): Promise<WebAssembly.Module> {
  // Resolved on use, not at import: a bundle without a URL base must still load.
  const defaultUrl = new URL("../wasm/generated/dnx_row_decoder.wasm", import.meta.url);
  const url = wasmUrl === undefined ? defaultUrl : new URL(wasmUrl, defaultUrl);
  let compiled = compiledModules.get(url.href);
  if (!compiled) {
    compiled = fetch(url).then(async (response) => {
      if (!response.ok) {
        throw new Error(`DNx Zig row decoder request failed with HTTP ${response.status}.`);
      }
      return WebAssembly.compile(await response.arrayBuffer());
    });
    // A failed load is not cached, so a later decoder can retry.
    compiled.catch(() => compiledModules.delete(url.href));
    compiledModules.set(url.href, compiled);
  }
  return compiled;
}
