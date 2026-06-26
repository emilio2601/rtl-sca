const std = @import("std");
const C32 = @import("complex.zig").C32;

/// Iterative radix-2 decimation-in-time FFT with precomputed twiddles and a
/// bit-reversal permutation. `n` must be a power of two (n <= 65536).
pub const Fft = struct {
    n: usize,
    tw: []C32, // n/2 twiddles: tw[k] = exp(-j2πk/n)
    rev: []u16, // bit-reversal permutation

    pub fn init(a: std.mem.Allocator, n: usize) !Fft {
        std.debug.assert(std.math.isPowerOfTwo(n) and n <= 65536);
        const log2n: u5 = @intCast(std.math.log2_int(usize, n));
        const tw = try a.alloc(C32, n / 2);
        for (tw, 0..) |*t, k| {
            const ph = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            t.* = .{ .re = @floatCast(@cos(ph)), .im = @floatCast(@sin(ph)) };
        }
        const rev = try a.alloc(u16, n);
        for (rev, 0..) |*r, i| {
            var x: usize = i;
            var y: usize = 0;
            var b: u5 = 0;
            while (b < log2n) : (b += 1) {
                y = (y << 1) | (x & 1);
                x >>= 1;
            }
            r.* = @intCast(y);
        }
        return .{ .n = n, .tw = tw, .rev = rev };
    }

    pub fn deinit(self: *Fft, a: std.mem.Allocator) void {
        a.free(self.tw);
        a.free(self.rev);
    }

    /// In-place forward FFT on x[0..n] (caller sets imag=0 for real input).
    pub fn forward(self: *const Fft, x: []C32) void {
        std.debug.assert(x.len == self.n);
        for (0..self.n) |i| {
            const j = self.rev[i];
            if (j > i) std.mem.swap(C32, &x[i], &x[j]);
        }
        var len: usize = 2;
        while (len <= self.n) : (len <<= 1) {
            const half = len / 2;
            const step = self.n / len;
            var base: usize = 0;
            while (base < self.n) : (base += len) {
                var j: usize = 0;
                while (j < half) : (j += 1) {
                    const t = x[base + j + half].mul(self.tw[j * step]);
                    const u = x[base + j];
                    x[base + j] = u.add(t);
                    x[base + j + half] = u.sub(t);
                }
            }
        }
    }
};

/// Welch averaged power spectrum of a real signal: Hann window, 50% overlap,
/// one-sided (length n/2+1), accumulated in f64. Relative scaling is what the
/// caller needs (peak-minus-floor dB), but it is normalized so a tone reads a
/// stable level across segment counts.
pub const Welch = struct {
    fft: Fft,
    win: []f32,
    seg: []C32,
    psd: []f64, // length n/2+1
    win_pow: f64,
    nseg: usize = 0,

    pub fn init(a: std.mem.Allocator, n: usize) !Welch {
        const win = try a.alloc(f32, n);
        var wp: f64 = 0;
        for (win, 0..) |*wv, i| {
            const w = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1)));
            wv.* = @floatCast(w);
            wp += w * w;
        }
        return .{
            .fft = try Fft.init(a, n),
            .win = win,
            .seg = try a.alloc(C32, n),
            .psd = try a.alloc(f64, n / 2 + 1),
            .win_pow = wp,
        };
    }

    pub fn deinit(self: *Welch, a: std.mem.Allocator) void {
        self.fft.deinit(a);
        a.free(self.win);
        a.free(self.seg);
        a.free(self.psd);
    }

    fn addSegment(self: *Welch, x: []const f32) void {
        const n = self.fft.n;
        for (0..n) |i| self.seg[i] = .{ .re = x[i] * self.win[i], .im = 0 };
        self.fft.forward(self.seg);
        for (self.psd, 0..) |*p, i| p.* += self.seg[i].re * self.seg[i].re + self.seg[i].im * self.seg[i].im;
        self.nseg += 1;
    }

    /// Welch over a full real buffer with 50% overlap; fills psd[] normalized.
    pub fn run(self: *Welch, x: []const f32) void {
        @memset(self.psd, 0);
        self.nseg = 0;
        const n = self.fft.n;
        const step = n / 2;
        var s: usize = 0;
        while (s + n <= x.len) : (s += step) self.addSegment(x[s .. s + n]);
        if (self.nseg == 0) return;
        const scale = 1.0 / (@as(f64, @floatFromInt(self.nseg)) * self.win_pow);
        for (self.psd, 0..) |*p, i| {
            p.* *= scale;
            if (i != 0 and i != n / 2) p.* *= 2.0; // one-sided
        }
    }

    pub fn binHz(self: *const Welch, i: usize, fs: f64) f64 {
        return @as(f64, @floatFromInt(i)) * fs / @as(f64, @floatFromInt(self.fft.n));
    }
    pub fn hzBin(self: *const Welch, hz: f64, fs: f64) usize {
        return @intFromFloat(@round(hz * @as(f64, @floatFromInt(self.fft.n)) / fs));
    }
};

