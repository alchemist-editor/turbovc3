const std = @import("std");
const binary = @import("../mxf/binary.zig");

pub const Profile = enum { dnxhd, dnxhr_lb, dnxhr_sq, dnxhr_hq, dnxhr_hqx, dnxhr_444, unknown };
pub const FourCc = enum { AVdn, AVdh };

pub const FrameHeader = struct {
    four_cc: FourCc,
    cid: u32,
    profile: Profile,
    width: u32,
    encoded_width: u32,
    height: u32,
    bit_depth: u8,
    is_444: bool,
    interlaced: bool,
    mbaff: bool,
    field_height: u32,
    macroblock_width: u32,
    macroblock_height: u32,
    data_offset: u32,
    expected_frame_size: ?u32,
    supported: bool,
};

const CidEntry = struct {
    cid: u32,
    profile: Profile,
    width: ?u32,
    height: ?u32,
    frame_size: ?u32,
    coding_unit_size: ?u32,
    bit_depth: ?u8,
    interlaced: bool = false,
    is_444: bool = false,
    mbaff: bool = false,
    scale_num: ?u32 = null,
    scale_den: ?u32 = null,
};

const cid_table = [_]CidEntry{
    .{ .cid = 1235, .profile = .dnxhd, .width = 1920, .height = 1080, .frame_size = 917504, .coding_unit_size = 917504, .bit_depth = 10 },
    .{ .cid = 1237, .profile = .dnxhd, .width = 1920, .height = 1080, .frame_size = 606208, .coding_unit_size = 606208, .bit_depth = 8 },
    .{ .cid = 1238, .profile = .dnxhd, .width = 1920, .height = 1080, .frame_size = 917504, .coding_unit_size = 917504, .bit_depth = 8 },
    .{ .cid = 1270, .profile = .dnxhr_444, .width = null, .height = null, .frame_size = null, .coding_unit_size = null, .bit_depth = null, .is_444 = true, .scale_num = 57344, .scale_den = 255 },
    .{ .cid = 1271, .profile = .dnxhr_hqx, .width = null, .height = null, .frame_size = null, .coding_unit_size = null, .bit_depth = null, .scale_num = 28672, .scale_den = 255 },
    .{ .cid = 1272, .profile = .dnxhr_hq, .width = null, .height = null, .frame_size = null, .coding_unit_size = null, .bit_depth = 8, .scale_num = 28672, .scale_den = 255 },
    .{ .cid = 1273, .profile = .dnxhr_sq, .width = null, .height = null, .frame_size = null, .coding_unit_size = null, .bit_depth = 8, .scale_num = 18944, .scale_den = 255 },
    .{ .cid = 1274, .profile = .dnxhr_lb, .width = null, .height = null, .frame_size = null, .coding_unit_size = null, .bit_depth = 8, .scale_num = 5888, .scale_den = 255 },
};

fn getCid(cid: u32) ?CidEntry {
    for (cid_table) |entry| if (entry.cid == cid) return entry;
    return null;
}

fn parseBitDepth(bits: u8) ?u8 {
    return switch (bits) {
        1 => 8,
        2 => 10,
        3 => 12,
        else => null,
    };
}

fn parsePrefix(packet: []const u8) ?struct { kind: enum { classic, hr }, data_offset: ?u32 } {
    if (packet.len < 5) return null;
    if (packet[0] == 0 and packet[1] == 0 and packet[2] == 0x02 and packet[3] == 0x80) {
        if (packet[4] == 0x01 or packet[4] == 0x02) return .{ .kind = .classic, .data_offset = null };
    }
    const data_offset = binary.readU32BE(packet, 0);
    if (packet[0] == 0 and packet[1] == 0 and packet[4] == 0x03 and data_offset >= 0x0280 and data_offset <= 0x2170 and data_offset % 4 == 0) {
        return .{ .kind = .hr, .data_offset = data_offset };
    }
    return null;
}

