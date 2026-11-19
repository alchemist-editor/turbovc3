//! Native DNx frame decoder benchmark.
//!
//!     zig build bench -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu -- FILE.mxf...
//!
//! Decodes each file's first frame repeatedly, per output, thread count
//! (0 is every core) and size, and prints frames per second. A target buffer
//! is reused from frame to frame, as a host's frame pool would be.
const std = @import("std");
const tv = @import("turbovc3");

const frame_decoder = tv.dnx.frame_decoder;
const thread_counts = [_]u32{ 1, 2, 4, 8, 16, 0 };
const sizes = [_]u2{ 0, 1, 2 };
const min_frames = 12;
const min_seconds = 0.35;

const Output = enum { rgb8, rgb8_into, biplanar, planar };

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 2) {
        std.debug.print("usage: native_decode FILE.mxf...\n", .{});
        return error.MissingPath;
    }
    for (argv[1..]) |path| {
        const packet = try firstPacket(gpa, io, path);
        defer gpa.free(packet);
        std.debug.print("{s} ({d} KiB)\n", .{ std.fs.path.basename(path), packet.len / 1024 });
        for (std.enums.values(Output)) |output| {
            std.debug.print("  {s}\n    threads", .{@tagName(output)});
            for (sizes) |log2| std.debug.print("{s:>9}1/{d}", .{ "", @as(u32, 1) << log2 });
            std.debug.print("\n", .{});
            for (thread_counts) |threads| {
                std.debug.print("    {d:>7}", .{threads});
                for (sizes) |log2| {
                    const fps = try measure(gpa, io, packet, output, threads, log2);
                    std.debug.print("{d:>12.1}", .{fps});
                }
                std.debug.print("\n", .{});
            }
        }
    }
}

fn firstPacket(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try tv.FileReader.open(io, path);
    defer file.deinit();
    const reader = file.reader();
    var demuxed = try tv.mxf.demuxFile(gpa, reader, .{});
    defer demuxed.deinit();
    const track = demuxed.primaryVideoTrack() orelse return error.NoVideoTrack;
    var packets = demuxed.packetsForTrack(track);
    return demuxed.readPacket(reader, packets.next() orelse return error.NoPackets);
}

fn measure(gpa: std.mem.Allocator, io: std.Io, packet: []const u8, output: Output, threads: u32, log2: u2) !f64 {
    const options: frame_decoder.Options = .{ .concurrency = threads, .log2_downscale = log2 };
    var planes: Planes = .{};
    defer planes.deinit(gpa);
    const start = now(io);
    var frames: usize = 0;
    while (frames < min_frames or now(io) - start < min_seconds) : (frames += 1) {
        switch (output) {
            .rgb8 => {
                var frame = try frame_decoder.decodeRgb8(gpa, packet, options);
                frame.deinit();
            },
            .rgb8_into => {
                var prepared = try frame_decoder.Prepared.init(gpa, packet, options);
                defer prepared.deinit();
                const stride = @as(usize, prepared.width()) * 3;
                if (planes.luma.len == 0) planes.luma = try gpa.alloc(u8, stride * prepared.height());
                try prepared.decodeRgb8Into(planes.luma, stride);
            },
            .planar => {
                var frame = try frame_decoder.decodeYuv16(gpa, packet, options);
                frame.deinit();
            },
            .biplanar => {
                var prepared = try frame_decoder.Prepared.init(gpa, packet, options);
                defer prepared.deinit();
                try prepared.decodeBiplanar(try planes.fit(gpa, prepared));
            },
        }
    }
    return @as(f64, @floatFromInt(frames)) / (now(io) - start);
}

const Planes = struct {
    luma: []u8 = &.{},
    chroma: []u8 = &.{},

    fn fit(self: *Planes, gpa: std.mem.Allocator, prepared: frame_decoder.Prepared) !frame_decoder.Biplanar {
        const width: usize = prepared.width();
        const height: usize = prepared.height();
        const pairs = if (prepared.is444()) width else (width + 1) / 2;
        const luma_stride = width * 2;
        const chroma_stride = pairs * 4;
        if (self.luma.len == 0) {
            self.luma = try gpa.alloc(u8, luma_stride * height);
            self.chroma = try gpa.alloc(u8, chroma_stride * height);
        }
        return .{ .luma = self.luma, .luma_stride_bytes = luma_stride, .chroma = self.chroma, .chroma_stride_bytes = chroma_stride };
    }

    fn deinit(self: *Planes, gpa: std.mem.Allocator) void {
        gpa.free(self.luma);
        gpa.free(self.chroma);
    }
};

fn now(io: std.Io) f64 {
    const timestamp = std.Io.Timestamp.now(io, .awake);
    return @as(f64, @floatFromInt(timestamp.nanoseconds)) * 1e-9;
}
