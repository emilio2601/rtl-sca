const std = @import("std");

pub const C32 = struct {
    re: f32,
    im: f32,

    pub const zero: C32 = .{ .re = 0, .im = 0 };

    pub inline fn scale(a: C32, s: f32) C32 {
        return .{ .re = a.re * s, .im = a.im * s };
    }
    pub inline fn add(a: C32, b: C32) C32 {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    pub inline fn mul(a: C32, b: C32) C32 {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    pub inline fn conj(a: C32) C32 {
        return .{ .re = a.re, .im = -a.im };
    }
    pub inline fn mag(a: C32) f32 {
        return std.math.hypot(a.re, a.im);
    }
};

/// Unpack interleaved cu8 (uint8 IQ, DC bias 127.5) into normalized C32 in [-1, 1).
/// Returns the number of complex samples written (= bytes.len / 2).
pub fn unpackCu8(bytes: []const u8, out: []C32) usize {
    const n = bytes.len / 2;
    std.debug.assert(out.len >= n);
    const s = 1.0 / 127.5;
    for (0..n) |i| {
        const ir: f32 = @floatFromInt(bytes[2 * i]);
        const qr: f32 = @floatFromInt(bytes[2 * i + 1]);
        out[i] = .{ .re = (ir - 127.5) * s, .im = (qr - 127.5) * s };
    }
    return n;
}

/// Unpack interleaved cs16 (little-endian int16 IQ) into normalized C32 in [-1, 1).
/// Returns the number of complex samples written (= bytes.len / 4).
pub fn unpackCs16(bytes: []const u8, out: []C32) usize {
    const n = bytes.len / 4;
    std.debug.assert(out.len >= n);
    const s = 1.0 / 32768.0;
    for (0..n) |i| {
        const ii = std.mem.readInt(i16, bytes[4 * i ..][0..2], .little);
        const qq = std.mem.readInt(i16, bytes[4 * i + 2 ..][0..2], .little);
        const ir: f32 = @floatFromInt(ii);
        const qr: f32 = @floatFromInt(qq);
        out[i] = .{ .re = ir * s, .im = qr * s };
    }
    return n;
}

const testing = std.testing;

test "unpackCu8 endpoints and midpoint" {
    var out: [4]C32 = undefined;
    // I bytes: 255 (+1), 0 (-1), 128 (~0+), 127 (~0-);  Q mirrors with a shift
    const bytes = [_]u8{ 255, 0, 0, 255, 128, 128, 127, 127 };
    const n = unpackCu8(&bytes, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[0].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[1].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[1].im, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[2].re, 0.01);
    try testing.expect(out[3].re < 0 and out[3].re > -0.01);
}

test "unpackCs16 endpoints" {
    var out: [2]C32 = undefined;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i16, bytes[0..2], 32767, .little);
    std.mem.writeInt(i16, bytes[2..4], -32768, .little);
    std.mem.writeInt(i16, bytes[4..6], 0, .little);
    std.mem.writeInt(i16, bytes[6..8], 16384, .little);
    const n = unpackCs16(&bytes, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[0].re, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[0].im, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[1].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[1].im, 1e-4);
}

test "C32 ops" {
    const a = C32{ .re = 1, .im = 2 };
    const b = C32{ .re = 3, .im = 4 };
    try testing.expectEqual(C32{ .re = -5, .im = 10 }, a.mul(b));
    try testing.expectEqual(C32{ .re = 1, .im = -2 }, a.conj());
    try testing.expectApproxEqAbs(@as(f32, 5.0), (C32{ .re = 3, .im = 4 }).mag(), 1e-6);
}
