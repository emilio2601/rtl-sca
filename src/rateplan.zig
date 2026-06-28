const std = @import("std");

/// FM occupied bandwidth (Carson): 2·(75 kHz peak dev + ~100 kHz top MPX freq
/// for a 92 kHz SCA). The complex IQ must stay at or above this before the
/// discriminator, or the FM sidebands clip and audio degrades.
pub const CARSON_BW: f64 = 350_000;

/// Keep the real MPX at or above this before subcarrier extraction, so the
/// 92 kHz slot and its sidebands survive (SPEC §7).
pub const MPX_MIN: f64 = 240_000;

pub const Error = error{NyquistTrap};

/// Reduced rational resampling ratio, output = input · L / M.
pub const Ratio = struct { l: usize, m: usize };

/// The full rate chain derived once from the configured input and audio rates.
/// The IQ→MPX decimation `d0·d1` is factored so the discriminator runs at the
/// lowest rate that still preserves the FM signal (`fs_demod ≥ CARSON_BW`), while
/// `fs_mpx` lands at the same value the single-stage chain produced.
pub const RatePlan = struct {
    fs_iq: f64,
    d0: usize, // complex IQ decimation, pre-demod
    fs_demod: f64, // discriminator rate = fs_iq / d0
    d1: usize, // real MPX decimation, post-demod
    fs_mpx: f64, // subcarrier-stage rate = fs_demod / d1
    d2: usize, // integer decimation to the content rate
    fs_chan: f64, // demod + de-emph rate = fs_mpx / d2, driven by bandwidth
    resamp: Ratio, // fs_chan → fs_audio, reduced L/M
    fs_audio: u32, // exact output rate

    pub fn decimTotal(self: RatePlan) usize {
        return self.d0 * self.d1;
    }
};

/// Largest `d` dividing `n` with `n / d >= min_quotient` (so the post-decimation
/// rate stays at or above the floor). Falls back to 1, which always satisfies it
/// when `n >= min_quotient`.
fn largestDivisor(n: usize, min_quotient: usize) usize {
    if (min_quotient == 0) return 1;
    var d: usize = @max(1, n / min_quotient);
    while (d > 1 and n % d != 0) d -= 1;
    return d;
}

/// Largest divisor of `n` that is `<= cap`.
fn largestDivisorLE(n: usize, cap: usize) usize {
    var d: usize = @max(1, @min(n, cap));
    while (d > 1 and n % d != 0) d -= 1;
    return d;
}

/// Baseband low-pass cutoff that isolates `bw_hz` of *unique* spectrum. `--bw`
/// always means the unique bandwidth recovered: the real main channel (sub==0)
/// keeps `bw` of audio (cut at bw), while a complex subcarrier slot is `bw` wide
/// (±bw/2). The real/complex factor of 2 is hidden here, not in the flag.
pub fn channelCutoff(sub_hz: u32, bw_hz: u32) f64 {
    const bw: f64 = @floatFromInt(bw_hz);
    return if (sub_hz == 0) bw else bw / 2.0;
}

pub fn plan(fs_iq_hz: u32, fs_audio_target: u32, sub_hz: u32, bw_hz: u32) Error!RatePlan {
    const fs_iq_u: usize = fs_iq_hz;
    const fs_iq: f64 = @floatFromInt(fs_iq_hz);

    // Total IQ→MPX decimation: bring the MPX as close to MPX_MIN as a clean
    // divisor allows (this matches the old single-stage factor exactly).
    const d_total = largestDivisor(fs_iq_u, @intFromFloat(MPX_MIN));
    const fs_mpx_u = fs_iq_u / d_total;
    const fs_mpx: f64 = @floatFromInt(fs_mpx_u);
    if (fs_mpx < MPX_MIN) return error.NyquistTrap;

    // Split d_total = d0·d1 with d0 as large as possible (lowest demod rate)
    // subject to fs_iq/d0 >= CARSON_BW.
    const d0_cap: usize = @intFromFloat(fs_iq / CARSON_BW);
    const d0 = largestDivisorLE(d_total, d0_cap);
    const d1 = d_total / d0;
    const fs_demod = fs_iq / @as(f64, @floatFromInt(d0));

    // Audio side: the channel rate serves the *content* (the channel cutoff plus
    // transition margin), independent of the output rate — main mono (15 kHz)
    // needs far more than an SCA voice slot. The resampler then bridges fs_chan
    // to fs_audio. floor keeps fs_chan ≥ target so the channel filter is feasible.
    const cutoff = channelCutoff(sub_hz, bw_hz);
    const fs_chan_target = @max(16_000.0, 2.5 * cutoff);
    const d2: usize = @max(1, @as(usize, @intFromFloat(@floor(fs_mpx / fs_chan_target))));
    const fs_chan = fs_mpx / @as(f64, @floatFromInt(d2));

    const num: usize = @as(usize, fs_audio_target) * d2;
    const den: usize = fs_mpx_u;
    const g = std.math.gcd(num, den);

    return .{
        .fs_iq = fs_iq,
        .d0 = d0,
        .fs_demod = fs_demod,
        .d1 = d1,
        .fs_mpx = fs_mpx,
        .d2 = d2,
        .fs_chan = fs_chan,
        .resamp = .{ .l = num / g, .m = den / g },
        .fs_audio = fs_audio_target,
    };
}

