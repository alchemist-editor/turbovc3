const builtin = @import("builtin");
const fast_idct = @import("dnx_fast_idct.zig");
const std = @import("std");

// The limits are 8K DCI: 8192x4320, 512 macroblocks wide and 270 rows.
// A row of 512 macroblocks can code up to about 1.6 MB in the worst case
// (tests/dnx-row-buffer-test.mjs works it out from the tables).
const MAX_ROW_BYTES = 2 * 1024 * 1024;
const MAX_MACROBLOCKS = 512;
const MAX_ROWS = 270;
// The largest DNxHR packet at that size, 4:4:4 (57344/255 bytes per
// macroblock), is about 31.1 MB.
const MAX_PACKET_BYTES = 32 * 1024 * 1024;
// 8192x4320, three full planes of 16-bit samples.
const MAX_FRAME_BYTES = MAX_MACROBLOCKS * 16 * MAX_ROWS * 16 * 3 * 2;
const MAX_BLOCKS_PER_MACROBLOCK = 12;
const MAX_BLOCKS = MAX_MACROBLOCKS * MAX_BLOCKS_PER_MACROBLOCK;
pub const LOOKUP_SIZE = 1 << 16;
const MAX_AC_INFO = 1024;
const MAX_RUN_VALUES = 64;

var row_bytes: [MAX_ROW_BYTES]u8 align(16) = undefined;
// The packet and frame buffers are sized on demand by dnx_reserve_frame, up
// to the limits above. Static buffers that large would commit the full 8K
// size (about 240 MB) in every instance, row workers included, which only
// ever decode rows.
var packet_bytes: []align(16) u8 = &.{};
var row_starts: [MAX_ROWS]u32 align(16) = undefined;
var row_ends: [MAX_ROWS]u32 align(16) = undefined;
var frame_bytes: []align(16) u8 = &.{};
const buffer_allocator = if (builtin.cpu.arch.isWasm()) std.heap.wasm_allocator else std.heap.page_allocator;
var dc_lookup: [LOOKUP_SIZE]u16 align(16) = @splat(0);
var ac_lookup: [LOOKUP_SIZE]u16 align(16) = @splat(0);
var run_lookup: [LOOKUP_SIZE]u16 align(16) = @splat(0);
var ac_info: [MAX_AC_INFO]u16 align(16) = @splat(0);
var run_values: [MAX_RUN_VALUES]u8 align(16) = @splat(0);
var luma_weight: [64]u16 align(16) = @splat(0);
var chroma_weight: [64]u16 align(16) = @splat(0);
var coefficients: [MAX_BLOCKS * 64]i32 align(16) = undefined;
var samples: [MAX_BLOCKS * 64]u16 align(16) = undefined;
var diagnostic_stage: u32 = 0;
var diagnostic_row: u32 = 0;
var diagnostic_macroblock: u32 = 0;
var diagnostic_block: u32 = 0;
var diagnostic_bit_offset: u32 = 0;

pub const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// The entropy and quantiser tables one decode reads. The WASM exports fill
/// module globals and decode through `global_tables`; the native frame
/// decoder (`dnx/frame_decoder.zig`) builds its own, so several frames or
/// rows can decode at once.
pub const Tables = struct {
    dc_lookup: *const [LOOKUP_SIZE]u16,
    ac_lookup: *const [LOOKUP_SIZE]u16,
    run_lookup: *const [LOOKUP_SIZE]u16,
    ac_info: []const u16,
    run_values: []const u8,
    luma_weight: *const [64]u16,
    chroma_weight: *const [64]u16,
    eob_index: u32,
    index_bits: u32,
    level_bias: i32,
    level_shift: u32,
    /// Tests turn this off to compare against bit-by-bit checked reads.
    batch_reads: bool = true,
    /// Small first-level tables. The native decoder has them; without them
    /// (the WASM build) every symbol goes through the full lookups.
    fast: ?*const FastTables = null,
};

