//! Native DNx frame decoder: thread-safe, decodes macroblock rows in parallel,
//! and can decode at 1/2, 1/4 or 1/8 of the frame's size.
//!
//! Unlike `decode.zig` (which drives the WASM row decoder's module globals
//! one frame at a time behind a mutex), every buffer a decode writes belongs
//! to it, so any number of frames may decode at once. Each DNx row restarts
//! its DC prediction, so rows are independent: the caller and the shared
//! workers (`worker_pool.zig`) take one row at a time, which keeps fast and
//! slow cores busy alike. RGB and biplanar output go straight from a small
//! per-thread row buffer to the target; only planar output holds a whole frame
//! of u16 samples.
//!
//! Reduced decoding: each 8x8 block is reconstructed with an n-point inverse
//! DCT (n = 8 >> log2_downscale) of its lowest n x n frequencies, scaled by
//! n / 8 so the block mean is preserved. DNx codes every block to its
//! end-of-block symbol, so the bitstream is still parsed in full; the saving
//! is the inverse transform and everything per pixel after it.

const builtin = @import("builtin");
const std = @import("std");
const decode_mod = @import("decode.zig");
const header_mod = @import("header.zig");
const huffman = @import("huffman.zig");
const worker_pool = @import("worker_pool.zig");
const fast_idct = @import("../dnx_fast_idct.zig");
const row = @import("../dnx_row_decoder.zig");

pub const RgbFrame = decode_mod.RgbFrame;

pub const Error = error{
    InvalidDnxHeader,
    UnsupportedDnxProfile,
    InterlacedNotSupported,
    UnsupportedDnxCid,
    UnsupportedDownscale,
    DnxDecodeFailed,
    TooManyRows,
    TargetTooSmall,
} || std.mem.Allocator.Error || std.Thread.SpawnError;

/// Below this much work per thread, waking another costs more than it saves.
pub const rows_per_default_thread = 4;
/// More threads than this stopped helping even at 2160p.
pub const max_default_threads = 16;

pub const Options = struct {
    /// 0 full size, 1 half, 2 quarter, 3 eighth.
    log2_downscale: u2 = 0,
    /// Threads to decode one frame with; 0 picks one per
    /// `rows_per_default_thread` macroblock rows, up to the CPU count and
    /// `max_default_threads`.
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
    var job = try Job.init(packet, options);
    const samples = @as(usize, job.plane_width) * job.plane_height + 2 * @as(usize, job.chroma_width) * job.plane_height;
    const data = try allocator.alloc(u16, samples);
    errdefer allocator.free(data);
    try job.run(.{ .planar = data });
    return .{
        .data = data,
        .width = job.width,
        .height = job.height,
        .plane_width = job.plane_width,
        .chroma_width = job.chroma_width,
        .plane_height = job.plane_height,
        .bit_depth = job.hdr.bit_depth,
        .is_444 = job.hdr.is_444,
        .allocator = allocator,
    };
}

/// Decodes `packet` to interleaved RGB8 (BT.709 limited range to full range),
/// byte-for-byte what `decode.decodeFrameRgb8` returns at full size.
pub fn decodeRgb8(allocator: std.mem.Allocator, packet: []const u8, options: Options) Error!RgbFrame {
    var job = try Job.init(packet, options);
    const stride: usize = @as(usize, job.width) * 3;
    const rgb = try allocator.alloc(u8, stride * job.height);
    errdefer allocator.free(rgb);
    try job.run(.{ .rgb8 = .{ .data = rgb, .stride_bytes = stride } });
    return .{ .data = rgb, .width = job.width, .height = job.height, .stride_bytes = stride, .allocator = allocator };
}

/// A host's biplanar Y'CbCr planes (P010/P210/P410 layout): a luma plane of
/// u16 samples, then interleaved Cb,Cr pairs (one pair per two pixels for
/// 4:2:2, per pixel for 4:4:4), each sample in the high bits of its
/// little-endian u16 whatever the source's bit depth. Each plane holds
/// `height` rows at its stride; bytes past a row's samples are left alone.
pub const Biplanar = struct {
    luma: []u8,
    luma_stride_bytes: usize,
    chroma: []u8,
    chroma_stride_bytes: usize,

    fn fits(self: Biplanar, width: u32, height: u32, is_444: bool) bool {
        if (width == 0 or height == 0) return true;
        const pairs: usize = if (is_444) width else (@as(usize, width) + 1) / 2;
        const luma_row = @as(usize, width) * 2;
        const chroma_row = pairs * 4;
        if (self.luma_stride_bytes < luma_row or self.chroma_stride_bytes < chroma_row) return false;
        const rows = @as(usize, height) - 1;
        return self.luma.len >= rows * self.luma_stride_bytes + luma_row and
            self.chroma.len >= rows * self.chroma_stride_bytes + chroma_row;
    }
};

/// Interleaved RGB8 rows at a stride; bytes past a row's pixels are left alone.
const Rgb8Target = struct {
    data: []u8,
    stride_bytes: usize,

    fn fits(self: Rgb8Target, width: u32, height: u32) bool {
        if (width == 0 or height == 0) return true;
        const row_bytes = @as(usize, width) * 3;
        if (self.stride_bytes < row_bytes) return false;
        return self.data.len >= (@as(usize, height) - 1) * self.stride_bytes + row_bytes;
    }
};

