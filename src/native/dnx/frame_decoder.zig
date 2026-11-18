//! Native DNx frame decoder: thread-safe, decodes macroblock rows in parallel,
//! and can decode at 1/2, 1/4 or 1/8 of the frame's size.
//!
//! Unlike `decode.zig` (which drives the WASM row decoder's module globals
//! one frame at a time behind a mutex), every buffer here belongs to the call,
//! so any number of frames may decode at once, and one frame's macroblock rows
//! are split across threads (each DNx row restarts its DC prediction, so rows
//! are independent).
//!
//! Reduced decoding: each 8x8 block is reconstructed with an n-point inverse
//! DCT (n = 8 >> log2_downscale) of its lowest n x n frequencies, scaled by
//! n / 8 so the block mean is preserved. DNx codes every block to its
//! end-of-block symbol, so the bitstream is still parsed in full; the saving
//! is the inverse transform and everything per pixel after it.

const std = @import("std");
const header_mod = @import("header.zig");
const huffman = @import("huffman.zig");
const decode_mod = @import("decode.zig");
const row = @import("../dnx_row_decoder.zig");
const fast_idct = @import("../dnx_fast_idct.zig");

pub const RgbFrame = decode_mod.RgbFrame;

pub const Error = error{
    InvalidDnxHeader,
    UnsupportedDnxProfile,
    InterlacedNotSupported,
    UnsupportedDnxCid,
    UnsupportedDownscale,
    DnxDecodeFailed,
    TooManyRows,
} || std.mem.Allocator.Error || std.Thread.SpawnError;

pub const Options = struct {
    /// 0 full size, 1 half, 2 quarter, 3 eighth.
    log2_downscale: u2 = 0,
    /// Threads to decode one frame with; 0 picks the CPU count.
    concurrency: u32 = 0,
};

/// Planar Y'CbCr at the decoded (possibly reduced) size, one u16 per sample
/// at the source's bit depth. Planes are `plane_width x plane_height` (Cb and
/// Cr `chroma_width` wide); `width` x `height` is the visible part.
pub const YuvFrame = struct {
    data: []u16,
    width: u32,
    height: u32,
    plane_width: u32,
    chroma_width: u32,
    plane_height: u32,
    bit_depth: u8,
    is_444: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *YuvFrame) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn luma(self: YuvFrame) []u16 {
        return self.data[0 .. @as(usize, self.plane_width) * self.plane_height];
    }
    pub fn cb(self: YuvFrame) []u16 {
        const start = @as(usize, self.plane_width) * self.plane_height;
        return self.data[start..][0 .. @as(usize, self.chroma_width) * self.plane_height];
    }
    pub fn cr(self: YuvFrame) []u16 {
        const start = @as(usize, self.plane_width) * self.plane_height + @as(usize, self.chroma_width) * self.plane_height;
        return self.data[start..][0 .. @as(usize, self.chroma_width) * self.plane_height];
    }
};

/// Decodes `packet` to planar u16 Y'CbCr. Interlaced frames are refused, and a
/// reduced decode of a frame with per-macroblock field coding (MBAFF) is
/// refused rather than approximated.
pub fn decodeYuv16(allocator: std.mem.Allocator, packet: []const u8, options: Options) Error!YuvFrame {
    var job = try Job.init(allocator, packet, options);
    defer job.deinit();
    try job.run(null);
    return job.takeYuv();
}

/// Decodes `packet` to interleaved RGB8 (BT.709 limited range to full range),
/// byte-for-byte what `decode.decodeFrameRgb8` returns at full size.
pub fn decodeRgb8(allocator: std.mem.Allocator, packet: []const u8, options: Options) Error!RgbFrame {
    var job = try Job.init(allocator, packet, options);
    defer job.deinit();
    const stride: usize = @as(usize, job.width) * 3;
    const rgb = try allocator.alloc(u8, stride * job.height);
    errdefer allocator.free(rgb);
    try job.run(rgb);
    return .{ .data = rgb, .width = job.width, .height = job.height, .stride_bytes = stride, .allocator = allocator };
}

