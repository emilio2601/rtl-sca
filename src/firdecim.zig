const std = @import("std");
const C32 = @import("complex.zig").C32;

pub const Window = enum { hamming };

/// Hamming tap count for a given transition width; forced odd for a Type-I
/// linear-phase filter with an integer-sample group delay.
pub fn tapCount(fs_in: f64, transition_hz: f64) usize {
    const nf = 3.3 / (transition_hz / fs_in);
    var n: usize = @ceil(nf);
    if (n % 2 == 0) n += 1;
    return n;
}

/// Generate windowed-sinc lowpass taps normalized to unity DC gain.
/// `cutoff_hz` is the lowpass band edge; taps.len sets the order (see tapCount).
pub fn genTaps(taps: []f32, fs_in: f64, cutoff_hz: f64, window: Window) void {
    _ = window; // Hamming only for now
    const n = taps.len;
    const fc = cutoff_hz / fs_in; // normalized, cycles/sample
    const m: f64 = @floatFromInt(n - 1);
    var sum: f64 = 0;
    for (0..n) |i| {
        const k: f64 = @floatFromInt(i);
        const x = k - m / 2.0;
        const sinc = if (x == 0) 2 * fc else @sin(2 * std.math.pi * fc * x) / (std.math.pi * x);
        const w = 0.54 - 0.46 * @cos(2 * std.math.pi * k / m);
        const v = sinc * w;
        taps[i] = @floatCast(v);
        sum += v;
    }
    const inv = 1.0 / sum;
    for (taps) |*t| t.* = @floatCast(@as(f64, t.*) * inv);
}

/// Decimating FIR over `Elem` (f32 for real signals, C32 for complex). Taps are
/// real; a complex signal is filtered as two real convolutions.
///
/// The history is a **mirror buffer**: `ring.len == 2 * taps.len`, and each input
/// sample is written twice (at `w` and `w + n`). That keeps the most-recent `n`
/// samples a *contiguous* slice `ring[w .. w + n]` regardless of wrap, so `dot`
/// is a straight contiguous dot product that vectorizes. Taps here are
/// linear-phase (symmetric), so the window can be read oldest→newest against
/// taps directly. Caller owns `taps` and `ring`, preallocated once.
pub fn FirDecim(comptime Elem: type) type {
    return struct {
        const Self = @This();
        const lanes = std.simd.suggestVectorLength(f32) orelse 4;

        taps: []const f32,
        ring: []Elem, // 2*n mirror buffer
        n: usize, // taps.len
        w: usize = 0, // write index in [0, n); also start of the live window
        phase: usize = 0,
        decim: usize,

        pub fn init(taps: []const f32, ring: []Elem, decim: usize) Self {
            std.debug.assert(ring.len == 2 * taps.len);
            for (ring) |*r| r.* = elemZero();
            return .{ .taps = taps, .ring = ring, .n = taps.len, .decim = decim };
        }

        inline fn elemZero() Elem {
            return if (Elem == f32) 0 else Elem.zero;
        }

        /// Push `in`, append decimated outputs to `out`, return the count written.
        /// `out` must have capacity >= in.len / decim + 1.
        pub fn process(self: *Self, in: []const Elem, out: []Elem) usize {
            var n: usize = 0;
            for (in) |s| {
                self.ring[self.w] = s;
                self.ring[self.w + self.n] = s; // mirror copy
                self.w += 1;
                if (self.w == self.n) self.w = 0;
                self.phase += 1;
                if (self.phase == self.decim) {
                    self.phase = 0;
                    out[n] = self.dot();
                    n += 1;
                }
            }
            return n;
        }

        fn dot(self: *const Self) Elem {
            @setFloatMode(.optimized); // allow FMA + reduction reassociation
            const win = self.ring[self.w .. self.w + self.n]; // contiguous, oldest→newest
            const L = lanes;
            if (Elem == f32) {
                const V = @Vector(L, f32);
                var acc: V = @splat(0);
                var j: usize = 0;
                while (j + L <= self.n) : (j += L) {
                    const wv: V = win[j..][0..L].*;
                    const tv: V = self.taps[j..][0..L].*;
                    acc += wv * tv;
                }
                var s = @reduce(.Add, acc);
                while (j < self.n) : (j += 1) s += win[j] * self.taps[j];
                return s;
            } else {
                // C32: reinterpret the window as interleaved f32 [re,im,...] and
                // duplicate each tap across the pair, then split re/im at the end.
                const dup: @Vector(2 * L, i32) = comptime blk: {
                    var m: [2 * L]i32 = undefined;
                    for (0..L) |k| {
                        m[2 * k] = @intCast(k);
                        m[2 * k + 1] = @intCast(k);
                    }
                    break :blk m;
                };
                const evn: @Vector(L, i32) = comptime blk: {
                    var m: [L]i32 = undefined;
                    for (0..L) |k| m[k] = @intCast(2 * k);
                    break :blk m;
                };
                const odd: @Vector(L, i32) = comptime blk: {
                    var m: [L]i32 = undefined;
                    for (0..L) |k| m[k] = @intCast(2 * k + 1);
                    break :blk m;
                };
                const Vf = @Vector(2 * L, f32);
                const wf: [*]const f32 = @ptrCast(win.ptr);
                var acc: Vf = @splat(0);
                var j: usize = 0;
                while (j + L <= self.n) : (j += L) {
                    const wv: Vf = wf[2 * j ..][0 .. 2 * L].*;
                    const tl: @Vector(L, f32) = self.taps[j..][0..L].*;
                    acc += wv * @shuffle(f32, tl, undefined, dup);
                }
                var re = @reduce(.Add, @shuffle(f32, acc, undefined, evn));
                var im = @reduce(.Add, @shuffle(f32, acc, undefined, odd));
                while (j < self.n) : (j += 1) {
                    re += wf[2 * j] * self.taps[j];
                    im += wf[2 * j + 1] * self.taps[j];
                }
                return .{ .re = re, .im = im };
            }
        }
    };
}