/// First-level tables over the leading bits of each code. The full lookups are
/// 128 KiB each, and because a short code fills thousands of their entries,
/// decoding walks all over them; these fit in the L1 cache alongside the
/// decoder's other data. An AC entry usually holds a whole coefficient (code,
/// sign and run, when they fit in the prefix), so one load replaces the chain
/// of lookups and the unpredictable branches on what follows each code.
/// An entry of 0 means "use the full lookups", which also report bad codes.
pub const FastTables = struct {
    ac: [1 << ac_bits]u32,
    run: [1 << run_bits]u16,
    dc: [1 << dc_bits]u16,

    pub const ac_bits = 12;
    pub const run_bits = 9;
    pub const dc_bits = 9;

    // An AC entry. `ac_partial` entries cover the code alone: the sign, level
    // index and run are still in the stream. The others cover all of it.
    const ac_length_mask: u32 = 0x1f;
    const ac_has_index_shift = 5;
    const ac_has_run_shift = 6;
    const ac_end_of_block: u32 = 1 << 7;
    const ac_partial: u32 = 1 << 8;
    const ac_sign_shift = 9;
    const ac_run_shift = 10;
    const ac_run_mask: u32 = 0x3f;
    const ac_level_shift = 16;

    const max_fast_dc_bits = 16;

    pub fn fill(
        self: *FastTables,
        dc: *const [LOOKUP_SIZE]u16,
        ac: *const [LOOKUP_SIZE]u16,
        run: *const [LOOKUP_SIZE]u16,
        info: []const u16,
        run_table: []const u8,
        eob_index: u32,
    ) void {
        for (&self.ac, 0..) |*entry, prefix| {
            entry.* = 0;
            const symbol = resolved(ac, prefix, ac_bits) orelse continue;
            if (symbol.value == eob_index) {
                entry.* = symbol.length | ac_end_of_block;
                continue;
            }
            const index = @as(usize, symbol.value) * 2;
            if (index + 1 >= info.len) continue;
            const flags: u32 = info[index + 1];
            const level: u32 = info[index];
            const code_bits: u32 = symbol.length;
            entry.* = code_bits | ac_partial |
                ((flags & 1) << ac_has_index_shift) |
                (((flags >> 1) & 1) << ac_has_run_shift) |
                (level << ac_level_shift);

            // The whole coefficient, when no level index follows and the sign
            // and any run code also fit in the prefix.
            if (flags & 1 != 0 or code_bits >= ac_bits) continue;
            const sign_position: u5 = @intCast(ac_bits - code_bits - 1);
            const sign: u32 = @intCast((prefix >> sign_position) & 1);
            var run_value: u32 = 0;
            var run_code_bits: u32 = 0;
            if (flags & 2 != 0) {
                if (sign_position == 0) continue;
                const run_prefix = prefix & ((@as(usize, 1) << sign_position) - 1);
                const run_symbol = resolved(run, run_prefix, sign_position) orelse continue;
                if (run_symbol.value >= run_table.len) continue;
                run_value = run_table[run_symbol.value];
                run_code_bits = run_symbol.length;
            }
            if (run_value > ac_run_mask) continue;
            entry.* = (code_bits + 1 + run_code_bits) |
                (sign << ac_sign_shift) |
                (run_value << ac_run_shift) |
                (level << ac_level_shift);
        }
        for (&self.run, 0..) |*entry, prefix| {
            entry.* = 0;
            const symbol = resolved(run, prefix, run_bits) orelse continue;
            if (symbol.value >= run_table.len) continue;
            entry.* = symbol.length | (@as(u16, run_table[symbol.value]) << 8);
        }
        for (&self.dc, 0..) |*entry, prefix| {
            entry.* = 0;
            const symbol = resolved(dc, prefix, dc_bits) orelse continue;
            if (symbol.value > max_fast_dc_bits) continue;
            entry.* = symbol.length | (symbol.value << 8);
        }
    }

    const Resolved = struct { length: u16, value: u16 };

    /// The symbol a `bits`-long prefix decides, if its code fits in the prefix.
    fn resolved(lookup: *const [LOOKUP_SIZE]u16, prefix: usize, bits: u5) ?Resolved {
        const packed_value = lookup[prefix << (16 - bits)];
        if (packed_value == 0) return null;
        const length = (packed_value >> 12) + 1;
        if (length > bits) return null;
        return .{ .length = length, .value = (packed_value & 0x0fff) - 1 };
    }
};

fn globalTables(ac_info_length: u32, run_values_length: u32, eob_index: u32, index_bits: u32, level_bias: i32, level_shift: u32) Tables {
    return .{
        .dc_lookup = &dc_lookup,
        .ac_lookup = &ac_lookup,
        .run_lookup = &run_lookup,
        .ac_info = ac_info[0..ac_info_length],
        .run_values = run_values[0..run_values_length],
        .luma_weight = &luma_weight,
        .chroma_weight = &chroma_weight,
        .eob_index = eob_index,
        .index_bits = index_bits,
        .level_bias = level_bias,
        .level_shift = level_shift,
    };
}

/// One component's dequantiser at one qscale, indexed by scan position.
pub const Quantiser = struct {
    scale: [64]i32,
    offset: [64]i32,

    pub fn fill(self: *Quantiser, qscale: i32, weight: *const [64]u16, level_bias: i32) void {
        for (weight, 0..) |w, index| {
            const scale = qscale * @as(i32, w);
            self.scale[index] = scale;
            self.offset[index] = (scale >> 1) + (if (level_bias < 32 or w != level_bias) level_bias else 0);
        }
    }
};

pub const DecodeError = enum(u32) {
    ok = 0,
    invalid_arguments = 1,
    macroblock_header = 2,
    act_not_supported = 3,
    dc_vlc = 4,
    dc_delta = 5,
    ac_sign = 6,
    ac_level = 7,
    run_vlc = 8,
    coefficient_overrun = 9,
    ac_vlc = 10,
    out_of_memory = 11,
};