const Job = struct {
    allocator: std.mem.Allocator,
    packet: []const u8,
    hdr: header_mod.FrameHeader,
    tables: *huffman.TableSet,
    row_tables: row.Tables,
    spans: [256]header_mod.RowSpan,
    span_count: usize,
    log2: u2,
    concurrency: u32,
    yuv: []u16,
    yuv_taken: bool = false,
    width: u32,
    height: u32,
    plane_width: u32,
    chroma_width: u32,
    plane_height: u32,
    failed: std.atomic.Value(u32) = .init(0),

    fn init(allocator: std.mem.Allocator, packet: []const u8, options: Options) Error!Job {
        const hdr = header_mod.parseFrameHeader(packet) orelse return error.InvalidDnxHeader;
        if (!hdr.supported) return error.UnsupportedDnxProfile;
        if (hdr.interlaced) return error.InterlacedNotSupported;
        if (hdr.mbaff and options.log2_downscale != 0) return error.UnsupportedDownscale;

        const tables = try allocator.create(huffman.TableSet);
        errdefer allocator.destroy(tables);
        tables.* = huffman.tableForCid(hdr.cid) orelse return error.UnsupportedDnxCid;

        var job: Job = .{
            .allocator = allocator,
            .packet = packet,
            .hdr = hdr,
            .tables = tables,
            .row_tables = undefined,
            .spans = undefined,
            .span_count = 0,
            .log2 = options.log2_downscale,
            .concurrency = options.concurrency,
            .yuv = &.{},
            .width = 0,
            .height = 0,
            .plane_width = 0,
            .chroma_width = 0,
            .plane_height = 0,
        };
        if (hdr.macroblock_height > job.spans.len) return error.TooManyRows;
        const spans = header_mod.parseRowSpans(packet, hdr, &job.spans) catch return error.DnxDecodeFailed;
        job.span_count = spans.len;

        const k: u5 = options.log2_downscale;
        const coded_w = hdr.macroblock_width * 16;
        const coded_h = hdr.macroblock_height * 16;
        job.plane_width = coded_w >> k;
        job.plane_height = coded_h >> k;
        job.chroma_width = if (hdr.is_444) job.plane_width else job.plane_width / 2;
        const divisor = @as(u32, 1) << k;
        job.width = (hdr.width + divisor - 1) >> k;
        job.height = (hdr.height + divisor - 1) >> k;
        const samples = @as(usize, job.plane_width) * job.plane_height + 2 * @as(usize, job.chroma_width) * job.plane_height;
        job.yuv = try allocator.alloc(u16, samples);
        return job;
    }

    fn deinit(self: *Job) void {
        if (!self.yuv_taken) self.allocator.free(self.yuv);
        self.allocator.destroy(self.tables);
    }

    fn takeYuv(self: *Job) YuvFrame {
        self.yuv_taken = true;
        return .{
            .data = self.yuv,
            .width = self.width,
            .height = self.height,
            .plane_width = self.plane_width,
            .chroma_width = self.chroma_width,
            .plane_height = self.plane_height,
            .bit_depth = self.hdr.bit_depth,
            .is_444 = self.hdr.is_444,
            .allocator = self.allocator,
        };
    }

    fn run(self: *Job, rgb: ?[]u8) Error!void {
        const t = self.tables;
        self.row_tables = .{
            .dc_lookup = &t.dc_lookup,
            .ac_lookup = &t.ac_lookup,
            .run_lookup = &t.run_lookup,
            .ac_info = t.ac_info,
            .run_values = t.run,
            .luma_weight = t.luma_weight[0..64],
            .chroma_weight = t.chroma_weight[0..64],
            .eob_index = t.eob_index,
            .index_bits = t.index_bits,
            .level_bias = t.level_bias,
            .level_shift = t.level_shift,
        };
        const rows: u32 = self.hdr.macroblock_height;
        var threads: u32 = self.concurrency;
        if (threads == 0) threads = @intCast(std.Thread.getCpuCount() catch 1);
        threads = @max(1, @min(threads, rows));

        var handles: [64]std.Thread = undefined;
        threads = @min(threads, handles.len + 1);
        var spawned: usize = 0;
        defer for (handles[0..spawned]) |h| h.join();
        var band: u32 = 1;
        while (band < threads) : (band += 1) {
            handles[spawned] = try std.Thread.spawn(.{}, bandWorker, .{ self, rgb, band, threads });
            spawned += 1;
        }
        bandWorker(self, rgb, 0, threads);
        for (handles[0..spawned]) |h| h.join();
        spawned = 0;
        if (self.failed.load(.acquire) != 0) return error.DnxDecodeFailed;
    }

    fn bandWorker(self: *Job, rgb: ?[]u8, band: u32, bands: u32) void {
        const rows: u32 = self.hdr.macroblock_height;
        const first = rows * band / bands;
        const last = rows * (band + 1) / bands;
        var r = first;
        while (r < last) : (r += 1) {
            if (self.failed.load(.monotonic) != 0) return;
            if (self.decodeRow(r) != .ok) {
                self.failed.store(1, .release);
                return;
            }
        }
        if (rgb) |out| self.convertRows(out, first, last);
    }

    fn decodeRow(self: *Job, r: u32) row.DecodeError {
        const span = self.spans[r];
        if (span.start > span.end or span.end > self.packet.len) return .invalid_arguments;
        var reader = row.BitReader{ .bytes = self.packet[span.start..span.end] };
        const bit_depth: u32 = self.hdr.bit_depth;
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
        const mbaff = self.hdr.mbaff;
        const is_444 = self.hdr.is_444;
        const blocks_per_macroblock: usize = if (is_444) 12 else 8;
        var coefficients: [64]i32 align(16) = undefined;
        var samples: [64]u16 align(16) = undefined;

        var macroblock: usize = 0;
        while (macroblock < self.hdr.macroblock_width) : (macroblock += 1) {
            const interlaced = if (mbaff)
                (reader.readBits(1) orelse return .macroblock_header) != 0
            else
                false;
            const qscale_value = reader.readBits(if (mbaff) 10 else 11) orelse return .macroblock_header;
            _ = reader.readBits(1) orelse return .macroblock_header;
            const qscale: i32 = @intCast(qscale_value);
            if (qscale != last_qscale) {
                for (0..64) |index| {
                    luma_scale[index] = qscale * @as(i32, self.row_tables.luma_weight[index]);
                    chroma_scale[index] = qscale * @as(i32, self.row_tables.chroma_weight[index]);
                }
                last_qscale = qscale;
            }
            for (0..blocks_per_macroblock) |block_index| {
                @memset(&coefficients, 0);
                var has_ac = false;
                const result = row.decodeBlockInto(&self.row_tables, &reader, &coefficients, block_index, &last_dc, &luma_scale, &chroma_scale, is_444, dc_shift, &has_ac);
                if (result != .ok) return result;
                const n: usize = @as(usize, 8) >> self.log2;
                if (self.log2 == 0) {
                    if (has_ac) {
                        fast_idct.transformBlock(&coefficients, &samples, maximum);
                    } else {
                        fast_idct.transformDcBlock(coefficients[0], &samples, maximum);
                    }
                } else switch (self.log2) {
                    1 => reducedIdct(4, &coefficients, &samples, maximum),
                    2 => reducedIdct(2, &coefficients, &samples, maximum),
                    else => reducedIdct(1, &coefficients, &samples, maximum),
                }
                self.storeBlock(&samples, n, r, macroblock, block_index, interlaced);
            }
        }
        return .ok;
    }

    /// Writes an n x n block of `samples` where block `block_index` of
    /// macroblock (`r`, `macroblock`) lands, at the reduced size.
    fn storeBlock(self: *Job, samples: *const [64]u16, n: usize, r: u32, macroblock: usize, block_index: usize, interlaced: bool) void {
        const plane_width: usize = self.plane_width;
        const chroma_width: usize = self.chroma_width;
        const y_size = plane_width * self.plane_height;
        const chroma_size = chroma_width * self.plane_height;
        // Positions in full-size samples, scaled by n / 8 at the end.
        const luma_x = macroblock * 16;
        const chroma_x = macroblock * (if (self.hdr.is_444) @as(usize, 16) else 8);
        const y = @as(usize, r) * 16;
        const line_step: usize = if (interlaced) 2 else 1;
        const bottom_offset: usize = if (interlaced) 1 else 8;

        var plane_start: usize = 0;
        var stride: usize = plane_width;
        var bx: usize = 0;
        var by: usize = 0;
        if (self.hdr.is_444) {
            const plane = (block_index >> 1) % 3;
            const quadrant = block_index / 6 * 2 + block_index % 2;
            plane_start = plane * y_size;
            bx = luma_x + (quadrant % 2) * 8;
            by = y + (quadrant / 2) * bottom_offset;
        } else switch (block_index) {
            0 => {
                bx = luma_x;
                by = y;
            },
            1 => {
                bx = luma_x + 8;
                by = y;
            },
            2, 3 => {
                plane_start = if (block_index == 2) y_size else y_size + chroma_size;
                stride = chroma_width;
                bx = chroma_x;
                by = y;
            },
            4 => {
                bx = luma_x;
                by = y + bottom_offset;
            },
            5 => {
                bx = luma_x + 8;
                by = y + bottom_offset;
            },
            6, 7 => {
                plane_start = if (block_index == 6) y_size else y_size + chroma_size;
                stride = chroma_width;
                bx = chroma_x;
                by = y + bottom_offset;
            },
            else => unreachable,
        }
        const k: u6 = self.log2;
        const x0 = bx >> k;
        const y0 = by >> k;
        const step = if (self.log2 == 0) line_step else 1;
        for (0..n) |block_row| {
            const output_start = plane_start + (y0 + block_row * step) * stride + x0;
            @memcpy(self.yuv[output_start..][0..n], samples[block_row * n ..][0..n]);
        }
    }

    /// BT.709 limited range to full-range RGB8, the formula `decode.zig` uses,
    /// for the pixel rows macroblock rows `first`..`last` produced.
    fn convertRows(self: *Job, rgb: []u8, first: u32, last: u32) void {
        const shift: u4 = switch (self.hdr.bit_depth) {
            8 => 0,
            10 => 2,
            else => 4,
        };
        switch (shift) {
            inline 0, 2, 4 => |s| if (self.hdr.is_444)
                self.convertRowsAs(true, s, rgb, first, last)
            else
                self.convertRowsAs(false, s, rgb, first, last),
            else => unreachable,
        }
    }

    fn convertRowsAs(self: *Job, comptime is_444: bool, comptime shift: u4, rgb: []u8, first: u32, last: u32) void {
        const rows_per_mb: u32 = @as(u32, 16) >> @as(u5, self.log2);
        const y_begin = first * rows_per_mb;
        const y_end = @min(last * rows_per_mb, self.height);
        const plane_width: usize = self.plane_width;
        const chroma_width: usize = self.chroma_width;
        const y_plane = self.yuv[0 .. plane_width * self.plane_height];
        const cb_plane = self.yuv[y_plane.len..][0 .. chroma_width * self.plane_height];
        const cr_plane = self.yuv[y_plane.len + cb_plane.len ..][0 .. chroma_width * self.plane_height];
        const width: usize = self.width;
        const stride: usize = width * 3;
        var y: usize = y_begin;
        while (y < y_end) : (y += 1) {
            const luma_row = y_plane[y * plane_width ..][0..width];
            const cb_row = cb_plane[y * chroma_width ..];
            const cr_row = cr_plane[y * chroma_width ..];
            const out = rgb[y * stride ..][0..stride];
            for (luma_row, 0..) |sample, x| {
                const cx: usize = if (is_444) x else x / 2;
                const y_: i32 = @as(i32, sample >> shift) - 16;
                const u_: i32 = @as(i32, cb_row[cx] >> shift) - 128;
                const v_: i32 = @as(i32, cr_row[cx] >> shift) - 128;
                out[x * 3] = @intCast(std.math.clamp((298 * y_ + 459 * v_ + 128) >> 8, 0, 255));
                out[x * 3 + 1] = @intCast(std.math.clamp((298 * y_ - 55 * u_ - 136 * v_ + 128) >> 8, 0, 255));
                out[x * 3 + 2] = @intCast(std.math.clamp((298 * y_ + 541 * u_ + 128) >> 8, 0, 255));
            }
        }
    }
};