/// One frame's decode in two steps, so a caller can size (or borrow) its
/// planes from the frame's header first: `init` parses the header and knows
/// the output size; a decode then runs on every thread, each thread writing
/// its own rows straight into the target, with no pass over the whole frame
/// after it.
pub const Prepared = struct {
    job: Job,

    pub fn init(allocator: std.mem.Allocator, packet: []const u8, options: Options) Error!Prepared {
        _ = allocator;
        return .{ .job = try Job.init(packet, options) };
    }

    pub fn deinit(self: *Prepared) void {
        self.* = undefined;
    }

    /// The visible size the decode writes (reduced by `log2_downscale`).
    pub fn width(self: Prepared) u32 {
        return self.job.width;
    }
    pub fn height(self: Prepared) u32 {
        return self.job.height;
    }
    pub fn bitDepth(self: Prepared) u8 {
        return self.job.hdr.bit_depth;
    }
    pub fn is444(self: Prepared) bool {
        return self.job.hdr.is_444;
    }

    /// Decodes into `target`; `TargetTooSmall` (nothing written) when its
    /// planes cannot hold `width` x `height`. Call once.
    pub fn decodeBiplanar(self: *Prepared, target: Biplanar) Error!void {
        if (!target.fits(self.job.width, self.job.height, self.job.hdr.is_444)) return error.TargetTooSmall;
        try self.job.run(.{ .biplanar = target });
    }

    /// Decodes to interleaved RGB8 in `target`, as `decodeRgb8` does, so a
    /// host can reuse its frame memory; `TargetTooSmall` (nothing written)
    /// when it cannot hold `width` x `height`. Call once.
    pub fn decodeRgb8Into(self: *Prepared, target: []u8, stride_bytes: usize) Error!void {
        const rgb: Rgb8Target = .{ .data = target, .stride_bytes = stride_bytes };
        if (!rgb.fits(self.job.width, self.job.height)) return error.TargetTooSmall;
        try self.job.run(.{ .rgb8 = rgb });
    }
};

/// The C kernels in `dnx_idct_kernel.c`, on x86-64 CPUs with AVX2.
const simd = struct {
    const compiled = builtin.cpu.arch == .x86_64;

    extern fn dnx_x86_has_avx2() c_int;
    extern fn dnx_idct8_avx2(coefficients: [*]const i32, output: [*]u16, scale: [*]const f32, factors: [*]const f32, maximum: u32) void;
    extern fn dnx_rgb8_line_avx2(luma: [*]const u16, cb: [*]const u16, cr: [*]const u16, out: [*]u8, width: usize, shift: u32, is_444: c_int) usize;
    extern fn dnx_shift_line_avx2(samples: [*]const u16, out: [*]u8, count: usize, shift: u32) usize;
    extern fn dnx_interleave_line_avx2(cb: [*]const u16, cr: [*]const u16, out: [*]u8, pairs: usize, shift: u32) usize;

    const unknown = 0;
    const absent = 1;
    const present = 2;
    var detected: std.atomic.Value(u8) = .init(unknown);
    /// Tests clear this to exercise the portable paths on any machine.
    var enabled = true;

    fn available() bool {
        if (!compiled or !enabled) return false;
        var state = detected.load(.monotonic);
        if (state == unknown) {
            state = if (dnx_x86_has_avx2() != 0) present else absent;
            detected.store(state, .monotonic);
        }
        return state == present;
    }

    inline fn idct8(coefficients: *const [64]i32, samples: *[64]u16, maximum: u16) void {
        dnx_idct8_avx2(coefficients, samples, &fast_idct.scale_matrix, &fast_idct.idct_factors, maximum);
    }

    inline fn rgb8Line(luma: [*]const u16, cb: [*]const u16, cr: [*]const u16, out: [*]u8, width: usize, shift: u4, is_444: bool) usize {
        return dnx_rgb8_line_avx2(luma, cb, cr, out, width, shift, @intFromBool(is_444));
    }

    inline fn shiftLine(samples: []const u16, out: []u8, shift: u4) usize {
        return dnx_shift_line_avx2(samples.ptr, out.ptr, samples.len, shift);
    }

    inline fn interleaveLine(cb: []const u16, cr: []const u16, out: []u8, shift: u4) usize {
        return dnx_interleave_line_avx2(cb.ptr, cr.ptr, out.ptr, cb.len, shift);
    }
};

/// Where each decoded macroblock row goes.
const Output = union(enum) {
    planar: []u16,
    rgb8: Rgb8Target,
    biplanar: Biplanar,
};

/// One macroblock row's planes: into the planar frame, or a row buffer.
const RowPlanes = struct {
    luma: [*]u16,
    cb: [*]u16,
    cr: [*]u16,
    luma_stride: usize,
    chroma_stride: usize,
};

const failure_decode = 1;
const failure_memory = 2;

