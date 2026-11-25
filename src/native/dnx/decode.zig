//! Progressive DNx decode via the existing Zig row decoder, with planar
//! YUV8 and interleaved RGB8 outputs. 10/12-bit sources are tone-mapped to
//! 8 bits the same way the TypeScript dnxPixelConversion does (linear shift).

const std = @import("std");
const header_mod = @import("header.zig");
const huffman = @import("huffman.zig");
const row_decoder = @import("../dnx_row_decoder.zig");

pub const RgbFrame = struct {
    data: []u8,
    width: u32,
    height: u32,
    stride_bytes: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RgbFrame) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

/// Planar 8-bit YUV at coded (macroblock-aligned) dimensions:
/// Y plane (coded_w × coded_h), then Cb, then Cr (each chroma_w × coded_h,
/// where chroma_w is coded_w/2 for 4:2:2 and coded_w for 4:4:4).
pub const YuvFrame = struct {
    data: []u8,
    width: u32, // display width
    height: u32, // display height
    coded_width: u32,
    coded_height: u32,
    is_444: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *YuvFrame) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

var decode_mutex: std.atomic.Mutex = .unlocked;

/// Decode a DNx packet into an owned planar YUV8 buffer.
pub fn decodeFrameYuv8(allocator: std.mem.Allocator, packet: []const u8) !YuvFrame {
    const hdr = header_mod.parseFrameHeader(packet) orelse return error.InvalidDnxHeader;
    if (!hdr.supported) return error.UnsupportedDnxProfile;
    if (hdr.interlaced) return error.InterlacedNotSupported;
    var table_set = huffman.tableForCid(hdr.cid) orelse return error.UnsupportedDnxCid;

    var spans_buf: [header_mod.max_rows]header_mod.RowSpan = undefined;
    const spans = try header_mod.parseRowSpans(packet, hdr, &spans_buf);

    const coded_w = hdr.macroblock_width * 16;
    const coded_h = hdr.macroblock_height * 16;
    const chroma_w = if (hdr.is_444) coded_w else coded_w / 2;
    const out_len: usize = @as(usize, coded_w) * coded_h + 2 * @as(usize, chroma_w) * coded_h;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    while (!decode_mutex.tryLock()) std.atomic.spinLoopHint();
    defer decode_mutex.unlock();

    if (packet.len > row_decoder.dnx_packet_capacity()) return error.PacketTooLarge;
    const sample_bytes: usize = if (hdr.bit_depth == 8) 1 else 2;
    switch (row_decoder.dnx_reserve_frame(@intCast(packet.len), @intCast(out_len * sample_bytes))) {
        0 => {},
        11 => return error.OutOfMemory,
        else => return error.FrameTooLarge,
    }
    const packet_ptr: [*]u8 = @ptrFromInt(row_decoder.dnx_packet_buffer_ptr());
    @memcpy(packet_ptr[0..packet.len], packet);

    const starts_ptr: [*]u32 = @ptrFromInt(row_decoder.dnx_row_starts_ptr());
    const ends_ptr: [*]u32 = @ptrFromInt(row_decoder.dnx_row_ends_ptr());
    for (spans, 0..) |span, i| {
        starts_ptr[i] = span.start;
        ends_ptr[i] = span.end;
    }

    const dc_ptr: [*]u16 = @ptrFromInt(row_decoder.dnx_dc_lookup_ptr());
    const ac_ptr: [*]u16 = @ptrFromInt(row_decoder.dnx_ac_lookup_ptr());
    const run_ptr: [*]u16 = @ptrFromInt(row_decoder.dnx_run_lookup_ptr());
    @memcpy(dc_ptr[0..huffman.LOOKUP_SIZE], table_set.dc_lookup[0..]);
    @memcpy(ac_ptr[0..huffman.LOOKUP_SIZE], table_set.ac_lookup[0..]);
    @memcpy(run_ptr[0..huffman.LOOKUP_SIZE], table_set.run_lookup[0..]);

    const ac_info_ptr: [*]u16 = @ptrFromInt(row_decoder.dnx_ac_info_ptr());
    @memcpy(ac_info_ptr[0..table_set.ac_info.len], table_set.ac_info);
    const run_values_ptr: [*]u8 = @ptrFromInt(row_decoder.dnx_run_values_ptr());
    @memcpy(run_values_ptr[0..table_set.run.len], table_set.run);
    const luma_ptr: [*]u16 = @ptrFromInt(row_decoder.dnx_luma_weight_ptr());
    const chroma_ptr: [*]u16 = @ptrFromInt(row_decoder.dnx_chroma_weight_ptr());
    @memcpy(luma_ptr[0..64], table_set.luma_weight[0..64]);
    @memcpy(chroma_ptr[0..64], table_set.chroma_weight[0..64]);

    const result = row_decoder.dnx_decode_frame(
        @intCast(packet.len),
        hdr.macroblock_width,
        hdr.macroblock_height,
        hdr.bit_depth,
        @intCast(table_set.ac_info.len),
        @intCast(table_set.run.len),
        table_set.eob_index,
        table_set.index_bits,
        table_set.level_bias,
        table_set.level_shift,
        if (hdr.is_444) 1 else 0,
        if (hdr.mbaff) 1 else 0,
    );
    if (result != 0) return error.DnxDecodeFailed;

    const src_ptr: [*]const u8 = @ptrFromInt(row_decoder.dnx_frame_buffer_ptr());
    if (hdr.bit_depth == 8) {
        @memcpy(out, src_ptr[0..out_len]);
    } else {
        // Row decoder writes u16 samples; tone-map to 8 bits linearly.
        const shift: u4 = if (hdr.bit_depth == 10) 2 else 4;
        const src16: [*]const u16 = @ptrCast(@alignCast(src_ptr));
        for (out, 0..) |*dst, i| dst.* = @intCast(src16[i] >> shift);
    }

    return .{
        .data = out,
        .width = hdr.width,
        .height = hdr.height,
        .coded_width = coded_w,
        .coded_height = coded_h,
        .is_444 = hdr.is_444,
        .allocator = allocator,
    };
}