/// n-point orthonormal DCT-II basis, `basis[n][x * n + u]`.
const bases = blk: {
    @setEvalBranchQuota(100_000);
    var result: [5][16]f32 = undefined;
    for ([_]usize{ 1, 2, 4 }) |n| {
        for (0..n) |x| for (0..n) |u| {
            const c: f64 = if (u == 0) @sqrt(1.0 / @as(f64, n)) else @sqrt(2.0 / @as(f64, n));
            result[n][x * n + u] = @floatCast(c * @cos(std.math.pi * @as(f64, @floatFromInt(2 * x + 1)) * @as(f64, @floatFromInt(u)) / @as(f64, @floatFromInt(2 * n))));
        };
    }
    break :blk result;
};

/// The n x n inverse DCT of the lowest n x n frequencies of `coefficients`
/// (stored `u * 8 + v`), scaled by n / 8, into `out[0 .. n * n]` row-major.
fn reducedIdct(comptime n: usize, coefficients: *const [64]i32, out: *[64]u16, maximum: u16) void {
    const basis = comptime bases[n];
    const scale: f32 = @as(f32, @floatFromInt(n)) / 8.0;
    // tmp[v * n + px] = sum_u F[v][u] * B[px][u], F[v][u] = coefficients[u * 8 + v]
    var tmp: [16]f32 = undefined;
    inline for (0..n) |v| inline for (0..n) |px| {
        var sum: f32 = 0;
        inline for (0..n) |u| sum += @as(f32, @floatFromInt(coefficients[u * 8 + v])) * basis[px * n + u];
        tmp[v * n + px] = sum * scale;
    };
    const max_f: f32 = @floatFromInt(maximum);
    inline for (0..n) |py| inline for (0..n) |px| {
        var sum: f32 = 0;
        inline for (0..n) |v| sum += basis[py * n + v] * tmp[v * n + px];
        const clamped = @min(@max(@floor(sum + 0.5), 0), max_f);
        out[py * n + px] = @intFromFloat(clamped);
    };
}