pub const BitReader = struct {
    bytes: []const u8,
    byte_offset: usize = 0,
    cache: u64 = 0,
    cached_bits: usize = 0,

    pub inline fn bitsRead(self: *const BitReader) usize {
        return self.byte_offset * 8 - self.cached_bits;
    }

    /// Whether `count` bits (at most 56) are cached, refilling if needed.
    inline fn ensure(self: *BitReader, count: usize) bool {
        if (self.cached_bits < count) self.refill();
        return self.cached_bits >= count;
    }

    /// The next `count` bits (1 to 32), which `ensure` has made available.
    inline fn takeBits(self: *BitReader, count: usize) u32 {
        const value: u32 = @truncate(self.cache >> @intCast(64 - count));
        self.consume(count);
        return value;
    }

    /// `readSymbol` with 16 bits known to be cached.
    inline fn takeSymbol(self: *BitReader, lookup: *const [LOOKUP_SIZE]u16) ?u32 {
        const prefix: u16 = @truncate(self.cache >> 48);
        const packed_value = lookup[prefix];
        if (packed_value == 0) return null;
        self.consume((packed_value >> 12) + 1);
        return (packed_value & 0x0fff) - 1;
    }

    // A refill leaves at least 56 bits cached unless the input has run out,
    // so after one, too few cached bits means too few bits remain.
    pub inline fn readBits(self: *BitReader, count: usize) ?u32 {
        if (count == 0) return 0;
        if (self.cached_bits < count) {
            self.refill();
            if (self.cached_bits < count) return null;
        }
        const value: u32 = @truncate(self.cache >> @intCast(64 - count));
        self.consume(count);
        return value;
    }

    pub inline fn readSymbol(self: *BitReader, lookup: *const [LOOKUP_SIZE]u16) ?u32 {
        if (self.cached_bits < 16) {
            self.refill();
            if (self.cached_bits == 0) return null;
        }
        const prefix: u16 = @truncate(self.cache >> 48);
        const packed_value = lookup[prefix];
        if (packed_value == 0) return null;
        const bit_count = (packed_value >> 12) + 1;
        if (bit_count > self.cached_bits) return null;
        self.consume(bit_count);
        return (packed_value & 0x0fff) - 1;
    }

    inline fn refill(self: *BitReader) void {
        if (self.canRefillWhole()) {
            self.refillWhole();
            return;
        }
        while (self.cached_bits <= 56 and self.byte_offset < self.bytes.len) {
            const shift: u6 = @intCast(56 - self.cached_bits);
            self.cache |= @as(u64, self.bytes[self.byte_offset]) << shift;
            self.byte_offset += 1;
            self.cached_bits += 8;
        }
    }

    inline fn canRefillWhole(self: *const BitReader) bool {
        return self.bytes.len - self.byte_offset >= 8;
    }

    /// Tops the cache up to 56 to 63 bits, with no branch on how many it held.
    /// Bits of a partly taken byte also land in the cache; the next refill ORs
    /// in the same bits. Needs `canRefillWhole`.
    inline fn refillWhole(self: *BitReader) void {
        const word = std.mem.readInt(u64, self.bytes[self.byte_offset..][0..8], .big);
        self.cache |= word >> @intCast(self.cached_bits);
        self.byte_offset += (63 - self.cached_bits) >> 3;
        self.cached_bits |= 56;
    }

    inline fn consume(self: *BitReader, count: usize) void {
        self.cache <<= @intCast(count);
        self.cached_bits -= count;
    }
};

pub export fn dnx_row_decoder_version() u32 {
    return 5;
}

pub export fn dnx_row_capacity() u32 {
    return MAX_ROW_BYTES;
}

pub export fn dnx_macroblock_capacity() u32 {
    return MAX_MACROBLOCKS;
}

pub export fn dnx_rows_capacity() u32 {
    return MAX_ROWS;
}

pub export fn dnx_row_buffer_ptr() usize {
    return @intFromPtr(&row_bytes);
}

pub export fn dnx_packet_capacity() u32 {
    return MAX_PACKET_BYTES;
}

/// The packet buffer; valid for dnx_packet_buffer_length() bytes, after a
/// successful dnx_reserve_frame. Reserving again may move it.
pub export fn dnx_packet_buffer_ptr() usize {
    return @intFromPtr(packet_bytes.ptr);
}

pub export fn dnx_packet_buffer_length() u32 {
    return @intCast(packet_bytes.len);
}

pub export fn dnx_row_starts_ptr() usize {
    return @intFromPtr(&row_starts);
}

pub export fn dnx_row_ends_ptr() usize {
    return @intFromPtr(&row_ends);
}

pub export fn dnx_frame_capacity() u32 {
    return MAX_FRAME_BYTES;
}

/// The frame buffer; valid for dnx_frame_buffer_length() bytes, after a
/// successful dnx_reserve_frame. Reserving again may move it.
pub export fn dnx_frame_buffer_ptr() usize {
    return @intFromPtr(frame_bytes.ptr);
}

pub export fn dnx_frame_buffer_length() u32 {
    return @intCast(frame_bytes.len);
}

/// Make the packet and frame buffers at least this large. Returns ok,
/// invalid_arguments past dnx_packet_capacity or dnx_frame_capacity, or
/// out_of_memory. Grown buffers keep no contents, so reserve before writing
/// the packet; WebAssembly memory may grow, so re-read memory.buffer after.
pub export fn dnx_reserve_frame(packet_length: u32, frame_byte_length: u32) u32 {
    if (packet_length > MAX_PACKET_BYTES or frame_byte_length > MAX_FRAME_BYTES) {
        return @backingInt(DecodeError.invalid_arguments);
    }
    if (!reserve(&packet_bytes, packet_length) or !reserve(&frame_bytes, frame_byte_length)) {
        return @backingInt(DecodeError.out_of_memory);
    }
    return @backingInt(DecodeError.ok);
}

fn reserve(buffer: *[]align(16) u8, length: u32) bool {
    if (buffer.len >= length) return true;
    // Whole MiBs, so a stream whose packets vary by a few bytes does not
    // reallocate every frame.
    const rounded = std.mem.alignForward(usize, length, 1024 * 1024);
    const grown = buffer_allocator.alignedAlloc(u8, .@"16", rounded) catch return false;
    if (buffer.len != 0) buffer_allocator.free(buffer.*);
    buffer.* = grown;
    return true;
}

pub export fn dnx_dc_lookup_ptr() usize {
    return @intFromPtr(&dc_lookup);
}

pub export fn dnx_ac_lookup_ptr() usize {
    return @intFromPtr(&ac_lookup);
}

pub export fn dnx_run_lookup_ptr() usize {
    return @intFromPtr(&run_lookup);
}

