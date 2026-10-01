const fast_idct = @import("dnx_fast_idct.zig");
const std = @import("std");

const MAX_ROW_BYTES = 1024 * 1024;
const MAX_PACKET_BYTES = 8 * 1024 * 1024;
const MAX_FRAME_BYTES = 56 * 1024 * 1024;
const MAX_MACROBLOCKS = 256;
const MAX_ROWS = 256;
const MAX_BLOCKS_PER_MACROBLOCK = 12;
const MAX_BLOCKS = MAX_MACROBLOCKS * MAX_BLOCKS_PER_MACROBLOCK;
const LOOKUP_SIZE = 1 << 16;
const MAX_AC_INFO = 1024;
const MAX_RUN_VALUES = 64;

var row_bytes: [MAX_ROW_BYTES]u8 align(16) = undefined;
var packet_bytes: [MAX_PACKET_BYTES]u8 align(16) = undefined;
var row_starts: [MAX_ROWS]u32 align(16) = undefined;
var row_ends: [MAX_ROWS]u32 align(16) = undefined;
var frame_bytes: [MAX_FRAME_BYTES]u8 align(16) = undefined;
var dc_lookup: [LOOKUP_SIZE]u16 align(16) = @as([LOOKUP_SIZE]u16, @splat(0));
var ac_lookup: [LOOKUP_SIZE]u16 align(16) = @as([LOOKUP_SIZE]u16, @splat(0));
var run_lookup: [LOOKUP_SIZE]u16 align(16) = @as([LOOKUP_SIZE]u16, @splat(0));
var ac_info: [MAX_AC_INFO]u16 align(16) = @as([MAX_AC_INFO]u16, @splat(0));
var run_values: [MAX_RUN_VALUES]u8 align(16) = @as([MAX_RUN_VALUES]u8, @splat(0));
var luma_weight: [64]u16 align(16) = @as([64]u16, @splat(0));
var chroma_weight: [64]u16 align(16) = @as([64]u16, @splat(0));
var coefficients: [MAX_BLOCKS * 64]i32 align(16) = undefined;
var samples: [MAX_BLOCKS * 64]u16 align(16) = undefined;
var diagnostic_stage: u32 = 0;
var diagnostic_row: u32 = 0;
var diagnostic_macroblock: u32 = 0;
var diagnostic_block: u32 = 0;
var diagnostic_bit_offset: u32 = 0;

const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const DecodeError = enum(u32) {
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
};

const BitReader = struct {
    bytes: []const u8,
    byte_offset: usize = 0,
    bits_read: usize = 0,
    cache: u64 = 0,
    cached_bits: usize = 0,

    inline fn bitsRemaining(self: *const BitReader) usize {
        return self.cached_bits + (self.bytes.len - self.byte_offset) * 8;
    }

    inline fn readBits(self: *BitReader, count: usize) ?u32 {
        if (count > self.bitsRemaining()) return null;
        if (count == 0) return 0;
        if (self.cached_bits < count) self.refill();
        const value: u32 = @truncate(self.cache >> @intCast(64 - count));
        self.consume(count);
        return value;
    }

    inline fn readSymbol(self: *BitReader, lookup: *const [LOOKUP_SIZE]u16) ?u32 {
        if (self.bitsRemaining() == 0) return null;
        if (self.cached_bits < 16) self.refill();
        const prefix: u16 = @truncate(self.cache >> 48);
        const packed_value = lookup[prefix];
        if (packed_value == 0) return null;
        const bit_count = (packed_value >> 12) + 1;
        if (bit_count > self.bitsRemaining()) return null;
        self.consume(bit_count);
        return (packed_value & 0x0fff) - 1;
    }

    inline fn refill(self: *BitReader) void {
        while (self.cached_bits <= 56 and self.byte_offset < self.bytes.len) {
            const shift: u6 = @intCast(56 - self.cached_bits);
            self.cache |= @as(u64, self.bytes[self.byte_offset]) << shift;
            self.byte_offset += 1;
            self.cached_bits += 8;
        }
    }

    inline fn consume(self: *BitReader, count: usize) void {
        self.cache <<= @intCast(count);
        self.cached_bits -= count;
        self.bits_read += count;
    }
};

