const std = @import("std");
const C32 = @import("complex.zig").C32;

pub const FmDemod = struct {
    prev: C32 = .{ .re = 1, .im = 0 },

    /// Polar discriminator: y[n] = atan2(Im(x·conj(prev)), Re(x·conj(prev))).
    /// Output is instantaneous frequency in radians/sample, one per input.
    pub fn process(self: *FmDemod, in: []const C32, out: []f32) usize {
        std.debug.assert(out.len >= in.len);
        for (in, 0..) |x, i| {
            const d = x.mul(self.prev.conj());
            out[i] = std.math.atan2(d.im, d.re);
            self.prev = x;
        }
        return in.len;
    }
};

const testing = std.testing;

fn tone(out: []C32, freq: f64, fs: f64) void {
    for (out, 0..) |*c, n| {
        const ph = 2.0 * std.math.pi * freq * @as(f64, @floatFromInt(n)) / fs;
        c.* = .{ .re = @floatCast(@cos(ph)), .im = @floatCast(@sin(ph)) };
    }
}

test "discriminator on a pure tone yields constant freq" {
    const fs = 16000.0;
    const f = 1000.0;
    var in: [512]C32 = undefined;
    var out: [512]f32 = undefined;
    tone(&in, f, fs);
    var d = FmDemod{};
    _ = d.process(&in, &out);
    const expected: f32 = @floatCast(2.0 * std.math.pi * f / fs);
    // skip the first sample (depends on initial prev state)
    for (out[1..]) |y| try testing.expectApproxEqAbs(expected, y, 1e-4);
}

test "discriminator recovers an FM-modulated baseband tone" {
    const fs = 48000.0;
    const fc = 5000.0; // subcarrier
    const fm = 500.0; // modulating tone
    const dev = 1500.0; // peak deviation
    var in: [4096]C32 = undefined;
    var out: [4096]f32 = undefined;
    for (&in, 0..) |*c, n| {
        const t = @as(f64, @floatFromInt(n)) / fs;
        // phase = 2π fc t + (dev/fm) sin(2π fm t)  → instantaneous freq carries the tone
        const ph = 2.0 * std.math.pi * fc * t + (dev / fm) * @sin(2.0 * std.math.pi * fm * t);
        c.* = .{ .re = @floatCast(@cos(ph)), .im = @floatCast(@sin(ph)) };
    }
    var d = FmDemod{};
    _ = d.process(&in, &out);
    // recovered = 2π fc/fs + (2π dev/fs) cos(2π fm t); its AC part is the tone.
    // Assert the demodulated signal oscillates at ~fm: count zero crossings of AC part.
    const dc: f32 = @floatCast(2.0 * std.math.pi * fc / fs);
    var crossings: usize = 0;
    var prev = out[1] - dc;
    for (out[2..]) |y| {
        const ac = y - dc;
        if ((prev < 0) != (ac < 0)) crossings += 1;
        prev = ac;
    }
    // expected crossings ≈ 2 * fm * duration
    const dur = @as(f64, @floatFromInt(out.len - 2)) / fs;
    const expected_cross = 2.0 * fm * dur;
    try testing.expectApproxEqAbs(expected_cross, @as(f64, @floatFromInt(crossings)), expected_cross * 0.05);
}

test "process is identical split across blocks (state carries)" {
    const fs = 16000.0;
    var in: [300]C32 = undefined;
    tone(&in, 1234.0, fs);
    var whole: [300]f32 = undefined;
    var split: [300]f32 = undefined;

    var d1 = FmDemod{};
    _ = d1.process(&in, &whole);

    var d2 = FmDemod{};
    _ = d2.process(in[0..128], split[0..128]);
    _ = d2.process(in[128..], split[128..]);

    for (whole, split) |a, b| try testing.expectApproxEqAbs(a, b, 1e-6);
}