pub export fn dnx_ac_info_ptr() usize {
    return @intFromPtr(&ac_info);
}

pub export fn dnx_run_values_ptr() usize {
    return @intFromPtr(&run_values);
}

pub export fn dnx_luma_weight_ptr() usize {
    return @intFromPtr(&luma_weight);
}

pub export fn dnx_chroma_weight_ptr() usize {
    return @intFromPtr(&chroma_weight);
}

pub export fn dnx_samples_ptr() usize {
    return @intFromPtr(&samples);
}

pub export fn dnx_coefficients_ptr() usize {
    return @intFromPtr(&coefficients);
}

pub export fn dnx_diagnostic_stage() u32 {
    return diagnostic_stage;
}

pub export fn dnx_diagnostic_row() u32 {
    return diagnostic_row;
}

pub export fn dnx_diagnostic_macroblock() u32 {
    return diagnostic_macroblock;
}

pub export fn dnx_diagnostic_block() u32 {
    return diagnostic_block;
}

pub export fn dnx_diagnostic_bit_offset() u32 {
    return diagnostic_bit_offset;
}

pub export fn dnx_decode_row(
    row_length: u32,
    macroblock_width: u32,
    bit_depth: u32,
    ac_info_length: u32,
    run_values_length: u32,
    eob_index: u32,
    index_bits: u32,
    level_bias: i32,
    level_shift: u32,
    is_444: u32,
) u32 {
    if (row_length > MAX_ROW_BYTES or macroblock_width == 0 or macroblock_width > MAX_MACROBLOCKS or
        (bit_depth != 8 and bit_depth != 10 and bit_depth != 12) or ac_info_length > MAX_AC_INFO or
        run_values_length > MAX_RUN_VALUES or level_shift > 31 or is_444 > 1)
    {
        return @backingInt(DecodeError.invalid_arguments);
    }

    diagnostic_row = 0;
    return @backingInt(decodeRowBytes(
        row_bytes[0..row_length],
        macroblock_width,
        bit_depth,
        ac_info_length,
        run_values_length,
        eob_index,
        index_bits,
        level_bias,
        level_shift,
        is_444 != 0,
    ));
}

pub export fn dnx_decode_frame(
    packet_length: u32,
    macroblock_width: u32,
    macroblock_height: u32,
    bit_depth: u32,
    ac_info_length: u32,
    run_values_length: u32,
    eob_index: u32,
    index_bits: u32,
    level_bias: i32,
    level_shift: u32,
    is_444: u32,
    mbaff: u32,
) u32 {
    if (packet_length > packet_bytes.len or macroblock_width == 0 or macroblock_width > MAX_MACROBLOCKS or
        macroblock_height == 0 or macroblock_height > MAX_ROWS or
        (bit_depth != 8 and bit_depth != 10 and bit_depth != 12) or ac_info_length > MAX_AC_INFO or
        run_values_length > MAX_RUN_VALUES or level_shift > 31 or is_444 > 1 or mbaff > 1)
    {
        return @backingInt(DecodeError.invalid_arguments);
    }
    const bytes_per_sample: u64 = if (bit_depth == 8) 1 else 2;
    const plane_count: u64 = if (is_444 != 0) 3 else 2;
    const frame_byte_length = @as(u64, macroblock_width) * 16 * macroblock_height * 16 * plane_count * bytes_per_sample;
    if (frame_byte_length > frame_bytes.len) return @backingInt(DecodeError.invalid_arguments);

    for (0..macroblock_height) |row| {
        diagnostic_row = @intCast(row);
        const start = row_starts[row];
        const end = row_ends[row];
        if (start > end or end > packet_length) {
            return @backingInt(DecodeError.invalid_arguments);
        }
        const result = decodeRowIntoFrame(
            packet_bytes[start..end],
            macroblock_width,
            macroblock_height,
            @intCast(row),
            bit_depth,
            ac_info_length,
            run_values_length,
            eob_index,
            index_bits,
            level_bias,
            level_shift,
            is_444 != 0,
            mbaff != 0,
        );
        if (result != .ok) return @backingInt(result);
    }

    diagnostic_stage = 6;
    return @backingInt(DecodeError.ok);
}

test "native capacity exports and oversized arguments are safe" {
    try std.testing.expectEqual(@as(u32, MAX_MACROBLOCKS), dnx_macroblock_capacity());
    try std.testing.expectEqual(@as(u32, MAX_ROWS), dnx_rows_capacity());
    try std.testing.expectEqual(
        @backingInt(DecodeError.invalid_arguments),
        dnx_decode_row(0, MAX_MACROBLOCKS + 1, 8, 0, 0, 0, 0, 0, 0, 0),
    );
    try std.testing.expectEqual(
        @backingInt(DecodeError.invalid_arguments),
        dnx_decode_frame(0, std.math.maxInt(u32), std.math.maxInt(u32), 12, 0, 0, 0, 0, 0, 0, 1, 0),
    );
}

