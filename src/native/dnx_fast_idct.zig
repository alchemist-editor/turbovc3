// Adapted from TurboRes' SIMD IDCT structure.
// Copyright (c) 2026-present, Vanilagy and contributors
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const V4 = @Vector(4, f32);
const V8 = @Vector(8, f32);
const V64 = @Vector(64, f32);

const S = [8]f32{
    8 * 0.353553390593273762200422,
    8 * 0.254897789552079584470970,
    8 * 0.270598050073098492199862,
    8 * 0.300672443467522640271861,
    8 * 0.353553390593273762200422,
    8 * 0.449988111568207852319255,
    8 * 0.653281482438188263928322,
    8 * 1.281457723870753089398043,
};

const A = [6]f32{
    0,
    0.707106781186547524400844,
    0.541196100146196984399723,
    0.707106781186547524400844,
    1.306562964876376527856643,
    0.382683432365089771728460,
};

/// The multipliers `idctColumns` uses, for the AVX2 kernel to use unchanged.
pub const idct_factors = blk: {
    const denominator = 2.0 / (A[2] * A[5] - A[2] * A[4] - A[4] * A[5]);
    break :blk [5]f32{ A[5] * denominator, A[4] * denominator, A[2] * denominator, 1.0 / A[3], 1.0 / A[1] };
};

pub const scale_matrix = blk: {
    var result: [64]f32 = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            result[y * 8 + x] = 1.0 / (S[x] * S[y]);
        }
    }
    break :blk result;
};

pub inline fn transformBlock(coefficients: [*]const i32, output: [*]u16, maximum: u16) void {
    var values: V64 = undefined;
    inline for (0..8) |y| {
        inline for (0..8) |x| {
            const output_index = y * 8 + x;
            const coefficient_index = x * 8 + y;
            values[output_index] = @as(f32, @floatFromInt(coefficients[coefficient_index])) * scale_matrix[output_index];
        }
    }

    var rows: [8]V8 = @bitCast(values);
    rows = idctColumns(rows);
    rows = transposeRows(rows);
    rows = idctColumns(rows);

    // floor(value + 0.5) clamped to 0..maximum. Clamping first leaves a
    // non-negative value, whose truncation is its floor, so this needs no
    // floor instruction (baseline x86-64 has none, and would call out for
    // every sample).
    inline for (0..8) |row| {
        const offset = rows[row] + @as(V8, @splat(0.5));
        const clamped = @min(@max(offset, @as(V8, @splat(0))), @as(V8, @splat(@floatFromInt(maximum))));
        const as_i32: @Vector(8, i32) = @intFromFloat(clamped);
        const as_u16: @Vector(8, u16) = @intCast(as_i32);
        output[row * 8 ..][0..8].* = as_u16;
    }
}

pub inline fn transformDcBlock(coefficient: i32, output: [*]u16, maximum: u16) void {
    const offset = @as(f32, @floatFromInt(coefficient)) * 0.125 + 0.5;
    const clamped = @min(@max(offset, 0), @as(f32, @floatFromInt(maximum)));
    @memset(output[0..64], @intFromFloat(clamped));
}

inline fn idctColumns(rows: [8]V8) [8]V8 {
    const v15 = rows[0];
    const v26 = rows[1];
    const v21 = rows[2];
    const v28 = rows[3];
    const v16 = rows[4];
    const v25 = rows[5];
    const v22 = rows[6];
    const v27 = rows[7];

    const v19 = v25 - v28;
    const v20 = v26 - v27;
    const v23 = v26 + v27;
    const v24 = v25 + v28;
    const v7 = v23 + v24;
    const v11 = v21 + v22;
    const v13 = v23 - v24;
    const v17 = v21 - v22;
    const v8 = v15 + v16;
    const v9 = v15 - v16;

    const denominator = 2.0 / (A[2] * A[5] - A[2] * A[4] - A[4] * A[5]);
    const v18 = (v19 - v20) * @as(V8, @splat(A[5] * denominator));
    const v12 = v19 * @as(V8, @splat(A[4] * denominator)) - v18;
    const v14 = v18 - v20 * @as(V8, @splat(A[2] * denominator));
    const v6 = v14 - v7;
    const v5 = v13 * @as(V8, @splat(1.0 / A[3])) - v6;
    const v4 = v5 + v12;
    const v10 = v17 * @as(V8, @splat(1.0 / A[1])) - v11;
    const v0 = v8 + v11;
    const v1 = v9 + v10;
    const v2 = v9 - v10;
    const v3 = v8 - v11;

    return .{
        v0 + v7,
        v1 + v6,
        v2 + v5,
        v3 - v4,
        v3 + v4,
        v2 - v5,
        v1 - v6,
        v0 - v7,
    };
}

inline fn transposeRows(rows: [8]V8) [8]V8 {
    var low: [8]V4 = undefined;
    var high: [8]V4 = undefined;
    inline for (0..8) |row| {
        low[row] = @shuffle(f32, rows[row], undefined, [4]i32{ 0, 1, 2, 3 });
        high[row] = @shuffle(f32, rows[row], undefined, [4]i32{ 4, 5, 6, 7 });
    }

    const a = transpose4x4(low[0], low[1], low[2], low[3]);
    const b = transpose4x4(high[0], high[1], high[2], high[3]);
    const c = transpose4x4(low[4], low[5], low[6], low[7]);
    const d = transpose4x4(high[4], high[5], high[6], high[7]);
    var result: [8]V8 = undefined;
    inline for (0..4) |index| {
        result[index] = @shuffle(f32, a[index], c[index], [8]i32{ 0, 1, 2, 3, -1, -2, -3, -4 });
        result[index + 4] = @shuffle(f32, b[index], d[index], [8]i32{ 0, 1, 2, 3, -1, -2, -3, -4 });
    }
    return result;
}

inline fn transpose4x4(v0: V4, v1: V4, v2: V4, v3: V4) [4]V4 {
    const low01 = @shuffle(f32, v0, v1, [4]i32{ 0, -1, 1, -2 });
    const high01 = @shuffle(f32, v0, v1, [4]i32{ 2, -3, 3, -4 });
    const low23 = @shuffle(f32, v2, v3, [4]i32{ 0, -1, 1, -2 });
    const high23 = @shuffle(f32, v2, v3, [4]i32{ 2, -3, 3, -4 });

    return .{
        @shuffle(f32, low01, low23, [4]i32{ 0, 1, -1, -2 }),
        @shuffle(f32, low01, low23, [4]i32{ 2, 3, -3, -4 }),
        @shuffle(f32, high01, high23, [4]i32{ 0, 1, -1, -2 }),
        @shuffle(f32, high01, high23, [4]i32{ 2, 3, -3, -4 }),
    };
}