pub fn parseFrameHeader(packet: []const u8) ?FrameHeader {
    if (packet.len < 0x280) return null;
    const prefix = parsePrefix(packet) orelse return null;
    const field_height = binary.readU16BE(packet, 0x18);
    const encoded_width = binary.readU16BE(packet, 0x1a);
    const bit_depth = parseBitDepth(packet[0x21] >> 5) orelse return null;
    if (encoded_width == 0 or field_height == 0) return null;
    const cid_value = binary.readU32BE(packet, 0x28);
    const cid_entry = getCid(cid_value);
    const width = if (cid_entry) |e| e.width orelse encoded_width else encoded_width;
    const is_444 = ((packet[0x2c] >> 6) & 1) == 1;
    const macroblock_width = (width + 15) / 16;
    const macroblock_height = binary.readU16BE(packet, 0x16c);
    const data_offset: u32 = if (prefix.kind == .hr and macroblock_height > 68)
        0x170 + (@as(u32, macroblock_height) << 2)
    else
        0x280;
    const interlaced = (packet[5] & 2) != 0;
    const height: u32 = if (interlaced and cid_entry != null and cid_entry.?.height != null) cid_entry.?.height.? else field_height;
    const mbaff = ((packet[0x06] >> 5) & 1) == 1;
    const expected: ?u32 = if (cid_entry) |e| blk: {
        if (mbaff) break :blk e.coding_unit_size;
        if (e.frame_size) |fs| break :blk fs;
        if (e.scale_num) |num| {
            const den = e.scale_den orelse break :blk null;
            const mb: u64 = @as(u64, macroblock_width) * macroblock_height;
            const unaligned = (mb * num) / den;
            break :blk @intCast(((unaligned + 2048) / 4096) * 4096);
        }
        break :blk null;
    } else null;
    const alpha = (packet[0x07] & 1) == 1;
    const supported = !interlaced and !alpha and bit_depth == 8 and !is_444;
    return .{
        .four_cc = if (cid_value >= 1270 and cid_value <= 1274) .AVdh else .AVdn,
        .cid = cid_value,
        .profile = if (cid_entry) |e| e.profile else .unknown,
        .width = width,
        .encoded_width = encoded_width,
        .height = height,
        .bit_depth = bit_depth,
        .is_444 = is_444,
        .interlaced = interlaced,
        .mbaff = mbaff,
        .field_height = field_height,
        .macroblock_width = macroblock_width,
        .macroblock_height = macroblock_height,
        .data_offset = data_offset,
        .expected_frame_size = expected,
        .supported = supported,
    };
}

pub const RowSpan = struct { row: u32, start: u32, end: u32 };

/// The most macroblock rows a DNx packet can code: its scan table runs from
/// 0x170 to data_offset, and parsePrefix accepts data_offset up to 0x2170.
/// Size a parseRowSpans buffer with this, not with a picture size.
pub const max_rows = (0x2170 - 0x170) / 4;

pub fn parseRowSpans(packet: []const u8, header: FrameHeader, out: []RowSpan) ![]RowSpan {
    if (packet.len <= header.data_offset) return error.NoPayload;
    const payload_length: u32 = @intCast(packet.len - header.data_offset);
    if (header.macroblock_height > out.len) return error.TooManyRows;
    var previous: u32 = 0;
    var row: u32 = 0;
    while (row < header.macroblock_height) : (row += 1) {
        const scan_offset: usize = 0x170 + row * 4;
        if (scan_offset + 4 > packet.len) return error.ScanOutsidePacket;
        const relative_start = binary.readU32BE(packet, scan_offset);
        if (relative_start < previous) return error.NonMonotonicScan;
        if (relative_start > payload_length) return error.ScanPastPayload;
        const relative_end: u32 = if (row + 1 < header.macroblock_height and 0x170 + (row + 1) * 4 + 4 <= packet.len)
            binary.readU32BE(packet, 0x170 + (row + 1) * 4)
        else
            payload_length;
        if (relative_end < relative_start or relative_end > payload_length) return error.InvalidScanSpan;
        out[row] = .{ .row = row, .start = header.data_offset + relative_start, .end = header.data_offset + relative_end };
        previous = relative_start;
    }
    return out[0..header.macroblock_height];
}