fn decodeRowIntoFrame(
    input: []const u8,
    macroblock_width: u32,
    macroblock_height: u32,
    row: u32,
    bit_depth: u32,
    ac_info_length: u32,
    run_values_length: u32,
    eob_index: u32,
    index_bits: u32,
    level_bias: i32,
    level_shift: u32,
    is_444: bool,
    mbaff: bool,
) DecodeError {
    diagnostic_stage = 1;
    diagnostic_macroblock = 0;
    diagnostic_block = 0;
    diagnostic_bit_offset = 0;
    var reader = BitReader{ .bytes = input };
    var last_dc = [3]i32{
        @as(i32, 1) << @intCast(bit_depth + 2),
        @as(i32, 1) << @intCast(bit_depth + 2),
        @as(i32, 1) << @intCast(bit_depth + 2),
    };
    var last_qscale: i32 = -1;
    var luma_quantiser: Quantiser = undefined;
    var chroma_quantiser: Quantiser = undefined;
    const maximum: u16 = @intCast((@as(u32, 1) << @intCast(bit_depth)) - 1);
    const dc_shift: u32 = if (bit_depth == 12) 2 else 0;

    var macroblock: usize = 0;
    while (macroblock < macroblock_width) : (macroblock += 1) {
        diagnostic_stage = 2;
        diagnostic_macroblock = @intCast(macroblock);
        diagnostic_bit_offset = @intCast(reader.bitsRead());
        const interlaced = if (mbaff)
            (reader.readBits(1) orelse return .macroblock_header) != 0
        else
            false;
        const qscale_value = reader.readBits(if (mbaff) 10 else 11) orelse return .macroblock_header;
        _ = reader.readBits(1) orelse return .macroblock_header;

        const qscale: i32 = @intCast(qscale_value);
        if (qscale != last_qscale) {
            luma_quantiser.fill(qscale, &luma_weight, level_bias);
            chroma_quantiser.fill(qscale, &chroma_weight, level_bias);
            last_qscale = qscale;
        }

        const blocks_per_macroblock: usize = if (is_444) 12 else 8;
        for (0..blocks_per_macroblock) |block_index| {
            diagnostic_stage = 3;
            diagnostic_block = @intCast(block_index);
            diagnostic_bit_offset = @intCast(reader.bitsRead());
            @memset(coefficients[0..64], 0);
            var has_ac = false;
            const result = decodeBlock(
                &reader,
                0,
                block_index,
                &last_dc,
                &luma_quantiser,
                &chroma_quantiser,
                ac_info_length,
                run_values_length,
                eob_index,
                index_bits,
                level_bias,
                level_shift,
                is_444,
                dc_shift,
                &has_ac,
            );
            if (result != .ok) {
                diagnostic_bit_offset = @intCast(reader.bitsRead());
                return result;
            }

            diagnostic_stage = 4;
            if (has_ac) {
                fast_idct.transformBlock(coefficients[0..].ptr, samples[0..].ptr, maximum);
            } else {
                fast_idct.transformDcBlock(coefficients[0], samples[0..].ptr, maximum);
            }
            diagnostic_stage = 5;
            storeDecodedBlock(
                macroblock_width,
                macroblock_height,
                row,
                bit_depth,
                macroblock,
                block_index,
                is_444,
                interlaced,
            );
        }
    }

    diagnostic_bit_offset = @intCast(reader.bitsRead());
    return .ok;
}

fn decodeRowBytes(
    input: []const u8,
    macroblock_width: u32,
    bit_depth: u32,
    ac_info_length: u32,
    run_values_length: u32,
    eob_index: u32,
    index_bits: u32,
    level_bias: i32,
    level_shift: u32,
    is_444: bool,
) DecodeError {
    const blocks_per_macroblock: usize = if (is_444) 12 else 8;
    const block_count: usize = @as(usize, macroblock_width) * blocks_per_macroblock;
    diagnostic_stage = 1;
    diagnostic_macroblock = 0;
    diagnostic_block = 0;
    diagnostic_bit_offset = 0;
    @memset(coefficients[0 .. block_count * 64], 0);
    var reader = BitReader{ .bytes = input };
    var last_dc = [3]i32{
        @as(i32, 1) << @intCast(bit_depth + 2),
        @as(i32, 1) << @intCast(bit_depth + 2),
        @as(i32, 1) << @intCast(bit_depth + 2),
    };
    var last_qscale: i32 = -1;
    var luma_quantiser: Quantiser = undefined;
    var chroma_quantiser: Quantiser = undefined;
    const dc_shift: u32 = if (bit_depth == 12) 2 else 0;

    var macroblock: usize = 0;
    while (macroblock < macroblock_width) : (macroblock += 1) {
        diagnostic_stage = 2;
        diagnostic_macroblock = @intCast(macroblock);
        diagnostic_bit_offset = @intCast(reader.bitsRead());
        const qscale_value = reader.readBits(11) orelse return .macroblock_header;
        _ = reader.readBits(1) orelse return .macroblock_header;

        const qscale: i32 = @intCast(qscale_value);
        if (qscale != last_qscale) {
            luma_quantiser.fill(qscale, &luma_weight, level_bias);
            chroma_quantiser.fill(qscale, &chroma_weight, level_bias);
            last_qscale = qscale;
        }

        for (0..blocks_per_macroblock) |block_index| {
            diagnostic_stage = 3;
            diagnostic_block = @intCast(block_index);
            diagnostic_bit_offset = @intCast(reader.bitsRead());
            var has_ac = false;
            const result = decodeBlock(
                &reader,
                macroblock * blocks_per_macroblock + block_index,
                block_index,
                &last_dc,
                &luma_quantiser,
                &chroma_quantiser,
                ac_info_length,
                run_values_length,
                eob_index,
                index_bits,
                level_bias,
                level_shift,
                is_444,
                dc_shift,
                &has_ac,
            );
            if (result != .ok) {
                diagnostic_bit_offset = @intCast(reader.bitsRead());
                return result;
            }
        }
    }

    diagnostic_stage = 4;
    diagnostic_bit_offset = @intCast(reader.bitsRead());
    inverseDctBlocks(coefficients[0..].ptr, samples[0..].ptr, block_count, bit_depth);
    diagnostic_stage = 5;
    return .ok;
}