const testing = std.testing;

test "1.024M SCA → 16k reproduces the canonical chain as a passthrough" {
    const p = try plan(1_024_000, 16_000, 67_000, 8_000);
    try testing.expectEqual(@as(usize, 2), p.d0);
    try testing.expectEqual(@as(f64, 512_000), p.fs_demod);
    try testing.expectEqual(@as(usize, 2), p.d1);
    try testing.expectEqual(@as(f64, 256_000), p.fs_mpx);
    try testing.expectEqual(@as(usize, 16), p.d2);
    try testing.expectEqual(@as(f64, 16_000), p.fs_chan);
    try testing.expectEqual(@as(usize, 1), p.resamp.l);
    try testing.expectEqual(@as(usize, 1), p.resamp.m);
    try testing.expectEqual(@as(usize, 4), p.decimTotal());
}

test "2.048M keeps fs_mpx at 256k with demod at 512k" {
    const p = try plan(2_048_000, 16_000, 67_000, 8_000);
    try testing.expectEqual(@as(usize, 8), p.decimTotal());
    try testing.expectEqual(@as(f64, 256_000), p.fs_mpx);
    try testing.expectEqual(@as(f64, 512_000), p.fs_demod); // d0=4
    try testing.expectEqual(@as(usize, 4), p.d0);
    try testing.expectEqual(@as(usize, 2), p.d1);
    try testing.expect(p.fs_demod >= CARSON_BW);
}

test "SCA content rate stays 16k regardless of a 48k output (3/1 upsample)" {
    const p = try plan(1_024_000, 48_000, 67_000, 8_000);
    try testing.expectEqual(@as(usize, 16), p.d2);
    try testing.expectEqual(@as(f64, 16_000), p.fs_chan); // demod still at 16k
    try testing.expectEqual(@as(usize, 3), p.resamp.l);
    try testing.expectEqual(@as(usize, 1), p.resamp.m);
    try testing.expectEqual(@as(u32, 48_000), p.fs_audio);
}

test "main mono (--bw 15k) gets a content rate that carries 15 kHz" {
    const p = try plan(1_024_000, 48_000, 0, 15_000);
    try testing.expectEqual(@as(usize, 6), p.d2);
    try testing.expect(p.fs_chan / 2.0 > 15_000); // Nyquist covers full mono audio
    try testing.expectEqual(@as(usize, 9), p.resamp.l);
    try testing.expectEqual(@as(usize, 8), p.resamp.m);
}

test "non-divisible rate is accepted (degrades, does not reject)" {
    // 1.0M: the old chain rejected this. Now it plans cleanly.
    const p = try plan(1_000_000, 16_000, 67_000, 8_000);
    try testing.expect(p.fs_mpx >= MPX_MIN);
    try testing.expect(p.fs_demod >= CARSON_BW);
    try testing.expect(p.decimTotal() >= 1);
    // 1_000_000 = 2^6·5^6 → d_total = floor(1e6/240000)=4, 1e6%4==0 → fs_mpx=250k.
    try testing.expectEqual(@as(f64, 250_000), p.fs_mpx);
}

test "rate below the MPX floor traps" {
    try testing.expectError(error.NyquistTrap, plan(200_000, 16_000, 67_000, 8_000));
}