const Job = struct {
    packet: []const u8,
    hdr: header_mod.FrameHeader,
    row_tables: row.Tables,
    spans: [header_mod.max_rows]header_mod.RowSpan,
    span_count: usize,
    log2: u2,
    concurrency: u32,
    width: u32,
    height: u32,
    plane_width: u32,
    chroma_width: u32,
    plane_height: u32,
    output: Output = undefined,
    use_avx2: bool = false,
    task: worker_pool.Task = undefined,
    next_row: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    failed: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    fn init(packet: []const u8, options: Options) Error!Job {
        const hdr = header_mod.parseFrameHeader(packet) orelse return error.InvalidDnxHeader;
        if (!hdr.supported) return error.UnsupportedDnxProfile;
        if (hdr.interlaced) return error.InterlacedNotSupported;
        if (hdr.mbaff and options.log2_downscale != 0) return error.UnsupportedDownscale;
        const t = huffman.sharedTableForCid(hdr.cid) orelse return error.UnsupportedDnxCid;

        var job: Job = .{
            .packet = packet,
            .hdr = hdr,
            .row_tables = .{
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
                .fast = &t.fast,
            },
            .spans = undefined,
            .span_count = 0,
            .log2 = options.log2_downscale,
            .concurrency = options.concurrency,
            .width = 0,
            .height = 0,
            .plane_width = 0,
            .chroma_width = 0,
            .plane_height = 0,
        };
        // The coded rows must cover the picture: storage is allocated for
        // the visible size, and only coded rows are ever written.
        if (hdr.macroblock_height == 0 or @as(u32, hdr.macroblock_height) * 16 < hdr.height) return error.InvalidDnxHeader;
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
        return job;
    }

    fn run(self: *Job, output: Output) Error!void {
        self.output = output;
        self.use_avx2 = simd.available();
        self.next_row.store(0, .monotonic);
        self.failed.store(0, .monotonic);
        const rows: u32 = self.hdr.macroblock_height;
        var threads: u32 = self.concurrency;
        if (threads == 0) {
            const cores: u32 = @intCast(std.Thread.getCpuCount() catch 1);
            threads = @min(cores, max_default_threads, rows / rows_per_default_thread);
        }
        threads = @max(1, @min(threads, rows));
        if (threads == 1) {
            self.work();
        } else {
            self.task = .{ .run_fn = taskMain };
            worker_pool.run(&self.task, threads - 1);
        }
        return switch (self.failed.load(.acquire)) {
            0 => {},
            failure_memory => error.OutOfMemory,
            else => error.DnxDecodeFailed,
        };
    }

    fn taskMain(task: *worker_pool.Task) void {
        const self: *Job = @alignCast(@fieldParentPtr("task", task));
        self.work();
    }

    fn work(self: *Job) void {
        switch (self.log2) {
            inline 0, 1, 2, 3 => |k| if (self.hdr.is_444) self.workAs(k, true) else self.workAs(k, false),
        }
    }

    /// Takes rows until none are left, or another thread has failed.
    fn workAs(self: *Job, comptime k: u2, comptime is_444: bool) void {
        const rows_per_mb: usize = @as(usize, 16) >> k;
        const plane_width: usize = self.plane_width;
        const chroma_width: usize = self.chroma_width;
        const rows: u32 = self.hdr.macroblock_height;

        var buffer: ?worker_pool.Buffer = null;
        defer if (buffer) |held| worker_pool.releaseBuffer(held);
        var buffered: RowPlanes = undefined;
        if (self.output != .planar) {
            const samples = (plane_width + 2 * chroma_width) * rows_per_mb;
            const held = worker_pool.acquireBuffer(samples * @sizeOf(u16)) catch {
                self.failed.store(failure_memory, .release);
                return;
            };
            buffer = held;
            const base: [*]u16 = @ptrCast(held.ptr);
            buffered = .{
                .luma = base,
                .cb = base + plane_width * rows_per_mb,
                .cr = base + (plane_width + chroma_width) * rows_per_mb,
                .luma_stride = plane_width,
                .chroma_stride = chroma_width,
            };
        }

        while (self.failed.load(.monotonic) == 0) {
            const r = self.next_row.fetchAdd(1, .monotonic);
            if (r >= rows) return;
            const y = @as(usize, r) * rows_per_mb;
            const planes = switch (self.output) {
                .planar => |data| self.frameRow(data, y),
                else => buffered,
            };
            if (self.decodeRow(k, is_444, r, planes) != .ok) {
                self.failed.store(failure_decode, .release);
                return;
            }
            if (y >= self.height) continue;
            const lines = @min(rows_per_mb, self.height - y);
            switch (self.output) {
                .planar => {},
                .rgb8 => |target| self.convertLines(is_444, target, planes, y, lines),
                .biplanar => |target| self.packLines(is_444, target, planes, y, lines),
            }
        }
    }

    fn frameRow(self: *const Job, data: []u16, y: usize) RowPlanes {
        const plane_width: usize = self.plane_width;
        const chroma_width: usize = self.chroma_width;
        const luma_size = plane_width * self.plane_height;
        const chroma_size = chroma_width * self.plane_height;
        return .{
            .luma = data.ptr + y * plane_width,
            .cb = data.ptr + luma_size + y * chroma_width,
            .cr = data.ptr + luma_size + chroma_size + y * chroma_width,
            .luma_stride = plane_width,
            .chroma_stride = chroma_width,
        };
    }

    fn decodeRow(self: *const Job, comptime k: u2, comptime is_444: bool, r: u32, planes: RowPlanes) row.DecodeError {
        const n: usize = @as(usize, 8) >> k;
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
        var luma_quantiser: row.Quantiser = undefined;
        var chroma_quantiser: row.Quantiser = undefined;
        const maximum: u16 = @intCast((@as(u32, 1) << @intCast(bit_depth)) - 1);
        const dc_shift: u32 = if (bit_depth == 12) 2 else 0;
        const mbaff = self.hdr.mbaff;
        const blocks_per_macroblock: usize = if (is_444) 12 else 8;
        var coefficients: [64]i32 align(32) = undefined;
        var coefficients_dirty = true;
        var samples: [64]u16 align(32) = undefined;

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
                luma_quantiser.fill(qscale, self.row_tables.luma_weight, self.row_tables.level_bias);
                chroma_quantiser.fill(qscale, self.row_tables.chroma_weight, self.row_tables.level_bias);
                last_qscale = qscale;
            }
            for (0..blocks_per_macroblock) |block_index| {
                // A block with no AC wrote only its DC, which the next overwrites.
                if (coefficients_dirty) @memset(&coefficients, 0);
                var has_ac = false;
                const result = row.decodeBlockInto(&self.row_tables, &reader, &coefficients, block_index, &last_dc, &luma_quantiser, &chroma_quantiser, is_444, dc_shift, &has_ac);
                if (result != .ok) return result;
                coefficients_dirty = has_ac;
                if (k == 0) {
                    if (has_ac) {
                        if (simd.compiled and self.use_avx2) {
                            simd.idct8(&coefficients, &samples, maximum);
                        } else {
                            fast_idct.transformBlock(&coefficients, &samples, maximum);
                        }
                    } else {
                        fast_idct.transformDcBlock(coefficients[0], &samples, maximum);
                    }
                } else if (has_ac) {
                    reducedIdct(n, &coefficients, &samples, maximum);
                } else {
                    reducedDc(n, coefficients[0], &samples, maximum);
                }
                storeBlock(k, is_444, &samples, planes, macroblock, block_index, interlaced);
            }
        }
        return .ok;
    }

    /// Writes an n x n block of `samples` where block `block_index` of
    /// `macroblock` lands in its row's planes, at the reduced size.
    inline fn storeBlock(comptime k: u2, comptime is_444: bool, samples: *const [64]u16, planes: RowPlanes, macroblock: usize, block_index: usize, interlaced: bool) void {
        const n: usize = @as(usize, 8) >> k;
        // Positions in full-size samples, scaled by n / 8 at the end.
        const luma_x = macroblock * 16;
        const bottom_offset: usize = if (interlaced) 1 else 8;
        var target: [*]u16 = planes.luma;
        var stride: usize = planes.luma_stride;
        var bx: usize = undefined;
        var by: usize = undefined;
        if (is_444) {
            const plane = (block_index >> 1) % 3;
            const quadrant = block_index / 6 * 2 + block_index % 2;
            if (plane != 0) {
                target = if (plane == 1) planes.cb else planes.cr;
                stride = planes.chroma_stride;
            }
            bx = luma_x + (quadrant % 2) * 8;
            by = (quadrant / 2) * bottom_offset;
        } else {
            by = if (block_index >= 4) bottom_offset else 0;
            if (block_index & 2 != 0) {
                target = if (block_index & 1 == 0) planes.cb else planes.cr;
                stride = planes.chroma_stride;
                bx = macroblock * 8;
            } else {
                bx = luma_x + (block_index & 1) * 8;
            }
        }
        const x0 = bx >> k;
        const y0 = by >> k;
        // Field-coded macroblocks only reach here at full size.
        const step: usize = if (k == 0 and interlaced) 2 else 1;
        for (0..n) |block_row| {
            const line = target + (y0 + block_row * step) * stride + x0;
            line[0..n].* = samples[block_row * n ..][0..n].*;
        }
    }

    /// BT.709 limited range to full-range RGB8, the formula `decode.zig` uses.
    fn convertLines(self: *const Job, comptime is_444: bool, target: Rgb8Target, planes: RowPlanes, y: usize, lines: usize) void {
        switch (self.hdr.bit_depth) {
            inline 8, 10, 12 => |depth| {
                const shift: u4 = depth - 8;
                for (0..lines) |line| {
                    convertLine(
                        is_444,
                        shift,
                        planes.luma + line * planes.luma_stride,
                        planes.cb + line * planes.chroma_stride,
                        planes.cr + line * planes.chroma_stride,
                        target.data.ptr + (y + line) * target.stride_bytes,
                        self.width,
                        self.use_avx2,
                    );
                }
            },
            else => unreachable,
        }
    }

    /// The rows' samples, into the host's biplanar planes with each sample
    /// moved to the u16's high bits.
    fn packLines(self: *const Job, comptime is_444: bool, target: Biplanar, planes: RowPlanes, y: usize, lines: usize) void {
        switch (self.hdr.bit_depth) {
            inline 8, 10, 12 => |depth| {
                const shift: u4 = 16 - depth;
                const width: usize = self.width;
                const pairs: usize = if (is_444) width else (width + 1) / 2;
                for (0..lines) |line| {
                    const luma_in = (planes.luma + line * planes.luma_stride)[0..width];
                    const luma_out = target.luma[(y + line) * target.luma_stride_bytes ..][0 .. width * 2];
                    const luma_done: usize = if (simd.compiled and self.use_avx2) simd.shiftLine(luma_in, luma_out, shift) else 0;
                    for (luma_in[luma_done..], luma_done..) |sample, x| std.mem.writeInt(u16, luma_out[x * 2 ..][0..2], sample << shift, .little);
                    const cb_in = (planes.cb + line * planes.chroma_stride)[0..pairs];
                    const cr_in = (planes.cr + line * planes.chroma_stride)[0..pairs];
                    const chroma_out = target.chroma[(y + line) * target.chroma_stride_bytes ..][0 .. pairs * 4];
                    const pairs_done: usize = if (simd.compiled and self.use_avx2) simd.interleaveLine(cb_in, cr_in, chroma_out, shift) else 0;
                    for (cb_in[pairs_done..], cr_in[pairs_done..], pairs_done..) |cb, cr, x| {
                        std.mem.writeInt(u16, chroma_out[x * 4 ..][0..2], cb << shift, .little);
                        std.mem.writeInt(u16, chroma_out[x * 4 + 2 ..][0..2], cr << shift, .little);
                    }
                }
            },
            else => unreachable,
        }
    }
};