pub export fn dnx_row_decoder_version() u32 {
    return 4;
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

pub export fn dnx_packet_buffer_ptr() usize {
    return @intFromPtr(&packet_bytes);
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

pub export fn dnx_frame_buffer_ptr() usize {
    return @intFromPtr(&frame_bytes);
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
    if (packet_length > MAX_PACKET_BYTES or macroblock_width == 0 or macroblock_width > MAX_MACROBLOCKS or
        macroblock_height == 0 or macroblock_height > MAX_ROWS or
        (bit_depth != 8 and bit_depth != 10 and bit_depth != 12) or ac_info_length > MAX_AC_INFO or
        run_values_length > MAX_RUN_VALUES or level_shift > 31 or is_444 > 1 or mbaff > 1)
    {
        return @backingInt(DecodeError.invalid_arguments);
    }
    const bytes_per_sample: u64 = if (bit_depth == 8) 1 else 2;
    const plane_count: u64 = if (is_444 != 0) 3 else 2;
    const frame_byte_length = @as(u64, macroblock_width) * 16 * macroblock_height * 16 * plane_count * bytes_per_sample;
    if (frame_byte_length > MAX_FRAME_BYTES) return @backingInt(DecodeError.invalid_arguments);

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
    var luma_scale: [64]i32 = undefined;
    var chroma_scale: [64]i32 = undefined;
    const maximum: u16 = @intCast((@as(u32, 1) << @intCast(bit_depth)) - 1);
    const dc_shift: u32 = if (bit_depth == 12) 2 else 0;

    var macroblock: usize = 0;
    while (macroblock < macroblock_width) : (macroblock += 1) {
        diagnostic_stage = 2;
        diagnostic_macroblock = @intCast(macroblock);
        diagnostic_bit_offset = @intCast(reader.bits_read);
        const interlaced = if (mbaff)
            (reader.readBits(1) orelse return .macroblock_header) != 0
        else
            false;
        const qscale_value = reader.readBits(if (mbaff) 10 else 11) orelse return .macroblock_header;
        _ = reader.readBits(1) orelse return .macroblock_header;

        const qscale: i32 = @intCast(qscale_value);
        if (qscale != last_qscale) {
            for (0..64) |index| {
                luma_scale[index] = qscale * @as(i32, luma_weight[index]);
                chroma_scale[index] = qscale * @as(i32, chroma_weight[index]);
            }
            last_qscale = qscale;
        }

        const blocks_per_macroblock: usize = if (is_444) 12 else 8;
        for (0..blocks_per_macroblock) |block_index| {
            diagnostic_stage = 3;
            diagnostic_block = @intCast(block_index);
            diagnostic_bit_offset = @intCast(reader.bits_read);
            @memset(coefficients[0..64], 0);
            var has_ac = false;
            const result = decodeBlock(
                &reader,
                0,
                block_index,
                &last_dc,
                &luma_scale,
                &chroma_scale,
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
                diagnostic_bit_offset = @intCast(reader.bits_read);
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

    diagnostic_bit_offset = @intCast(reader.bits_read);
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
    var luma_scale: [64]i32 = undefined;
    var chroma_scale: [64]i32 = undefined;
    const dc_shift: u32 = if (bit_depth == 12) 2 else 0;

    var macroblock: usize = 0;
    while (macroblock < macroblock_width) : (macroblock += 1) {
        diagnostic_stage = 2;
        diagnostic_macroblock = @intCast(macroblock);
        diagnostic_bit_offset = @intCast(reader.bits_read);
        const qscale_value = reader.readBits(11) orelse return .macroblock_header;
        _ = reader.readBits(1) orelse return .macroblock_header;

        const qscale: i32 = @intCast(qscale_value);
        if (qscale != last_qscale) {
            for (0..64) |index| {
                luma_scale[index] = qscale * @as(i32, luma_weight[index]);
                chroma_scale[index] = qscale * @as(i32, chroma_weight[index]);
            }
            last_qscale = qscale;
        }

        for (0..blocks_per_macroblock) |block_index| {
            diagnostic_stage = 3;
            diagnostic_block = @intCast(block_index);
            diagnostic_bit_offset = @intCast(reader.bits_read);
            var has_ac = false;
            const result = decodeBlock(
                &reader,
                macroblock * blocks_per_macroblock + block_index,
                block_index,
                &last_dc,
                &luma_scale,
                &chroma_scale,
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
                diagnostic_bit_offset = @intCast(reader.bits_read);
                return result;
            }
        }
    }

    diagnostic_stage = 4;
    diagnostic_bit_offset = @intCast(reader.bits_read);
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

inline fn decodeBlock(
    reader: *BitReader,
    block: usize,
    block_index: usize,
    last_dc: *[3]i32,
    luma_scale: *const [64]i32,
    chroma_scale: *const [64]i32,
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
    const component: usize = if (is_444)
        (block_index >> 1) % 3
    else if ((block_index & 2) != 0)
        1 + (block_index & 1)
    else
        0;
    const scale = if (component == 0) luma_scale else chroma_scale;
    const weight = if (component == 0) &luma_weight else &chroma_weight;
    const dc_len = reader.readSymbol(&dc_lookup) orelse return .dc_vlc;
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

    const block_offset = block * 64;
    coefficients[block_offset] = last_dc[component];
    var coefficient_index: usize = 0;
    var ac_index = reader.readSymbol(&ac_lookup) orelse return .ac_vlc;
    has_ac.* = ac_index != eob_index;

    while (ac_index != eob_index) {
        const info_index = ac_index * 2;
        if (info_index + 1 >= ac_info_length) return .ac_vlc;
        const level_base: u32 = ac_info[info_index];
        const flags: u16 = ac_info[info_index + 1];
        const sign_bit = reader.readBits(1) orelse return .ac_sign;
        var level = level_base;

        if ((flags & 1) != 0) {
            const extra = reader.readBits(index_bits) orelse return .ac_level;
            level += extra << 7;
        }
        if ((flags & 2) != 0) {
            const run_symbol = reader.readSymbol(&run_lookup) orelse return .run_vlc;
            if (run_symbol >= run_values_length) return .run_vlc;
            coefficient_index += run_values[run_symbol];
        }

        coefficient_index += 1;
        if (coefficient_index > 63) return .coefficient_overrun;
        const natural_index = zigzag[coefficient_index];
        var value: i32 = @as(i32, @intCast(level)) * scale[coefficient_index];
        value += scale[coefficient_index] >> 1;
        if (level_bias < 32 or weight[coefficient_index] != level_bias) value += level_bias;
        value >>= @intCast(level_shift);
        coefficients[block_offset + natural_index] = if (sign_bit != 0) -value else value;
        ac_index = reader.readSymbol(&ac_lookup) orelse return .ac_vlc;
    }
    return .ok;
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
        const frame_ptr: [*]u8 = @ptrCast(&frame_bytes);
        for (0..8) |block_row| {
            const output_start = plane_start + (y + block_row * line_step) * stride_samples + x;
            const input_start = sample_start + block_row * 8;
            const source: *align(1) const @Vector(8, u16) = @ptrCast(samples_ptr + input_start);
            const target: *align(1) @Vector(8, u8) = @ptrCast(frame_ptr + output_start);
            target.* = @truncate(source.*);
        }
    } else {
        const frame_ptr: [*]u16 = @ptrCast(@alignCast(&frame_bytes));
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