const testing = std.testing;

/// Progressive, 8-bit 4:2:2 fixtures: what `header.zig` marks supported and
/// `huffman.tableForCid` has tables for.
const progressive_fixtures = [_][]const u8{
    "tests/fixtures/oracle_dnxhd_1080p30_8bit_cid1237.mxf",
    "tests/fixtures/oracle_dnxhd_1080p30_8bit_cid1238.mxf",
    "tests/fixtures/oracle_dnxhd_1080p30_8bit_cid1253.mxf",
    "tests/fixtures/oracle_dnxhd_1440x1080p30_8bit_cid1259.mxf",
    "tests/fixtures/dnxhr-lb-op1a-pcm.mxf",
    "tests/fixtures/dnxhr_hq_328x184.mxf",
};

/// The first packet, or null for a profile the native decoder does not take.
fn readFirstPacket(path: []const u8) ![]u8 {
    const reader_mod = @import("../reader.zig");
    const mxf = @import("../mxf/mod.zig");
    var file = try reader_mod.FileReader.open(testing.io, path);
    defer file.deinit();
    const r = file.reader();
    var demuxed = try mxf.demuxFile(testing.allocator, r, .{});
    defer demuxed.deinit();
    const video = demuxed.primaryVideoTrack() orelse return error.NoVideo;
    var iter = demuxed.packetsForTrack(video);
    const packet_meta = iter.next() orelse return error.NoPackets;
    return demuxed.readPacket(r, packet_meta);
}