inline fn clampByte(value: i32) u8 {
    return @intCast(std.math.clamp(value >> 8, 0, 255));
}

inline fn writeRgb(out: [*]u8, luma: i32, red: i32, green: i32, blue: i32) void {
    out[0] = clampByte(luma + red);
    out[1] = clampByte(luma + green);
    out[2] = clampByte(luma + blue);
}

fn convertLine(comptime is_444: bool, comptime shift: u4, luma: [*]const u16, cb: [*]const u16, cr: [*]const u16, out: [*]u8, width: usize, use_avx2: bool) void {
    const samples_per_chroma: usize = if (is_444) 1 else 2;
    var x: usize = if (simd.compiled and use_avx2) simd.rgb8Line(luma, cb, cr, out, width, shift, is_444) else 0;
    var chroma: usize = x / samples_per_chroma;
    while (x < width) : (chroma += 1) {
        const u: i32 = @as(i32, cb[chroma] >> shift) - 128;
        const v: i32 = @as(i32, cr[chroma] >> shift) - 128;
        const red = 459 * v + 128;
        const green = -55 * u - 136 * v + 128;
        const blue = 541 * u + 128;
        const end = @min(x + samples_per_chroma, width);
        while (x < end) : (x += 1) {
            const y: i32 = 298 * (@as(i32, luma[x] >> shift) - 16);
            writeRgb(out + x * 3, y, red, green, blue);
        }
    }
}

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