const testing = std.testing;

test "FFT of an impulse is flat" {
    var f = try Fft.init(testing.allocator, 64);
    defer f.deinit(testing.allocator);
    var x: [64]C32 = undefined;
    @memset(&x, C32.zero);
    x[0] = .{ .re = 1, .im = 0 };
    f.forward(&x);
    for (x) |c| try testing.expectApproxEqAbs(@as(f32, 1.0), c.mag(), 1e-5);
}

test "FFT of a complex tone lands in one bin" {
    const n = 256;
    var f = try Fft.init(testing.allocator, n);
    defer f.deinit(testing.allocator);
    var x: [n]C32 = undefined;
    const k = 40;
    for (&x, 0..) |*c, m| {
        const ph = 2.0 * std.math.pi * @as(f64, @floatFromInt(k * m)) / @as(f64, n);
        c.* = .{ .re = @floatCast(@cos(ph)), .im = @floatCast(@sin(ph)) };
    }
    f.forward(&x);
    try testing.expectApproxEqAbs(@as(f32, n), x[k].mag(), 0.05);
    for (x, 0..) |c, i| if (i != k) try testing.expect(c.mag() < 0.05);
}

test "FFT of a real cosine folds to bins k and n-k" {
    const n = 256;
    var f = try Fft.init(testing.allocator, n);
    defer f.deinit(testing.allocator);
    var x: [n]C32 = undefined;
    const k = 30;
    for (&x, 0..) |*c, m| {
        c.* = .{ .re = @floatCast(@cos(2.0 * std.math.pi * @as(f64, @floatFromInt(k * m)) / @as(f64, n))), .im = 0 };
    }
    f.forward(&x);
    try testing.expectApproxEqAbs(@as(f32, n / 2), x[k].mag(), 0.05);
    try testing.expectApproxEqAbs(@as(f32, n / 2), x[n - k].mag(), 0.05);
}

test "Parseval" {
    const n = 128;
    var f = try Fft.init(testing.allocator, n);
    defer f.deinit(testing.allocator);
    var x: [n]C32 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();
    var energy_t: f64 = 0;
    for (&x) |*c| {
        c.* = .{ .re = rnd.floatNorm(f32), .im = rnd.floatNorm(f32) };
        energy_t += @as(f64, c.re) * c.re + @as(f64, c.im) * c.im;
    }
    f.forward(&x);
    var energy_f: f64 = 0;
    for (x) |c| energy_f += @as(f64, c.re) * c.re + @as(f64, c.im) * c.im;
    try testing.expectApproxEqRel(energy_t, energy_f / @as(f64, n), 1e-4);
}

test "Welch puts a real tone in the right bin, well above the floor" {
    const n = 4096;
    const fs = 256000.0;
    var w = try Welch.init(testing.allocator, n);
    defer w.deinit(testing.allocator);
    const N = 200_000;
    const x = try testing.allocator.alloc(f32, N);
    defer testing.allocator.free(x);
    for (x, 0..) |*s, i| s.* = @floatCast(@cos(2.0 * std.math.pi * 30000.0 * @as(f64, @floatFromInt(i)) / fs));
    w.run(x);
    const kbin = w.hzBin(30000, fs);
    try testing.expectEqual(@as(usize, 480), kbin);
    // peak bin dominates a far-away bin by >40 dB
    const peak_db = 10.0 * std.math.log10(w.psd[kbin]);
    const off_db = 10.0 * std.math.log10(w.psd[1000] + 1e-20);
    try testing.expect(peak_db - off_db > 40);
}
