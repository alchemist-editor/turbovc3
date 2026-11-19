const std = @import("std");
const row = @import("../dnx_row_decoder.zig");
const tables = @import("tables.zig");

pub const LOOKUP_SIZE = 1 << 16;

pub const TableSet = struct {
    dc_lookup: [LOOKUP_SIZE]u16,
    ac_lookup: [LOOKUP_SIZE]u16,
    run_lookup: [LOOKUP_SIZE]u16,
    ac_info: []const u16,
    run: []const u8,
    eob_index: u32,
    index_bits: u32,
    level_bias: i32,
    level_shift: u32,
    luma_weight: []const u16,
    chroma_weight: []const u16,
    /// Filled for the shared sets only (`sharedTableForCid`).
    fast: row.FastTables = undefined,
};

fn buildLookup(codes: []const u32, bits: []const u8, out: *[LOOKUP_SIZE]u16) void {
    @memset(out, 0);
    // Match TS buildHuffmanTable: fill shortest codes first so longer
    // prefix-free codes overwrite only their own slots.
    var order: [512]u16 = undefined;
    const n = @min(codes.len, order.len);
    for (0..n) |i| order[i] = @intCast(i);
    var a: usize = 0;
    while (a + 1 < n) : (a += 1) {
        var b = a + 1;
        while (b < n) : (b += 1) {
            if (bits[order[b]] < bits[order[a]]) {
                const tmp = order[a];
                order[a] = order[b];
                order[b] = tmp;
            }
        }
    }
    for (order[0..n]) |symbol| {
        const bit_len = bits[symbol];
        if (bit_len == 0) continue;
        const suffix: u5 = @intCast(16 - bit_len);
        const start: u32 = codes[symbol] << suffix;
        const end = start + (@as(u32, 1) << suffix);
        const zig_packed: u16 = @intCast((@as(u16, bit_len - 1) << 12) | @as(u16, @intCast(symbol + 1)));
        var i = start;
        while (i < end) : (i += 1) out[@intCast(i)] = zig_packed;
    }
}

fn buildLookupU16(codes: []const u16, bits: []const u8, out: *[LOOKUP_SIZE]u16) void {
    var wide: [512]u32 = undefined;
    const n = @min(codes.len, wide.len);
    for (0..n) |i| wide[i] = codes[i];
    buildLookup(wide[0..n], bits[0..n], out);
}

/// One set of lookups per table family, built by the first frame that needs
/// it and shared by every frame after.
const SharedTable = struct {
    state: std.atomic.Value(u8) = .init(empty),
    set: TableSet = undefined,

    const empty = 0;
    const building = 1;
    const ready = 2;
};

var shared_tables: [3]SharedTable = @splat(.{});

fn familyForCid(cid: u32) ?struct { index: usize, cid: u32 } {
    return switch (cid) {
        1237, 1273, 1274, 1253, 1259 => .{ .index = 0, .cid = 1237 },
        1238, 1272, 1243 => .{ .index = 1, .cid = 1238 },
        1235 => .{ .index = 2, .cid = 1235 },
        else => null,
    };
}