/// `floor(value + 0.5)` clamped to 0..maximum. Clamping first makes the value
/// non-negative, where truncation is the floor, without a floor call.
inline fn roundedSample(value: f32, maximum: f32) u16 {
    return @intFromFloat(@min(@max(value + 0.5, 0), maximum));
}

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
        out[py * n + px] = roundedSample(sum, max_f);
    };
}

/// `reducedIdct` of a block with only its DC coefficient: every sample is the
/// same, so one is computed.
fn reducedDc(comptime n: usize, dc: i32, out: *[64]u16, maximum: u16) void {
    const basis = comptime bases[n][0];
    const scale: f32 = @as(f32, @floatFromInt(n)) / 8.0;
    const value = basis * ((@as(f32, @floatFromInt(dc)) * basis) * scale);
    @memset(out[0 .. n * n], roundedSample(value, @floatFromInt(maximum)));
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
    var spans_buf: [header_mod.max_rows]header_mod.RowSpan = undefined;
    const spans = try header_mod.parseRowSpans(packet, hdr, &spans_buf);

    const width: usize = hdr.macroblock_width * 16;
    const height: usize = hdr.macroblock_height * 16;
    const chroma_width: usize = if (hdr.is_444) width else width / 2;
    const out = try testing.allocator.alloc(u16, width * height + 2 * chroma_width * height);
    const blocks: usize = if (hdr.is_444) 12 else 8;
    const row_buffer: [*]u8 = @ptrFromInt(row.dnx_row_buffer_ptr());
    const samples: [*]const u16 = @ptrFromInt(row.dnx_samples_ptr());
    for (spans, 0..) |span, r| {
        // The last row's span runs to the end of the padded payload, past
        // the row buffer at 4K and up; the decoder stops after the row's
        // macroblocks, so the browser's row workers copy at most this much.
        const bytes = packet[span.start..@min(span.end, span.start + row.dnx_row_capacity())];
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

test "8K DCI (8192x4320, 270 rows of 512 macroblocks) matches the row decoder" {
    const gz = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/dnxhr_hq_8192x4320_smptehdbars.mxf.gz", testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(gz);
    var compressed: std.Io.Reader = .fixed(gz);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&compressed, .gzip, &window);
    const container = try inflate.reader.allocRemaining(testing.allocator, .limited(64 * 1024 * 1024));
    defer testing.allocator.free(container);
    const reader_mod = @import("../reader.zig");
    const mxf = @import("../mxf/mod.zig");
    var source: reader_mod.SliceReader = .{ .bytes = container };
    const r = source.reader();
    var demuxed = try mxf.demuxFile(testing.allocator, r, .{});
    defer demuxed.deinit();
    var iter = demuxed.packetsForTrack(demuxed.primaryVideoTrack() orelse return error.NoVideo);
    const packet = try demuxed.readPacket(r, iter.next() orelse return error.NoPackets);
    defer testing.allocator.free(packet);
    const hdr = header_mod.parseFrameHeader(packet).?;
    try testing.expectEqual(@as(u32, 512), hdr.macroblock_width);
    try testing.expectEqual(@as(u32, 270), hdr.macroblock_height);

    const oracle = try rowOracle(packet);
    defer testing.allocator.free(oracle);
    for ([_]u32{ 1, 8 }) |threads| {
        var frame = try decodeYuv16(testing.allocator, packet, .{ .concurrency = threads });
        defer frame.deinit();
        try testing.expectEqual(@as(u32, 8192), frame.width);
        try testing.expectEqual(@as(u32, 4320), frame.height);
        try testing.expectEqualSlices(u16, oracle, frame.data);
    }
}

test "the portable paths match the row decoder and the AVX2 output" {
    defer simd.enabled = true;
    for (progressive_fixtures) |path| {
        const packet = try readFirstPacket(path);
        defer testing.allocator.free(packet);
        const oracle = try rowOracle(packet);
        defer testing.allocator.free(oracle);
        simd.enabled = true;
        var fast_rgb = try decodeRgb8(testing.allocator, packet, .{ .concurrency = 2 });
        defer fast_rgb.deinit();
        simd.enabled = false;
        var portable = try decodeYuv16(testing.allocator, packet, .{ .concurrency = 2 });
        defer portable.deinit();
        try testing.expectEqualSlices(u16, oracle, portable.data);
        var portable_rgb = try decodeRgb8(testing.allocator, packet, .{ .concurrency = 2 });
        defer portable_rgb.deinit();
        try testing.expectEqualSlices(u8, portable_rgb.data, fast_rgb.data);

        const width: usize = fast_rgb.width;
        const pairs = if (portable.is_444) width else (width + 1) / 2;
        const size = width * 2 * fast_rgb.height + pairs * 4 * fast_rgb.height;
        const planes = try testing.allocator.alloc(u8, size * 2);
        defer testing.allocator.free(planes);
        var decoded: [2][]u8 = undefined;
        for ([_]bool{ true, false }, 0..) |enabled, index| {
            simd.enabled = enabled;
            const memory = planes[index * size ..][0..size];
            const luma_size = width * 2 * fast_rgb.height;
            var prepared = try Prepared.init(testing.allocator, packet, .{ .concurrency = 2 });
            defer prepared.deinit();
            try prepared.decodeBiplanar(.{ .luma = memory[0..luma_size], .luma_stride_bytes = width * 2, .chroma = memory[luma_size..], .chroma_stride_bytes = pairs * 4 });
            decoded[index] = memory;
        }
        try testing.expectEqualSlices(u8, decoded[1], decoded[0]);
    }
}

test "the AVX2 inverse DCT matches the portable one on extreme and random blocks" {
    if (!simd.compiled or !simd.available()) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x1dc7);
    const random = prng.random();
    for (0..20_000) |round| {
        var coefficients: [64]i32 align(32) = undefined;
        const limit: i32 = switch (round % 4) {
            0 => 16,
            1 => 512,
            2 => 8192,
            else => 1 << 20,
        };
        for (&coefficients) |*value| value.* = if (round % 3 == 0 and random.boolean()) 0 else random.intRangeAtMost(i32, -limit, limit);
        for ([_]u16{ 255, 1023, 4095 }) |maximum| {
            var portable: [64]u16 align(32) = undefined;
            var fast: [64]u16 align(32) = undefined;
            fast_idct.transformBlock(&coefficients, &portable, maximum);
            simd.idct8(&coefficients, &fast, maximum);
            try testing.expectEqualSlices(u16, &portable, &fast);
        }
    }
}

