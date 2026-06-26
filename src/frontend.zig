const std = @import("std");
const C32 = @import("complex.zig").C32;
const FmDemod = @import("fmdemod.zig").FmDemod;
const fir = @import("firdecim.zig");
const rateplan = @import("rateplan.zig");
const RatePlan = rateplan.RatePlan;

pub const Error = fir.BuildError;

/// IQ → real MPX front-end shared by `play`/`rec` (pipeline) and `scan` (detect).
/// Decimate-first 3-stage chain (SPEC §4 rate plan): a gentle complex anti-alias
/// drops the IQ to `fs_demod` (still ≥ Carson bandwidth, lossless), the polar
/// discriminator runs there, then a real FIR decimates to `fs_mpx`. Owns the
/// intermediate buffers sized at init; callers provide only the final output.
pub const Frontend = struct {
    fir0: ?fir.FirDecim(C32), // null when d0 == 1 (no pre-decimation needed)
    demod1: FmDemod,
    fir1: fir.FirDecim(f32),
    iq_dec: []C32,
    mpx_demod: []f32,
    d1: usize,
    decim_total: usize,
    fs_mpx: f64,

    pub fn init(a: std.mem.Allocator, plan: RatePlan, max_block: usize) Error!Frontend {
        const cutoff1 = plan.fs_mpx * 0.43; // ~110 kHz at 256 ksps
        const mpx_demod = try a.alloc(f32, max_block / plan.d0 + 2);

        var fir0: ?fir.FirDecim(C32) = null;
        var iq_dec: []C32 = &.{};
        if (plan.d0 > 1) {
            // Pass the full FM signal; the stop only needs to land by fs_demod/2.
            const cutoff0 = @min(rateplan.CARSON_BW / 2.0, plan.fs_demod * 0.45);
            fir0 = try fir.build(C32, a, plan.fs_iq, cutoff0, plan.d0);
            iq_dec = try a.alloc(C32, max_block / plan.d0 + 2);
        }

        return .{
            .fir0 = fir0,
            .demod1 = .{},
            .fir1 = try fir.build(f32, a, plan.fs_demod, cutoff1, plan.d1),
            .iq_dec = iq_dec,
            .mpx_demod = mpx_demod,
            .d1 = plan.d1,
            .decim_total = plan.decimTotal(),
            .fs_mpx = plan.fs_mpx,
        };
    }

    /// IQ block → real MPX at fs_mpx. `out` must hold >= outCap(iq.len) samples.
    pub fn process(self: *Frontend, iq: []const C32, out: []f32) usize {
        const nmpx = if (self.fir0) |*f0| blk: {
            const nd = f0.process(iq, self.iq_dec);
            break :blk self.demod1.process(self.iq_dec[0..nd], self.mpx_demod);
        } else self.demod1.process(iq, self.mpx_demod);
        return self.fir1.process(self.mpx_demod[0..nmpx], out);
    }

    /// Upper bound on MPX samples produced from `in_len` IQ samples.
    pub fn outCap(self: *const Frontend, in_len: usize) usize {
        return in_len / self.decim_total + 2;
    }
};
