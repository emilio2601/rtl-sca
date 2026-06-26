const std = @import("std");
const C32 = @import("complex.zig").C32;
const FmDemod = @import("fmdemod.zig").FmDemod;
const fir = @import("firdecim.zig");

pub const MPX_MIN: f64 = 240_000; // keep the MPX above this before extraction (SPEC §7)

pub const Error = error{ RateNotDivisible, NyquistTrap } || fir.BuildError;

/// IQ → real MPX front-end shared by `play`/`rec` (pipeline) and `scan` (detect):
/// FM-demodulate the IQ, then anti-alias and decimate to ~256 ksps. Owns a
/// full-rate scratch buffer sized at init so callers only provide the output.
pub const Frontend = struct {
    demod1: FmDemod,
    fir1: fir.FirDecim(f32),
    scratch: []f32,
    d1: usize,
    fs_mpx: f64,

    pub fn init(a: std.mem.Allocator, rate_hz: u32, max_block: usize) Error!Frontend {
        const fs_iq: f64 = @floatFromInt(rate_hz);
        const d1: usize = @max(1, @as(usize, @intFromFloat(fs_iq / MPX_MIN)));
        if (rate_hz % d1 != 0) return error.RateNotDivisible;
        const fs_mpx = fs_iq / @as(f64, @floatFromInt(d1));
        if (fs_mpx < MPX_MIN) return error.NyquistTrap;
        const cutoff1 = fs_mpx * 0.43; // ~110 kHz at 256 ksps
        return .{
            .demod1 = .{},
            .fir1 = try fir.build(f32, a, fs_iq, cutoff1, d1),
            .scratch = try a.alloc(f32, max_block),
            .d1 = d1,
            .fs_mpx = fs_mpx,
        };
    }

    /// IQ block → real MPX at fs_mpx. `out` must hold >= iq.len/d1 + 2 samples.
    pub fn process(self: *Frontend, iq: []const C32, out: []f32) usize {
        const nmpx = self.demod1.process(iq, self.scratch);
        return self.fir1.process(self.scratch[0..nmpx], out);
    }
};