pub export fn dnx_idct_blocks(block_count: u32, bit_depth: u32) u32 {
    if (block_count == 0 or block_count > MAX_BLOCKS or (bit_depth != 8 and bit_depth != 10 and bit_depth != 12)) {
        return @backingInt(DecodeError.invalid_arguments);
    }
    inverseDctBlocks(coefficients[0..].ptr, samples[0..].ptr, block_count, bit_depth);
    return @backingInt(DecodeError.ok);
}

/// Parses one 8x8 block into `out` (zeroed by the caller), in transposed
/// natural order (`u * 8 + v`, horizontal frequency first), dequantised.
pub inline fn decodeBlockInto(
    tables: *const Tables,
    reader: *BitReader,
    out: *[64]i32,
    block_index: usize,
    last_dc: *[3]i32,
    luma_quantiser: *const Quantiser,
    chroma_quantiser: *const Quantiser,
    is_444: bool,
    dc_shift: u32,
    has_ac: *bool,
) DecodeError {
    const component: usize = if (is_444)
        (block_index >> 1) % 3
    else if ((block_index & 2) != 0)
        1 + (block_index & 1)
    else
        0;
    const quantiser = if (component == 0) luma_quantiser else chroma_quantiser;
    // One coefficient reads at most its AC symbol, sign, level index and run
    // symbol. With that many bits cached none of them needs a check.
    const coefficient_bits: usize = 16 + 1 + @as(usize, tables.index_bits) + 16;
    const can_batch = tables.batch_reads and tables.index_bits >= 1 and coefficient_bits <= 56;
    const fast = if (can_batch) tables.fast else null;

    dc: {
        if (fast) |f| {
            if (reader.canRefillWhole()) {
                reader.refillWhole();
                const entry = f.dc[@intCast(reader.cache >> (64 - FastTables.dc_bits))];
                if (entry != 0) {
                    reader.consume(entry & 0xff);
                    // Branch-free: a clear top bit means a negative delta, and
                    // a zero length reads nothing and adds nothing.
                    const length: u6 = @intCast(entry >> 8);
                    const bits: u32 = @truncate((reader.cache >> 1) >> (63 - length));
                    reader.consume(length);
                    const negative: u32 = ((bits << 1) >> @as(u5, @intCast(length))) -% 1;
                    const span: u32 = (@as(u32, 1) << @as(u5, @intCast(length))) - 1;
                    const delta: i32 = @bitCast(bits -% (negative & span));
                    last_dc[component] += delta * (@as(i32, 1) << @intCast(dc_shift));
                    break :dc;
                }
            }
        }
        const dc_len = reader.readSymbol(tables.dc_lookup) orelse return .dc_vlc;
        if (dc_len > 31) return .dc_vlc;

        if (dc_len > 0) {
            const delta_bits = reader.readBits(dc_len) orelse return .dc_delta;
            const positive_threshold: u32 = @as(u32, 1) << @intCast(dc_len - 1);
            const delta: i32 = if (delta_bits < positive_threshold)
                @as(i32, @intCast(delta_bits)) - @as(i32, @intCast((@as(u32, 1) << @intCast(dc_len)) - 1))
            else
                @intCast(delta_bits);
            last_dc[component] += delta * (@as(i32, 1) << @intCast(dc_shift));
        }
    }

    out[0] = last_dc[component];
    var coefficient_index: usize = 0;
    const eob_index = tables.eob_index;
    const level_shift: u5 = @intCast(tables.level_shift);

    while (true) {
        if (fast) |f| {
            // Everything the loop uses lives in locals: writes through `out`
            // could otherwise alias the reader and the tables, and every
            // field would go back through memory for each coefficient.
            const ac_table = &f.ac;
            const run_table = &f.run;
            const scales = &quantiser.scale;
            const offsets = &quantiser.offset;
            const index_bits: u64 = tables.index_bits;
            const bytes = reader.bytes.ptr;
            const byte_count = reader.bytes.len;
            var cache = reader.cache;
            var cached = reader.cached_bits;
            var offset = reader.byte_offset;
            while (byte_count - offset >= 8) {
                cache |= std.mem.readInt(u64, bytes[offset..][0..8], .big) >> @intCast(cached);
                offset += (63 - cached) >> 3;
                cached |= 56;

                const entry = ac_table[@intCast(cache >> (64 - FastTables.ac_bits))];
                if (entry == 0) break;
                const entry_bits: u6 = @intCast(entry & FastTables.ac_length_mask);
                cache <<= entry_bits;
                cached -= entry_bits;

                var level: u32 = entry >> FastTables.ac_level_shift;
                var sign: u32 = (entry >> FastTables.ac_sign_shift) & 1;
                if (entry & (FastTables.ac_end_of_block | FastTables.ac_partial) == 0) {
                    coefficient_index += (entry >> FastTables.ac_run_shift) & FastTables.ac_run_mask;
                } else {
                    if (entry & FastTables.ac_end_of_block != 0) {
                        reader.cache = cache;
                        reader.cached_bits = cached;
                        reader.byte_offset = offset;
                        has_ac.* = coefficient_index != 0;
                        return .ok;
                    }

                    sign = @intCast(cache >> 63);
                    const has_index: u64 = (entry >> FastTables.ac_has_index_shift) & 1;
                    const extra_bits: u6 = @intCast((0 -% has_index) & index_bits);
                    const extra: u32 = @truncate((cache << 1 >> 1) >> (63 - extra_bits));
                    const after_level = cache << 1 << extra_bits;
                    level += extra << 7;

                    const has_run: u32 = (entry >> FastTables.ac_has_run_shift) & 1;
                    const run_mask: u32 = 0 -% has_run;
                    const run_entry: u32 = run_table[@intCast(after_level >> (64 - FastTables.run_bits))];
                    const level_bits = 1 + @as(usize, extra_bits);
                    if (run_entry == 0 and has_run != 0) {
                        reader.cache = after_level;
                        reader.cached_bits = cached - level_bits;
                        reader.byte_offset = offset;
                        const run_symbol = reader.takeSymbol(tables.run_lookup) orelse return .run_vlc;
                        if (run_symbol >= tables.run_values.len) return .run_vlc;
                        coefficient_index += tables.run_values[run_symbol];
                        cache = reader.cache;
                        cached = reader.cached_bits;
                    } else {
                        const run_bits: u6 = @intCast(run_entry & run_mask & 0xff);
                        cache = after_level << run_bits;
                        cached -= level_bits + run_bits;
                        coefficient_index += (run_entry >> 8) & run_mask;
                    }
                }

                coefficient_index += 1;
                if (coefficient_index > 63) {
                    reader.cache = cache;
                    reader.cached_bits = cached;
                    reader.byte_offset = offset;
                    return .coefficient_overrun;
                }
                const scaled: i32 = @as(i32, @intCast(level)) * scales[coefficient_index] + offsets[coefficient_index];
                const value = scaled >> level_shift;
                const negate: i32 = -@as(i32, @intCast(sign));
                out[zigzag[coefficient_index]] = (value ^ negate) - negate;
            }
            reader.cache = cache;
            reader.cached_bits = cached;
            reader.byte_offset = offset;
        }

        // Long codes, bad codes and the end of the row, read with every check.
        const ac_index = reader.readSymbol(tables.ac_lookup) orelse return .ac_vlc;
        if (ac_index == eob_index) {
            has_ac.* = coefficient_index != 0;
            return .ok;
        }
        const info_index = ac_index * 2;
        if (info_index + 1 >= tables.ac_info.len) return .ac_vlc;
        const level_base: u32 = tables.ac_info[info_index];
        const flags: u16 = tables.ac_info[info_index + 1];
        var level = level_base;
        var sign_bit: u32 = undefined;
        const batched = can_batch and reader.ensure(coefficient_bits);

        if (batched) {
            sign_bit = reader.takeBits(1);
            if ((flags & 1) != 0) level += reader.takeBits(tables.index_bits) << 7;
            if ((flags & 2) != 0) {
                const run_symbol = reader.takeSymbol(tables.run_lookup) orelse return .run_vlc;
                if (run_symbol >= tables.run_values.len) return .run_vlc;
                coefficient_index += tables.run_values[run_symbol];
            }
        } else {
            sign_bit = reader.readBits(1) orelse return .ac_sign;
            if ((flags & 1) != 0) {
                const extra = reader.readBits(tables.index_bits) orelse return .ac_level;
                level += extra << 7;
            }
            if ((flags & 2) != 0) {
                const run_symbol = reader.readSymbol(tables.run_lookup) orelse return .run_vlc;
                if (run_symbol >= tables.run_values.len) return .run_vlc;
                coefficient_index += tables.run_values[run_symbol];
            }
        }

        coefficient_index += 1;
        if (coefficient_index > 63) return .coefficient_overrun;
        const natural_index = zigzag[coefficient_index];
        var value: i32 = @as(i32, @intCast(level)) * quantiser.scale[coefficient_index];
        value += quantiser.offset[coefficient_index];
        value >>= level_shift;
        out[natural_index] = if (sign_bit != 0) -value else value;
    }
}

