const std = @import("std");

pub const Deemph = struct {
    alpha: f32,
    y_prev: f32 = 0,

    /// tau_us = 0 disables de-emphasis (alpha = 1 ⇒ passthrough). alpha is computed
    /// at the audio sample rate (dt = 1/fs_audio), not the MPX rate (SPEC §5).
    pub fn init(tau_us: f64, fs_audio: f64) Deemph {
        if (tau_us == 0) return .{ .alpha = 1 };
        const tau = tau_us * 1e-6;
        const dt = 1.0 / fs_audio;
        return .{ .alpha = @floatCast(dt / (tau + dt)) };
    }

    pub fn process(self: *Deemph, x: []f32) void {
        if (self.alpha == 1) return; // de-emphasis off: passthrough
        for (x) |*s| {
            self.y_prev += self.alpha * (s.* - self.y_prev);
            s.* = self.y_prev;
        }
    }
};

const testing = std.testing;

test "alpha matches the worked examples" {
    try testing.expectApproxEqAbs(@as(f32, 0.2941), Deemph.init(150, 16000).alpha, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.4545), Deemph.init(75, 16000).alpha, 1e-3);
    try testing.expectEqual(@as(f32, 1.0), Deemph.init(0, 16000).alpha);
}

test "off is identity" {
    var d = Deemph.init(0, 16000);
    var x = [_]f32{ 0.5, -0.3, 0.9, -1.0, 0.1 };
    const orig = x;
    d.process(&x);
    for (orig, x) |a, b| try testing.expectEqual(a, b);
}

// Steady-state amplitude gain of the filter at a given frequency (RMS ratio).
fn gainAt(tau_us: f64, fs: f64, f: f64) f32 {
    var d = Deemph.init(tau_us, fs);
    var buf: [8000]f32 = undefined;
    for (&buf, 0..) |*s, i| {
        s.* = @floatCast(@sin(2.0 * std.math.pi * f * @as(f64, @floatFromInt(i)) / fs));
    }
    d.process(&buf);
    // measure RMS over the second half (after the transient settles)
    var acc: f64 = 0;
    for (buf[4000..]) |s| acc += @as(f64, s) * s;
    const rms_out = @sqrt(acc / 4000.0);
    const rms_in = 1.0 / @sqrt(2.0); // unit-amplitude sine
    return @floatCast(rms_out / rms_in);
}

test "de-emphasis rolls off highs, passes DC" {
    // DC gain ~1
    try testing.expectApproxEqAbs(@as(f32, 1.0), gainAt(150, 16000, 20), 0.02);
    // monotone rolloff: more attenuation at higher frequency
    const g_corner = gainAt(150, 16000, 1061); // analog corner 1/(2π·150µs)
    const g_high = gainAt(150, 16000, 6000);
    try testing.expect(g_corner < 0.95 and g_corner > 0.55); // roughly -3 dB region
    try testing.expect(g_high < g_corner);
}