pub const BuildError = error{ FilterTooSharp, BadBandwidth } || std.mem.Allocator.Error;
pub const max_taps = 4096;

/// Allocate taps + ring from `a` and build a decimating FIR. The transition band
/// is sized to land the stopband at the post-decimation fold (fs_out/2).
pub fn build(comptime Elem: type, a: std.mem.Allocator, fs_in: f64, cutoff: f64, decim: usize) BuildError!FirDecim(Elem) {
    if (cutoff <= 0) return error.BadBandwidth;
    const fs_out = fs_in / @as(f64, @floatFromInt(decim));
    const transition = fs_out / 2.0 - cutoff;
    if (transition <= 0) return error.BadBandwidth;
    const n = tapCount(fs_in, transition);
    if (n > max_taps) return error.FilterTooSharp;
    const taps = try a.alloc(f32, n);
    genTaps(taps, fs_in, cutoff, .hamming);
    const ring = try a.alloc(Elem, 2 * n); // mirror buffer
    return FirDecim(Elem).init(taps, ring, decim);
}

const testing = std.testing;

fn gainAtReal(taps: []const f32, fs: f64, f: f64) f32 {
    const ring = testing.allocator.alloc(f32, 2 * taps.len) catch unreachable;
    defer testing.allocator.free(ring);
    var fir = FirDecim(f32).init(taps, ring, 1);
    var in: [8192]f32 = undefined;
    var out: [8192]f32 = undefined;
    for (&in, 0..) |*s, i| s.* = @floatCast(@sin(2.0 * std.math.pi * f * @as(f64, @floatFromInt(i)) / fs));
    const n = fir.process(&in, &out);
    var acc: f64 = 0;
    for (out[n / 2 .. n]) |s| acc += @as(f64, s) * s;
    const rms_out = @sqrt(acc / @as(f64, @floatFromInt(n - n / 2)));
    return @floatCast(rms_out / (1.0 / @sqrt(2.0)));
}

test "taps sum to unity (DC gain)" {
    var taps: [101]f32 = undefined;
    genTaps(&taps, 256000, 8000, .hamming);
    var sum: f64 = 0;
    for (taps) |t| sum += t;
    try testing.expectApproxEqAbs(@as(f64, 1.0), sum, 1e-6);
}

test "passband passes, stopband rejected" {
    var taps: [151]f32 = undefined;
    genTaps(&taps, 256000, 8000, .hamming);
    try testing.expectApproxEqAbs(@as(f32, 1.0), gainAtReal(&taps, 256000, 2000), 0.05);
    try testing.expect(gainAtReal(&taps, 256000, 40000) < 0.02); // deep stopband
}

test "decimation output count and values are block-split invariant" {
    var taps: [65]f32 = undefined;
    genTaps(&taps, 256000, 8000, .hamming);
    var ring1: [130]f32 = undefined;
    var ring2: [130]f32 = undefined;

    var in: [1000]f32 = undefined;
    for (&in, 0..) |*s, i| s.* = @floatCast(@sin(2.0 * std.math.pi * 1234.0 * @as(f64, @floatFromInt(i)) / 256000.0));

    var whole: [100]f32 = undefined;
    var split: [100]f32 = undefined;

    var f1 = FirDecim(f32).init(&taps, &ring1, 16);
    const n_whole = f1.process(&in, &whole);

    var f2 = FirDecim(f32).init(&taps, &ring2, 16);
    var n_split = f2.process(in[0..333], split[0..]);
    n_split += f2.process(in[333..], split[n_split..]);

    try testing.expectEqual(n_whole, n_split);
    for (whole[0..n_whole], split[0..n_split]) |a, b| try testing.expectApproxEqAbs(a, b, 1e-6);
}

test "complex FIR filters re and im independently" {
    var taps: [65]f32 = undefined;
    genTaps(&taps, 256000, 8000, .hamming);
    var ring: [130]C32 = undefined;
    var fir = FirDecim(C32).init(&taps, &ring, 1);

    var in: [256]C32 = undefined;
    @memset(&in, C32{ .re = 1, .im = -1 });
    var out: [256]C32 = undefined;
    const n = fir.process(&in, &out);
    // after warm-up a constant DC input passes at unity gain on both rails
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[n - 1].re, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, -1.0), out[n - 1].im, 1e-3);
}