inline fn decodeBlock(
    reader: *BitReader,
    block: usize,
    block_index: usize,
    last_dc: *[3]i32,
    luma_quantiser: *const Quantiser,
    chroma_quantiser: *const Quantiser,
    ac_info_length: u32,
    run_values_length: u32,
    eob_index: u32,
    index_bits: u32,
    level_bias: i32,
    level_shift: u32,
    is_444: bool,
    dc_shift: u32,
    has_ac: *bool,
) DecodeError {
    const tables = globalTables(ac_info_length, run_values_length, eob_index, index_bits, level_bias, level_shift);
    return decodeBlockInto(&tables, reader, coefficients[block * 64 ..][0..64], block_index, last_dc, luma_quantiser, chroma_quantiser, is_444, dc_shift, has_ac);
}

fn inverseDctBlocks(output_coefficients: [*]const i32, output_samples: [*]u16, block_count: usize, bit_depth: u32) void {
    const maximum: u16 = @intCast((@as(u32, 1) << @intCast(bit_depth)) - 1);

    for (0..block_count) |block| {
        diagnostic_stage = 40;
        diagnostic_macroblock = @intCast(block);
        const block_offset = block * 64;
        fast_idct.transformBlock(output_coefficients + block_offset, output_samples + block_offset, maximum);
    }
}