/// `tableForCid`, without rebuilding the lookups for every frame.
pub fn sharedTableForCid(cid: u32) ?*const TableSet {
    const family = familyForCid(cid) orelse return null;
    const slot = &shared_tables[family.index];
    if (slot.state.load(.acquire) == SharedTable.ready) return &slot.set;
    if (slot.state.cmpxchgStrong(SharedTable.empty, SharedTable.building, .acquire, .acquire) == null) {
        fillTableSet(&slot.set, family.cid);
        slot.state.store(SharedTable.ready, .release);
    } else {
        while (slot.state.load(.acquire) != SharedTable.ready) std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    return &slot.set;
}

fn fillTableSet(out: *TableSet, cid: u32) void {
    out.* = tableForCid(cid).?;
    out.fast.fill(&out.dc_lookup, &out.ac_lookup, &out.run_lookup, out.ac_info, out.run, out.eob_index);
}

pub fn tableForCid(cid: u32) ?TableSet {
    // DNxHR SQ/LB and DNxHD 1237 share TABLE_1237_8BIT (TS CID_TABLES)
    if (cid == 1237 or cid == 1273 or cid == 1274 or cid == 1253 or cid == 1259) {
        var set: TableSet = .{
            .dc_lookup = undefined,
            .ac_lookup = undefined,
            .run_lookup = undefined,
            .ac_info = &tables.DNXHD_1237_AC_INFO,
            .run = &tables.DNXHD_1237_RUN,
            .eob_index = 3,
            .index_bits = 4,
            .level_bias = 32,
            .level_shift = 6,
            .luma_weight = &tables.DNXHD_1237_LUMA_WEIGHT,
            .chroma_weight = &tables.DNXHD_1237_CHROMA_WEIGHT,
        };
        buildLookupU16(&tables.DNXHD_1237_DC_CODES, &tables.DNXHD_1237_DC_BITS, &set.dc_lookup);
        buildLookup(&tables.DNXHD_1237_AC_CODES, &tables.DNXHD_1237_AC_BITS, &set.ac_lookup);
        buildLookupU16(&tables.DNXHD_1237_RUN_CODES, &tables.DNXHD_1237_RUN_BITS, &set.run_lookup);
        return set;
    }
    // DNxHR HQ (1272) and DNxHD 1238/1243 share TABLE_1238_8BIT
    if (cid == 1238 or cid == 1272 or cid == 1243) {
        var set: TableSet = .{
            .dc_lookup = undefined,
            .ac_lookup = undefined,
            .run_lookup = undefined,
            .ac_info = &tables.DNXHD_1238_AC_INFO,
            .run = &tables.DNXHD_1238_RUN,
            .eob_index = 4,
            .index_bits = 4,
            .level_bias = 32,
            .level_shift = 6,
            .luma_weight = &tables.DNXHD_1238_LUMA_WEIGHT,
            .chroma_weight = &tables.DNXHD_1238_CHROMA_WEIGHT,
        };
        buildLookupU16(&tables.DNXHD_1237_DC_CODES, &tables.DNXHD_1237_DC_BITS, &set.dc_lookup);
        buildLookup(&tables.DNXHD_1238_AC_CODES, &tables.DNXHD_1238_AC_BITS, &set.ac_lookup);
        buildLookupU16(&tables.DNXHD_1235_RUN_CODES, &tables.DNXHD_1235_RUN_BITS, &set.run_lookup);
        return set;
    }
    if (cid == 1235) {
        var set: TableSet = .{
            .dc_lookup = undefined,
            .ac_lookup = undefined,
            .run_lookup = undefined,
            .ac_info = &tables.DNXHD_1235_AC_INFO,
            .run = &tables.DNXHD_1235_RUN,
            .eob_index = 4,
            .index_bits = 6,
            .level_bias = 8,
            .level_shift = 4,
            .luma_weight = &tables.DNXHD_1235_LUMA_WEIGHT,
            .chroma_weight = &tables.DNXHD_1235_CHROMA_WEIGHT,
        };
        buildLookupU16(&tables.DNXHD_1235_DC_CODES, &tables.DNXHD_1235_DC_BITS, &set.dc_lookup);
        buildLookup(&tables.DNXHD_1235_AC_CODES, &tables.DNXHD_1235_AC_BITS, &set.ac_lookup);
        buildLookupU16(&tables.DNXHD_1235_RUN_CODES, &tables.DNXHD_1235_RUN_BITS, &set.run_lookup);
        return set;
    }
    return null;
}

test "the shared tables are the ones tableForCid builds, one set per family" {
    for ([_]u32{ 1237, 1273, 1274, 1253, 1259, 1238, 1272, 1243, 1235 }) |cid| {
        const built = tableForCid(cid).?;
        const shared = sharedTableForCid(cid).?;
        try std.testing.expectEqualSlices(u16, &built.dc_lookup, &shared.dc_lookup);
        try std.testing.expectEqualSlices(u16, &built.ac_lookup, &shared.ac_lookup);
        try std.testing.expectEqualSlices(u16, &built.run_lookup, &shared.run_lookup);
        try std.testing.expectEqualSlices(u16, built.ac_info, shared.ac_info);
        try std.testing.expectEqualSlices(u8, built.run, shared.run);
        try std.testing.expectEqualSlices(u16, built.luma_weight, shared.luma_weight);
        try std.testing.expectEqualSlices(u16, built.chroma_weight, shared.chroma_weight);
    }
    try std.testing.expectEqual(sharedTableForCid(1272).?, sharedTableForCid(1238).?);
    try std.testing.expectEqual(@as(?*const TableSet, null), sharedTableForCid(1));
}

test "1237 zigLookup matches oracle fingerprint samples" {
    const set = tableForCid(1237).?;
    // TS: dc sample dc[0]=8193 dc[1]=8193 dc[0x8000]=8199
    try std.testing.expectEqual(@as(u16, 8193), set.dc_lookup[0]);
    try std.testing.expectEqual(@as(u16, 8193), set.dc_lookup[1]);
    try std.testing.expectEqual(@as(u16, 8199), set.dc_lookup[0x8000]);
    try std.testing.expectEqual(@as(u16, 4097), set.ac_lookup[0]);
    try std.testing.expectEqual(@as(u16, 8195), set.ac_lookup[0x8000]);
    try std.testing.expectEqual(@as(u16, 1), set.run_lookup[0]);
    try std.testing.expectEqual(@as(u8, 1), set.run[0]);
    try std.testing.expectEqual(@as(usize, 514), set.ac_info.len);
}