test "AVX2 RGB conversion matches the portable loop and writes only its pixels" {
    if (!simd.compiled or !simd.available()) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x4262);
    const random = prng.random();
    const Check = struct {
        fn run(comptime is_444: bool, comptime shift: u4, rand: std.Random) !void {
            const top: u16 = (@as(u16, 256) << shift) - 1;
            var luma: [97]u16 = undefined;
            var cb: [97]u16 = undefined;
            var cr: [97]u16 = undefined;
            for (0..200) |_| {
                for (&luma, &cb, &cr) |*y, *u, *v| {
                    y.* = rand.intRangeAtMost(u16, 0, top);
                    u.* = rand.intRangeAtMost(u16, 0, top);
                    v.* = rand.intRangeAtMost(u16, 0, top);
                }
                const width = rand.intRangeAtMost(usize, 0, luma.len);
                var portable: [97 * 3 + 8]u8 = @splat(0xa5);
                var fast: [97 * 3 + 8]u8 = @splat(0xa5);
                convertLine(is_444, shift, &luma, &cb, &cr, &portable, width, false);
                convertLine(is_444, shift, &luma, &cb, &cr, &fast, width, true);
                try testing.expectEqualSlices(u8, &portable, &fast);
            }
        }
    };
    inline for ([_]u4{ 0, 2, 4 }) |shift| {
        try Check.run(false, shift, random);
        try Check.run(true, shift, random);
    }
}