fn storeDecodedBlock(
    macroblock_width: u32,
    macroblock_height: u32,
    row: u32,
    bit_depth: u32,
    macroblock: usize,
    block_index: usize,
    is_444: bool,
    interlaced: bool,
) void {
    const bytes_per_sample: usize = if (bit_depth == 8) 1 else 2;
    const luma_width: usize = @as(usize, macroblock_width) * 16;
    const chroma_macroblock_width: usize = if (is_444) 16 else 8;
    const chroma_width: usize = @as(usize, macroblock_width) * chroma_macroblock_width;
    const frame_height: usize = @as(usize, macroblock_height) * 16;
    const y_size = luma_width * frame_height * bytes_per_sample;
    const chroma_size = chroma_width * frame_height * bytes_per_sample;
    const luma_x = macroblock * 16;
    const chroma_x = macroblock * chroma_macroblock_width;
    const y = @as(usize, row) * 16;
    const line_step: usize = if (interlaced) 2 else 1;
    const bottom_offset: usize = if (interlaced) 1 else 8;

    if (is_444) {
        const plane = (block_index >> 1) % 3;
        const quadrant = block_index / 6 * 2 + block_index % 2;
        const plane_start = plane * y_size;
        const block_x = luma_x + (quadrant % 2) * 8;
        const block_y = y + (quadrant / 2) * bottom_offset;
        storeBlock(plane_start, luma_width, bytes_per_sample, block_x, block_y, 0, line_step);
        return;
    }

    switch (block_index) {
        0 => storeBlock(0, luma_width, bytes_per_sample, luma_x, y, 0, line_step),
        1 => storeBlock(0, luma_width, bytes_per_sample, luma_x + 8, y, 0, line_step),
        2 => storeBlock(y_size, chroma_width, bytes_per_sample, chroma_x, y, 0, line_step),
        3 => storeBlock(y_size + chroma_size, chroma_width, bytes_per_sample, chroma_x, y, 0, line_step),
        4 => storeBlock(0, luma_width, bytes_per_sample, luma_x, y + bottom_offset, 0, line_step),
        5 => storeBlock(0, luma_width, bytes_per_sample, luma_x + 8, y + bottom_offset, 0, line_step),
        6 => storeBlock(y_size, chroma_width, bytes_per_sample, chroma_x, y + bottom_offset, 0, line_step),
        7 => storeBlock(y_size + chroma_size, chroma_width, bytes_per_sample, chroma_x, y + bottom_offset, 0, line_step),
        else => unreachable,
    }
}

fn storeBlock(
    plane_start: usize,
    stride_samples: usize,
    bytes_per_sample: usize,
    x: usize,
    y: usize,
    block: usize,
    line_step: usize,
) void {
    const samples_ptr: [*]u16 = @ptrCast(&samples);
    const sample_start = block * 64;
    if (bytes_per_sample == 1) {
        const frame_ptr: [*]u8 = frame_bytes.ptr;
        for (0..8) |block_row| {
            const output_start = plane_start + (y + block_row * line_step) * stride_samples + x;
            const input_start = sample_start + block_row * 8;
            const source: *align(1) const @Vector(8, u16) = @ptrCast(samples_ptr + input_start);
            const target: *align(1) @Vector(8, u8) = @ptrCast(frame_ptr + output_start);
            target.* = @truncate(source.*);
        }
    } else {
        const frame_ptr: [*]u16 = @ptrCast(frame_bytes.ptr);
        const plane_start_samples = plane_start / 2;
        for (0..8) |block_row| {
            const output_start = plane_start_samples + (y + block_row * line_step) * stride_samples + x;
            const input_start = sample_start + block_row * 8;
            const source: *align(1) const @Vector(8, u16) = @ptrCast(samples_ptr + input_start);
            const target: *align(1) @Vector(8, u16) = @ptrCast(frame_ptr + output_start);
            target.* = source.*;
        }
    }
}

test "native decode oracle frame via export buffers" {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "/tmp/beach-frame0.bin", std.testing.allocator, .limited(2 * 1024 * 1024)) catch return;
    defer std.testing.allocator.free(bytes);
    const data_offset: u32 = 0x280;
    const macroblock_width: u32 = 120;
    const macroblock_height: u32 = 68;
    try std.testing.expectEqual(@as(u32, 0), dnx_reserve_frame(@intCast(bytes.len), macroblock_width * 16 * macroblock_height * 16 * 2));
    @memcpy(packet_bytes[0..bytes.len], bytes);
    const payload_length: u32 = @intCast(bytes.len - data_offset);
    var row: u32 = 0;
    while (row < macroblock_height) : (row += 1) {
        const relative_start = std.mem.readInt(u32, bytes[0x170 + row * 4 ..][0..4], .big);
        const relative_end: u32 = if (row + 1 < macroblock_height)
            std.mem.readInt(u32, bytes[0x170 + (row + 1) * 4 ..][0..4], .big)
        else
            payload_length;
        row_starts[row] = data_offset + relative_start;
        row_ends[row] = data_offset + relative_end;
    }
    const huffman = @import("dnx/huffman.zig");
    const set = huffman.tableForCid(1272).?;
    @memcpy(dc_lookup[0..], set.dc_lookup[0..]);
    @memcpy(ac_lookup[0..], set.ac_lookup[0..]);
    @memcpy(run_lookup[0..], set.run_lookup[0..]);
    @memcpy(ac_info[0..set.ac_info.len], set.ac_info);
    @memcpy(run_values[0..set.run.len], set.run);
    @memcpy(luma_weight[0..], set.luma_weight[0..64]);
    @memcpy(chroma_weight[0..], set.chroma_weight[0..64]);

    const result = dnx_decode_frame(
        @intCast(bytes.len),
        macroblock_width,
        macroblock_height,
        8,
        @intCast(set.ac_info.len),
        @intCast(set.run.len),
        set.eob_index,
        set.index_bits,
        set.level_bias,
        set.level_shift,
        0,
        0,
    );
    try std.testing.expectEqual(@as(u32, 0), result);
}