/// The frame as the WASM row decoder (`dnx_decode_row`, what the browser
/// decodes with) produces it, one row at a time, placed by this test's own
/// layout code: progressive, non-MBAFF frames only.
fn rowOracle(packet: []const u8) ![]u16 {
    const hdr = header_mod.parseFrameHeader(packet).?;
    const set = huffman.tableForCid(hdr.cid).?;
    @memcpy(@as([*]u16, @ptrFromInt(row.dnx_dc_lookup_ptr()))[0..huffman.LOOKUP_SIZE], set.dc_lookup[0..]);
    @memcpy(@as([*]u16, @ptrFromInt(row.dnx_ac_lookup_ptr()))[0..huffman.LOOKUP_SIZE], set.ac_lookup[0..]);
    @memcpy(@as([*]u16, @ptrFromInt(row.dnx_run_lookup_ptr()))[0..huffman.LOOKUP_SIZE], set.run_lookup[0..]);
    @memcpy(@as([*]u16, @ptrFromInt(row.dnx_ac_info_ptr()))[0..set.ac_info.len], set.ac_info);
    @memcpy(@as([*]u8, @ptrFromInt(row.dnx_run_values_ptr()))[0..set.run.len], set.run);
    @memcpy(@as([*]u16, @ptrFromInt(row.dnx_luma_weight_ptr()))[0..64], set.luma_weight[0..64]);
    @memcpy(@as([*]u16, @ptrFromInt(row.dnx_chroma_weight_ptr()))[0..64], set.chroma_weight[0..64]);
    var spans_buf: [256]header_mod.RowSpan = undefined;
    const spans = try header_mod.parseRowSpans(packet, hdr, &spans_buf);

    const width: usize = hdr.macroblock_width * 16;
    const height: usize = hdr.macroblock_height * 16;
    const chroma_width: usize = if (hdr.is_444) width else width / 2;
    const out = try testing.allocator.alloc(u16, width * height + 2 * chroma_width * height);
    const blocks: usize = if (hdr.is_444) 12 else 8;
    const row_buffer: [*]u8 = @ptrFromInt(row.dnx_row_buffer_ptr());
    const samples: [*]const u16 = @ptrFromInt(row.dnx_samples_ptr());
    for (spans, 0..) |span, r| {
        const bytes = packet[span.start..span.end];
        @memcpy(row_buffer[0..bytes.len], bytes);
        const result = row.dnx_decode_row(@intCast(bytes.len), hdr.macroblock_width, hdr.bit_depth, @intCast(set.ac_info.len), @intCast(set.run.len), set.eob_index, set.index_bits, set.level_bias, set.level_shift, @intFromBool(hdr.is_444));
        if (result != 0) return error.RowDecodeFailed;
        for (0..hdr.macroblock_width) |mb| for (0..blocks) |b| {
            var plane_start: usize = 0;
            var stride = width;
            var x: usize = mb * 16;
            var y: usize = r * 16;
            if (hdr.is_444) {
                const plane = (b >> 1) % 3;
                const quadrant = b / 6 * 2 + b % 2;
                plane_start = plane * width * height;
                x += (quadrant % 2) * 8;
                y += (quadrant / 2) * 8;
            } else {
                if (b & 2 != 0) {
                    plane_start = width * height + (b & 1) * chroma_width * height;
                    stride = chroma_width;
                    x = mb * 8;
                } else {
                    x += (b & 1) * 8;
                }
                if (b >= 4) y += 8;
            }
            const block = samples + (mb * blocks + b) * 64;
            for (0..8) |dy| for (0..8) |dx| {
                out[plane_start + (y + dy) * stride + x + dx] = block[dy * 8 + dx];
            };
        };
    }
    return out;
}

