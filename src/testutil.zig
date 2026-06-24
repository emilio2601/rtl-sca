const std = @import("std");

/// Single-bin Goertzel power of frequency `f` over `x` (sampled at `fs`).
pub fn goertzelPower(x: []const f32, f: f64, fs: f64) f64 {
    const w = 2.0 * std.math.pi * f / fs;
    const c = 2.0 * @cos(w);
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (x) |v| {
        const s0 = @as(f64, v) + c * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return s1 * s1 + s2 * s2 - c * s1 * s2;
}

/// Ratio of power in the `f` bin to power in an off-signal `ref` bin — a simple,
/// scale-free "is the tone there" metric for the DSP integration tests.
pub fn toneDominance(x: []const f32, f: f64, ref: f64, fs: f64) f64 {
    return goertzelPower(x, f, fs) / goertzelPower(x, ref, fs);
}

/// Fill `out` with a real tone FM-modulated by a single audio tone:
/// phase = 2π·carrier·t + (dev/fm)·sin(2π·fm·t).
pub fn fmTone(out: []f32, carrier: f64, fm: f64, dev: f64, fs: f64) void {
    for (out, 0..) |*s, n| {
        const t = @as(f64, @floatFromInt(n)) / fs;
        const ph = 2.0 * std.math.pi * carrier * t + (dev / fm) * @sin(2.0 * std.math.pi * fm * t);
        s.* = @floatCast(@cos(ph));
    }
}
