//! turbovc3 — native Zig package for MXF demux + DNxHD/DNxHR decode.
//! Coequal with the TypeScript/WASM surface in this repository.

const std = @import("std");

pub const reader = @import("reader.zig");
pub const mxf = @import("mxf/mod.zig");
pub const dnx = @import("dnx/mod.zig");

// Keep the WASM row-decoder export unit in the module graph.
pub const row_decoder = @import("dnx_row_decoder.zig");

pub const Reader = reader.Reader;
pub const FileReader = reader.FileReader;
pub const SliceReader = reader.SliceReader;

test {
    _ = reader;
    _ = mxf;
    _ = dnx;
    _ = row_decoder;
}

test "demux and decode beach DNxHR HQ sample when present" {
    const path = "samples/dnxhr/beach_rec2020_dnxhr_hq_1080p2398_5s.mxf";
    var fr = reader.FileReader.open(std.testing.io, path) catch return; // skip if missing
    defer fr.deinit();
    const r = fr.reader();
    var demuxed = try mxf.demuxFile(std.testing.allocator, r, .{});
    defer demuxed.deinit();
    const video = demuxed.primaryVideoTrack() orelse return error.NoVideo;
    var iter = demuxed.packetsForTrack(video);
    const packet_meta = iter.next() orelse return error.NoPackets;
    const packet = try demuxed.readPacket(r, packet_meta);
    defer std.testing.allocator.free(packet);
    var frame = try dnx.decodeFrameRgb8(std.testing.allocator, packet);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u32, 1920), frame.width);
    try std.testing.expectEqual(@as(u32, 1080), frame.height);
    try std.testing.expect(frame.data.len > 0);
}

test "decode oracle beach frame0.bin when present" {
    const path = "/tmp/beach-frame0.bin";
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2 * 1024 * 1024)) catch return;
    defer std.testing.allocator.free(bytes);
    const hdr = dnx.parseFrameHeader(bytes) orelse return error.BadHeader;
    try std.testing.expectEqual(@as(u32, 1272), hdr.cid);
    var spans_buf: [dnx.header.max_rows]dnx.header.RowSpan = undefined;
    const spans = try dnx.header.parseRowSpans(bytes, hdr, &spans_buf);
    try std.testing.expectEqual(@as(usize, 68), spans.len);
    var frame = try dnx.decodeFrameRgb8(std.testing.allocator, bytes);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u32, 1920), frame.width);

    // Byte-exact planar YUV comparison against the WASM row-decoder output
    // (same Zig sources compiled to wasm32), when the oracle dump is present.
    const oracle = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "/tmp/wasm_frame0_yuv.bin", std.testing.allocator, .limited(8 * 1024 * 1024)) catch return;
    defer std.testing.allocator.free(oracle);
    var yuv = try dnx.decodeFrameYuv8(std.testing.allocator, bytes);
    defer yuv.deinit();
    try std.testing.expectEqual(oracle.len, yuv.data.len);
    try std.testing.expect(std.mem.eql(u8, oracle, yuv.data));
}