test "full-size decode matches the row decoder sample for sample, on one thread and on many" {
    for (progressive_fixtures) |path| {
        const packet = try readFirstPacket(path);
        defer testing.allocator.free(packet);
        const oracle = try rowOracle(packet);
        defer testing.allocator.free(oracle);
        for ([_]u32{ 1, 3, 8 }) |threads| {
            var frame = try decodeYuv16(testing.allocator, packet, .{ .concurrency = threads });
            defer frame.deinit();
            testing.expectEqualSlices(u16, oracle, frame.data) catch |err| {
                std.debug.print("{s} threads={d}\n", .{ path, threads });
                return err;
            };
        }
    }
}

test "RGB8 from the new decoder is the same on one thread and on many" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    var one = try decodeRgb8(testing.allocator, packet, .{ .concurrency = 1 });
    defer one.deinit();
    var many = try decodeRgb8(testing.allocator, packet, .{ .concurrency = 5 });
    defer many.deinit();
    try testing.expectEqualSlices(u8, one.data, many.data);
}

test "reduced decodes are 1/2, 1/4 and 1/8 the size and close to a box filter of the full frame" {
    var checked: usize = 0;
    for (progressive_fixtures) |path| {
        const packet = try readFirstPacket(path);
        defer testing.allocator.free(packet);
        var full = try decodeYuv16(testing.allocator, packet, .{ .concurrency = 4 });
        defer full.deinit();
        for ([_]u2{ 1, 2, 3 }) |log2| {
            var reduced = try decodeYuv16(testing.allocator, packet, .{ .log2_downscale = log2, .concurrency = 4 });
            defer reduced.deinit();
            const s: u32 = @as(u32, 1) << log2;
            try testing.expectEqual((full.width + s - 1) / s, reduced.width);
            try testing.expectEqual((full.height + s - 1) / s, reduced.height);
            try testing.expectEqual(full.plane_width / s, reduced.plane_width);

            // Luma, in 8-bit units, against the mean of each s x s full-size block
            const shift: u4 = @intCast(full.bit_depth - 8);
            var squared: f64 = 0;
            var count: f64 = 0;
            for (0..full.height / s) |y| for (0..full.width / s) |x| {
                var sum: f64 = 0;
                for (0..s) |dy| for (0..s) |dx| {
                    sum += @floatFromInt(full.luma()[(y * s + dy) * full.plane_width + x * s + dx] >> shift);
                };
                const err = @as(f64, @floatFromInt(reduced.luma()[y * reduced.plane_width + x] >> shift)) - sum / @as(f64, @floatFromInt(s * s));
                squared += err * err;
                count += 1;
            };
            const rmse = @sqrt(squared / count);
            // 1/8 is the block mean exactly; 1/2 and 1/4 are a truncated DCT, not a box
            const limit: f64 = if (log2 == 3) 0.6 else 12;
            std.debug.print("RMSE {s} 1/{d}: {d:.2}\n", .{ path, s, rmse });
            if (rmse >= limit) {
                std.debug.print("{s} 1/{d}: rmse {d:.2}\n", .{ path, s, rmse });
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
    }
    try testing.expectEqual(progressive_fixtures.len * 3, checked);
}

test "reduced RGB8 has the reduced size" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    var frame = try decodeRgb8(testing.allocator, packet, .{ .log2_downscale = 1 });
    defer frame.deinit();
    try testing.expectEqual(@as(u32, 164), frame.width);
    try testing.expectEqual(@as(u32, 92), frame.height);
    try testing.expectEqual(@as(usize, 164 * 3), frame.stride_bytes);
}

test "a corrupt packet fails cleanly on every thread count" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    const header = header_mod.parseFrameHeader(packet).?;
    // Garbage over the coded rows, past the header and row table
    @memset(packet[header.data_offset + 16 ..], 0xff);
    for ([_]u32{ 1, 4 }) |threads| {
        try testing.expectError(error.DnxDecodeFailed, decodeRgb8(testing.allocator, packet, .{ .concurrency = threads }));
    }
}