/// Decode a DNx packet directly to interleaved RGB8 (BT.709 limited range).
pub fn decodeFrameRgb8(allocator: std.mem.Allocator, packet: []const u8) !RgbFrame {
    var yuv = try decodeFrameYuv8(allocator, packet);
    defer yuv.deinit();

    const coded_w = yuv.coded_width;
    const chroma_w = if (yuv.is_444) coded_w else coded_w / 2;
    const y_size: usize = @as(usize, coded_w) * yuv.coded_height;
    const chroma_size: usize = @as(usize, chroma_w) * yuv.coded_height;
    const y_plane = yuv.data[0..y_size];
    const cb_plane = yuv.data[y_size .. y_size + chroma_size];
    const cr_plane = yuv.data[y_size + chroma_size .. y_size + chroma_size * 2];

    const stride: usize = @as(usize, yuv.width) * 3;
    const rgb = try allocator.alloc(u8, stride * yuv.height);
    errdefer allocator.free(rgb);

    var y: u32 = 0;
    while (y < yuv.height) : (y += 1) {
        var x: u32 = 0;
        while (x < yuv.width) : (x += 1) {
            const cx: usize = if (yuv.is_444) x else x / 2;
            const Y: i32 = y_plane[@as(usize, y) * coded_w + x];
            const Cb: i32 = cb_plane[@as(usize, y) * chroma_w + cx];
            const Cr: i32 = cr_plane[@as(usize, y) * chroma_w + cx];
            // BT.709 limited range → full-range RGB
            const y_ = Y - 16;
            const u_ = Cb - 128;
            const v_ = Cr - 128;
            const r = std.math.clamp((298 * y_ + 459 * v_ + 128) >> 8, 0, 255);
            const g = std.math.clamp((298 * y_ - 55 * u_ - 136 * v_ + 128) >> 8, 0, 255);
            const b = std.math.clamp((298 * y_ + 541 * u_ + 128) >> 8, 0, 255);
            const dst = @as(usize, y) * stride + @as(usize, x) * 3;
            rgb[dst] = @intCast(r);
            rgb[dst + 1] = @intCast(g);
            rgb[dst + 2] = @intCast(b);
        }
    }

    return .{
        .data = rgb,
        .width = yuv.width,
        .height = yuv.height,
        .stride_bytes = stride,
        .allocator = allocator,
    };
}