test "a corrupt or cut-off packet fails the same with and without the fast bit reads" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    const header = header_mod.parseFrameHeader(packet).?;
    var spans_buffer: [header_mod.max_rows]header_mod.RowSpan = undefined;
    const spans = try header_mod.parseRowSpans(packet, header, &spans_buffer);
    const t = huffman.sharedTableForCid(header.cid).?;
    const tables: row.Tables = .{
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
        .fast = &t.fast,
    };
    // The same stream, cut at every length: batching only applies with bits to
    // spare, so both ways of reading must stop at the same place.
    const whole = packet[spans[0].start..spans[0].end];
    var length: usize = 0;
    while (length < @min(whole.len, 2000)) : (length += 7) {
        const batched = decodeRowStatus(&tables, whole[0..length], false);
        const unbatched = decodeRowStatus(&tables, whole[0..length], true);
        try testing.expectEqual(unbatched, batched);
    }

    // Damaged streams reach every error path: the first-level tables must
    // stop where the checked reads stop, with the same coefficients.
    const damaged = try testing.allocator.dupe(u8, whole[0..@min(whole.len, 2000)]);
    defer testing.allocator.free(damaged);
    var random = std.Random.DefaultPrng.init(0x564333);
    var failures: usize = 0;
    for (0..3000) |_| {
        @memcpy(damaged, whole[0..damaged.len]);
        for (0..random.random().intRangeAtMost(usize, 1, 4)) |_| {
            damaged[random.random().uintLessThan(usize, damaged.len)] ^= @as(u8, 1) << random.random().int(u3);
        }
        const batched = decodeRowStatus(&tables, damaged, false);
        const unbatched = decodeRowStatus(&tables, damaged, true);
        try testing.expectEqual(unbatched, batched);
        if (batched[0] != .ok) failures += 1;
    }
    try testing.expect(failures > 0);
}

/// How far one macroblock row's blocks get: the status, the bits consumed and
/// a hash of what was decoded.
fn decodeRowStatus(tables: *const row.Tables, bytes: []const u8, disable_batching: bool) struct { row.DecodeError, usize, u64 } {
    var local = tables.*;
    var reader = row.BitReader{ .bytes = bytes };
    if (disable_batching) local.batch_reads = false;
    var last_dc = [3]i32{ 1 << 10, 1 << 10, 1 << 10 };
    var luma: row.Quantiser = undefined;
    var chroma: row.Quantiser = undefined;
    luma.fill(32, local.luma_weight, local.level_bias);
    chroma.fill(32, local.chroma_weight, local.level_bias);
    var coefficients: [64]i32 = undefined;
    var hash = std.hash.Wyhash.init(0);
    for (0..400) |block| {
        @memset(&coefficients, 0);
        var has_ac = false;
        const result = row.decodeBlockInto(&local, &reader, &coefficients, block % 8, &last_dc, &luma, &chroma, false, 0, &has_ac);
        hash.update(std.mem.asBytes(&coefficients));
        if (result != .ok) return .{ result, reader.bitsRead(), hash.final() };
        hash.update(&.{@intFromBool(has_ac)});
    }
    return .{ .ok, reader.bitsRead(), hash.final() };
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

test "a header whose coded rows do not cover the picture is refused" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    // Macroblock rows at 0x16c: none, then one short of 184 lines (12 rows)
    for ([_]u16{ 0, 11 }) |rows| {
        std.mem.writeInt(u16, packet[0x16c..][0..2], rows, .big);
        for ([_]u2{ 0, 1 }) |log2| {
            try testing.expectError(error.InvalidDnxHeader, decodeRgb8(testing.allocator, packet, .{ .log2_downscale = log2 }));
            try testing.expectError(error.InvalidDnxHeader, decodeYuv16(testing.allocator, packet, .{ .log2_downscale = log2 }));
        }
    }
}

