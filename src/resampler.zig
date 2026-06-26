const std = @import("std");
const fir = @import("firdecim.zig");

pub const BuildError = fir.BuildError;

/// Polyphase rational resampler over real audio: output rate = input · L / M.
/// The prototype lowpass is designed once at the upsampled rate (fs_in·L) and
/// split into L phases of P taps each; the per-sample path is allocation-free and
/// carries an input history ring across blocks, mirroring `FirDecim`. When
/// L == M == 1 it degrades to a zero-cost passthrough.
pub const Resampler = struct {
    l: usize,
    m: usize,
    p: usize, // taps per phase
    pf: []f32, // L·P taps, phase-major, gain-compensated (empty when passthrough)
    ring: []f32, // last P inputs
    head: usize = 0,
    nin: u64 = 0, // total inputs consumed
    base: u64 = 0, // input index the next output reads as its newest sample
    phase: usize = 0, // polyphase branch of the next output

    /// `cutoff` is the lowpass passband edge in Hz (anti-image + anti-alias),
    /// e.g. 0.45·min(fs_in, fs_out). Taps and ring are allocated from `a` once.
    pub fn build(a: std.mem.Allocator, fs_in: f64, l: usize, m: usize, cutoff: f64) BuildError!Resampler {
        if (l == 1 and m == 1) {
            return .{ .l = 1, .m = 1, .p = 0, .pf = &.{}, .ring = &.{} };
        }
        if (cutoff <= 0) return error.BadBandwidth;
        const fs_out = fs_in * @as(f64, @floatFromInt(l)) / @as(f64, @floatFromInt(m));
        const f_lo = @min(fs_in, fs_out);
        const transition = f_lo / 2.0 - cutoff;
        if (transition <= 0) return error.BadBandwidth;

        // P is the per-phase length set by the transition at the low rate; the
        // prototype is L·P long, designed at the upsampled rate.
        const p = fir.tapCount(f_lo, transition);
        const fs_high = fs_in * @as(f64, @floatFromInt(l));
        const lp = p * l;
        if (p > fir.max_taps) return error.FilterTooSharp;

        const proto = try a.alloc(f32, lp);
        fir.genTaps(proto, fs_high, cutoff, .hamming);

        // Reorder to phase-major and bake in the interpolation gain (·L), so each
        // phase has ~unity DC gain despite the zero-stuffing.
        const pf = try a.alloc(f32, lp);
        const lf: f32 = @floatFromInt(l);
        for (0..l) |ph| {
            for (0..p) |j| {
                pf[ph * p + j] = proto[ph + j * l] * lf;
            }
        }

        const ring = try a.alloc(f32, p);
        @memset(ring, 0);
        return .{ .l = l, .m = m, .p = p, .pf = pf, .ring = ring };
    }

    /// Push `in`, append resampled outputs to `out`, return the count written.
    /// `out` must have capacity >= in.len·L/M + 1.
    pub fn process(self: *Resampler, in: []const f32, out: []f32) usize {
        if (self.l == 1 and self.m == 1) {
            @memcpy(out[0..in.len], in);
            return in.len;
        }
        var n: usize = 0;
        for (in) |x| {
            self.ring[self.head] = x;
            self.head += 1;
            if (self.head == self.ring.len) self.head = 0;
            self.nin += 1;
            // Emit every output whose newest input sample has now arrived.
            while (self.base < self.nin) {
                out[n] = self.dot(self.phase);
                n += 1;
                const s = self.phase + self.m;
                self.base += s / self.l;
                self.phase = s % self.l;
            }
        }
        return n;
    }

    fn dot(self: *const Resampler, phase: usize) f32 {
        var acc: f32 = 0;
        var idx = self.head; // one past the newest input
        const off = phase * self.p;
        for (0..self.p) |j| {
            idx = if (idx == 0) self.ring.len - 1 else idx - 1;
            acc += self.pf[off + j] * self.ring[idx];
        }
        return acc;
    }
};

const testing = std.testing;
const tu = @import("testutil.zig");

test "passthrough is an exact copy" {
    var r = try Resampler.build(testing.allocator, 16000, 1, 1, 7200);
    var in: [64]f32 = undefined;
    for (&in, 0..) |*s, i| s.* = @floatCast(@sin(@as(f64, @floatFromInt(i))));
    var out: [64]f32 = undefined;
    const n = r.process(&in, &out);
    try testing.expectEqual(@as(usize, 64), n);
    for (in, out) |a, b| try testing.expectEqual(a, b);
}

test "output count tracks L/M" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 51200 → 48000 is 15/16.
    var r = try Resampler.build(arena.allocator(), 51200, 15, 16, 0.45 * 48000);
    var in: [16000]f32 = undefined;
    @memset(&in, 0);
    var out: [16001]f32 = undefined;
    const n = r.process(&in, &out);
    const expected = in.len * 15 / 16;
    try testing.expect(n >= expected - 1 and n <= expected + 1);
}

test "a 1 kHz tone survives 51200 → 48000" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r = try Resampler.build(arena.allocator(), 51200, 15, 16, 0.45 * 48000);
    const n_in = 51200;
    const in = try arena.allocator().alloc(f32, n_in);
    for (in, 0..) |*s, i| {
        s.* = @floatCast(@sin(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / 51200.0));
    }
    const out = try arena.allocator().alloc(f32, n_in * 15 / 16 + 2);
    const n = r.process(in, out);
    // skip filter warm-up; the 1 kHz tone should dominate at the 48k rate.
    const dom = tu.toneDominance(out[200..n], 1000, 3000, 48000);
    try testing.expect(dom > 50);
}

test "process is identical split across blocks (state carries)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in: [600]f32 = undefined;
    for (&in, 0..) |*s, i| s.* = @floatCast(@sin(2.0 * std.math.pi * 1234.0 * @as(f64, @floatFromInt(i)) / 51200.0));

    var whole_r = try Resampler.build(a, 51200, 15, 16, 0.45 * 48000);
    var whole: [700]f32 = undefined;
    const nw = whole_r.process(&in, &whole);

    var split_r = try Resampler.build(a, 51200, 15, 16, 0.45 * 48000);
    var split: [700]f32 = undefined;
    const n1 = split_r.process(in[0..256], split[0..]);
    const n2 = split_r.process(in[256..], split[n1..]);

    try testing.expectEqual(nw, n1 + n2);
    for (whole[0..nw], split[0..nw]) |a_, b_| try testing.expectApproxEqAbs(a_, b_, 1e-6);
}
