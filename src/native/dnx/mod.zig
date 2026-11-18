pub const header = @import("header.zig");
pub const huffman = @import("huffman.zig");
pub const tables = @import("tables.zig");
pub const decode = @import("decode.zig");
pub const frame_decoder = @import("frame_decoder.zig");

pub const FrameHeader = header.FrameHeader;
pub const parseFrameHeader = header.parseFrameHeader;
pub const RgbFrame = decode.RgbFrame;
pub const YuvFrame = decode.YuvFrame;
pub const decodeFrameRgb8 = decode.decodeFrameRgb8;
pub const decodeFrameYuv8 = decode.decodeFrameYuv8;

test {
    _ = header;
    _ = huffman;
    _ = decode;
    _ = frame_decoder;
}
