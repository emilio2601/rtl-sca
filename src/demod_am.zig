const std = @import("std");
const C32 = @import("complex.zig").C32;

/// Costas-loop diagnostics: `lock` quality ∈ [−1, 1] and residual carrier offset
/// `freq` in rad/sample.
pub const LoopStats = struct { lock: f32, freq: f32 };

/// Incoherent AM: envelope detection (|z|) with a one-pole DC block. Works for
/// AM-with-carrier; on suppressed-carrier DSB it yields the rectified message
/// (use AmCoherent for clean DSB). One output per input.
pub const AmEnv = struct {
    dc: f32 = 0,
    const dc_a: f32 = 0.001;

    pub fn process(self: *AmEnv, z: []const C32, out: []f32) usize {
        std.debug.assert(out.len >= z.len);
        for (z, 0..) |c, i| {
            const env = c.mag();
            self.dc += dc_a * (env - self.dc);
            out[i] = env - self.dc;
        }
        return z.len;
    }
};

/// Coherent DSB via a 2nd-order Costas loop: recover the suppressed-carrier
/// phase, output the in-phase (real) component = the message. The NCO upstream
/// already mixed the slot near DC; the loop tracks the residual offset/drift.
/// Sign of the message is ambiguous (inaudible for audio). One output per input.
pub const AmCoherent = struct {
    phase: f32 = 0,
    freq: f32 = 0,
    dc: f32 = 0,
    /// Lock quality: an EMA of cos(2·phase_error) ∈ [−1, 1]; →1 when locked, ~0
    /// when the loop is hunting. Read via `stats` for the `-v` signal readout.
    lock: f32 = 0,
    // 2nd-order loop, ζ≈0.7, loop BW ~ fs/200; clamp freq to keep it from running away.
    const alpha: f32 = 0.044;
    const beta: f32 = 0.001;
    const dc_a: f32 = 0.001;
    const lock_a: f32 = 0.0005; // lock EMA at the channel rate (~16–44 ksps)
    const freq_clamp: f32 = 0.5; // rad/sample

    /// Loop state for diagnostics: `lock` quality and the residual carrier
    /// frequency error `freq` in rad/sample (caller scales by fs/2π for Hz).
    pub fn stats(self: *const AmCoherent) LoopStats {
        return .{ .lock = self.lock, .freq = self.freq };
    }

    pub fn process(self: *AmCoherent, z: []const C32, out: []f32) usize {
        std.debug.assert(out.len >= z.len);
        for (z, 0..) |c, i| {
            const cs = @cos(self.phase);
            const sn = @sin(self.phase);
            const in_i = c.re * cs + c.im * sn; // derotate by -phase
            const qd = c.im * cs - c.re * sn;
            // Amplitude-normalized phase detector = ½·sin(2·error); without the
            // 1/power the loop gain swings with the signal and goes unstable.
            const pw = in_i * in_i + qd * qd + 1e-6;
            const err = (in_i * qd) / pw;
            self.lock += lock_a * ((in_i * in_i - qd * qd) / pw - self.lock); // cos(2·err)
            self.freq = std.math.clamp(self.freq + beta * err, -freq_clamp, freq_clamp);
            self.phase += self.freq + alpha * err;
            if (self.phase > std.math.pi) self.phase -= 2 * std.math.pi;
            if (self.phase < -std.math.pi) self.phase += 2 * std.math.pi;
            self.dc += dc_a * (in_i - self.dc);
            out[i] = in_i - self.dc;
        }
        return z.len;
    }
};

const testing = std.testing;

fn corr(a: []const f32, b: []const f32) f32 {
    var sab: f64 = 0;
    var saa: f64 = 0;
    var sbb: f64 = 0;
    for (a, b) |x, y| {
        sab += @as(f64, x) * y;
        saa += @as(f64, x) * x;
        sbb += @as(f64, y) * y;
    }
    return @floatCast(sab / (@sqrt(saa * sbb) + 1e-12));
}

test "AmEnv recovers a carrier-AM message" {
    const fs = 16000.0;
    const n = 8000;
    var z: [n]C32 = undefined;
    var msg: [n]f32 = undefined;
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / fs;
        const m: f32 = @floatCast(@cos(2.0 * std.math.pi * 500.0 * t)); // 500 Hz tone
        msg[i] = m;
        const amp = 1.0 + 0.5 * m; // AM with carrier (always > 0)
        z[i] = .{ .re = amp, .im = 0 };
    }
    var d = AmEnv{};
    var out: [n]f32 = undefined;
    _ = d.process(&z, &out);
    try testing.expect(@abs(corr(out[1000..], msg[1000..])) > 0.95);
}

test "AmCoherent recovers DSB-SC under a carrier offset" {
    const fs = 16000.0;
    const n = 16000;
    var z: [n]C32 = undefined;
    var msg: [n]f32 = undefined;
    const foff = 30.0; // residual carrier offset, Hz
    for (0..n) |i| {
        const t = @as(f64, @floatFromInt(i)) / fs;
        const m: f32 = @floatCast(@cos(2.0 * std.math.pi * 600.0 * t));
        msg[i] = m;
        const ph = 2.0 * std.math.pi * foff * t + 0.7;
        z[i] = .{ .re = @floatCast(m * @cos(ph)), .im = @floatCast(m * @sin(ph)) };
    }
    var d = AmCoherent{};
    var out: [n]f32 = undefined;
    _ = d.process(&z, &out);
    // after lock-in (skip first half), |correlation| with the message is high
    try testing.expect(@abs(corr(out[8000..], msg[8000..])) > 0.9);
    // and the loop reports itself locked
    try testing.expect(d.stats().lock > 0.8);
}

test "AmEnv DC block removes a constant bias" {
    var z: [8000]C32 = undefined;
    for (&z) |*c| c.* = .{ .re = 3.0, .im = 4.0 }; // |z| = 5, constant
    var d = AmEnv{};
    var out: [8000]f32 = undefined;
    _ = d.process(&z, &out);
    try testing.expectApproxEqAbs(@as(f32, 0), out[7999], 0.05); // DC settled out
}