test "biplanar output is the planar decode moved to the high bits, at every size and thread count" {
    var checked: usize = 0;
    for (progressive_fixtures) |path| {
        const packet = try readFirstPacket(path);
        defer testing.allocator.free(packet);
        for ([_]u2{ 0, 1, 2, 3 }) |log2| {
            var planar = decodeYuv16(testing.allocator, packet, .{ .log2_downscale = log2, .concurrency = 1 }) catch |err| switch (err) {
                error.UnsupportedDownscale => continue,
                else => return err,
            };
            defer planar.deinit();
            const shift: u4 = @intCast(16 - planar.bit_depth);
            const pairs: usize = if (planar.is_444) planar.width else (@as(usize, planar.width) + 1) / 2;
            // Strides wider than a row, and padding the decode must not touch.
            const luma_stride = @as(usize, planar.width) * 2 + 6;
            const chroma_stride = pairs * 4 + 10;
            const luma = try testing.allocator.alloc(u8, luma_stride * planar.height);
            defer testing.allocator.free(luma);
            const chroma = try testing.allocator.alloc(u8, chroma_stride * planar.height);
            defer testing.allocator.free(chroma);
            for ([_]u32{ 1, 3, 8 }) |threads| {
                @memset(luma, 0xa5);
                @memset(chroma, 0xa5);
                var prepared = try Prepared.init(testing.allocator, packet, .{ .log2_downscale = log2, .concurrency = threads });
                defer prepared.deinit();
                try testing.expectEqual(planar.width, prepared.width());
                try testing.expectEqual(planar.height, prepared.height());
                try prepared.decodeBiplanar(.{ .luma = luma, .luma_stride_bytes = luma_stride, .chroma = chroma, .chroma_stride_bytes = chroma_stride });
                for (0..planar.height) |y| {
                    for (0..planar.width) |x| {
                        const got = std.mem.readInt(u16, luma[y * luma_stride + x * 2 ..][0..2], .little);
                        try testing.expectEqual(planar.luma()[y * planar.plane_width + x] << shift, got);
                    }
                    for (0..pairs) |x| {
                        const cb = std.mem.readInt(u16, chroma[y * chroma_stride + x * 4 ..][0..2], .little);
                        const cr = std.mem.readInt(u16, chroma[y * chroma_stride + x * 4 + 2 ..][0..2], .little);
                        try testing.expectEqual(planar.cb()[y * planar.chroma_width + x] << shift, cb);
                        try testing.expectEqual(planar.cr()[y * planar.chroma_width + x] << shift, cr);
                    }
                    for (luma[y * luma_stride + @as(usize, planar.width) * 2 ..][0..6]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
                    for (chroma[y * chroma_stride + pairs * 4 ..][0..10]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
                }
                checked += 1;
            }
        }
    }
    try testing.expect(checked > 0);
}

test "biplanar output refuses planes too small for the frame" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    var prepared = try Prepared.init(testing.allocator, packet, .{ .log2_downscale = 3 });
    defer prepared.deinit();
    // 1/8 of 328x184 is 41x23: an odd width, so 21 chroma pairs a row.
    try testing.expectEqual(@as(u32, 41), prepared.width());
    var luma: [82 * 23]u8 = undefined;
    var chroma: [84 * 23]u8 = undefined;
    try testing.expectError(error.TargetTooSmall, prepared.decodeBiplanar(.{ .luma = &luma, .luma_stride_bytes = 82, .chroma = &chroma, .chroma_stride_bytes = 82 }));
    try prepared.decodeBiplanar(.{ .luma = &luma, .luma_stride_bytes = 82, .chroma = &chroma, .chroma_stride_bytes = 84 });
}

test "RGB8 into a caller's rows matches the allocating decode and leaves the padding alone" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    for ([_]u2{ 0, 1, 2, 3 }) |log2| {
        var expected = try decodeRgb8(testing.allocator, packet, .{ .log2_downscale = log2, .concurrency = 1 });
        defer expected.deinit();
        const stride = expected.stride_bytes + 7;
        const target = try testing.allocator.alloc(u8, stride * expected.height);
        defer testing.allocator.free(target);
        @memset(target, 0x5a);
        var prepared = try Prepared.init(testing.allocator, packet, .{ .log2_downscale = log2, .concurrency = 4 });
        defer prepared.deinit();
        try prepared.decodeRgb8Into(target, stride);
        for (0..expected.height) |y| {
            try testing.expectEqualSlices(u8, expected.data[y * expected.stride_bytes ..][0..expected.stride_bytes], target[y * stride ..][0..expected.stride_bytes]);
            for (target[y * stride + expected.stride_bytes ..][0..7]) |byte| try testing.expectEqual(@as(u8, 0x5a), byte);
        }
    }
}

test "RGB8 into a caller's rows refuses a target too small for the frame" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    var prepared = try Prepared.init(testing.allocator, packet, .{ .log2_downscale = 3 });
    defer prepared.deinit();
    var target: [41 * 3 * 23]u8 = undefined;
    try testing.expectError(error.TargetTooSmall, prepared.decodeRgb8Into(target[0 .. target.len - 1], 41 * 3));
    try testing.expectError(error.TargetTooSmall, prepared.decodeRgb8Into(&target, 41 * 3 - 1));
    try prepared.decodeRgb8Into(&target, 41 * 3);
}

test "frames decoding at once on several threads each come out right" {
    const packet = try readFirstPacket("tests/fixtures/dnxhr_hq_328x184.mxf");
    defer testing.allocator.free(packet);
    var expected = try decodeRgb8(testing.allocator, packet, .{ .concurrency = 1 });
    defer expected.deinit();
    const Caller = struct {
        fn main(bytes: []const u8, want: []const u8, failed: *std.atomic.Value(bool)) void {
            for (0..20) |_| {
                var frame = decodeRgb8(std.heap.smp_allocator, bytes, .{ .concurrency = 4 }) catch {
                    failed.store(true, .monotonic);
                    return;
                };
                defer frame.deinit();
                if (!std.mem.eql(u8, want, frame.data)) failed.store(true, .monotonic);
            }
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Caller.main, .{ packet, expected.data, &failed });
    for (threads) |thread| thread.join();
    try testing.expect(!failed.load(.monotonic));
}

test {
    _ = worker_pool;
}
