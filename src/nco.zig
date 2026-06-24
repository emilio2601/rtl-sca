const std = @import("std");
const C32 = @import("complex.zig").C32;

pub const Nco = struct {
    osc: C32 = .{ .re = 1, .im = 0 },
    rot: C32,
    counter: u32 = 0,

    const renorm_interval: u32 = 1024;

    /// Mixer that shifts a slot at +freq_hz down to DC: rotor = exp(-j·2π·f/fs).
    pub fn init(freq_hz: f64, fs: f64) Nco {
        const theta = -2.0 * std.math.pi * freq_hz / fs;
        return .{ .rot = .{ .re = @floatCast(@cos(theta)), .im = @floatCast(@sin(theta)) } };
    }

    /// Mix real input down to complex baseband, one output per input. The phasor
    /// is renormalized periodically to prevent amplitude drift (SPEC §7).
    pub fn mixReal(self: *Nco, in: []const f32, out: []C32) usize {
        std.debug.assert(out.len >= in.len);
        for (in, 0..) |s, i| {
            out[i] = .{ .re = s * self.osc.re, .im = s * self.osc.im };
            self.osc = self.osc.mul(self.rot);
            self.counter += 1;
            if (self.counter >= renorm_interval) {
                self.counter = 0;
                const m = self.osc.mag();
                if (m > 0) self.osc = self.osc.scale(1.0 / m);
            }
        }
        return in.len;
    }
};

const testing = std.testing;

test "phasor stays unit magnitude over a long run" {
    var nco = Nco.init(67000, 256000);
    var in: [4096]f32 = undefined;
    var out: [4096]C32 = undefined;
    @memset(&in, 1.0);
    var k: usize = 0;
    while (k < 64) : (k += 1) _ = nco.mixReal(&in, &out); // ~256k samples
    try testing.expectApproxEqAbs(@as(f32, 1.0), nco.osc.mag(), 1e-3);
}

test "mixing a real tone at f lands its energy at DC" {
    const fs = 256000.0;
    const f = 67000.0;
    var in: [4096]f32 = undefined;
    var out: [4096]C32 = undefined;
    for (&in, 0..) |*s, n| {
        s.* = @floatCast(@cos(2.0 * std.math.pi * f * @as(f64, @floatFromInt(n)) / fs));
    }
    var nco = Nco.init(f, fs);
    _ = nco.mixReal(&in, &out);
    // DC component = mean of the mixed signal; should be ≈ 0.5 in magnitude
    // (cos·e^{-jωn} = ½(1 + e^{-j2ωn}); the constant ½ survives averaging).
    var sum = C32.zero;
    for (out) |c| sum = sum.add(c);
    const mean = sum.scale(1.0 / @as(f32, out.len));
    try testing.expectApproxEqAbs(@as(f32, 0.5), mean.mag(), 0.02);
}
