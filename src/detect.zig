const std = @import("std");
const C32 = @import("complex.zig").C32;
const Welch = @import("fft.zig").Welch;
const Nco = @import("nco.zig").Nco;
const fir = @import("firdecim.zig");
const FmDemod = @import("fmdemod.zig").FmDemod;

pub const Modulation = enum { fm, am_dsb, data, unknown };

/// The metrics behind a classification, surfaced for `scan -v`. NaN ⇒ not computed
/// (the slot returned before extraction, e.g. below the SNR gate).
pub const SlotMetrics = struct {
    cv_env: f64 = nan,
    audio_db: f64 = nan,
    carrier_db: f64 = nan,
    sym: f64 = nan,
    const nan = std.math.nan(f64);
};

pub const SlotReport = struct {
    center_hz: f64,
    mod: Modulation,
    bw_hz: f64,
    snr_db: f64,
    guess: []const u8,
    metrics: SlotMetrics = .{},

    pub fn format(self: SlotReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d:>3.0} kHz  {t:<8} ~{d:>4.1} kHz  {d:>4.0} dB  {s}", .{
            self.center_hz / 1000.0,
            self.mod,
            self.bw_hz / 1000.0,
            self.snr_db,
            self.guess,
        });
    }
};

pub const ScanResult = struct {
    stereo: bool,
    pilot_snr_db: f64,
    slots: []SlotReport,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ScanResult) void {
        self.arena.deinit();
    }
};

pub const ScanConfig = struct {
    fs_mpx: f64 = 256_000,
    fft_n: usize = 4096,
    snr_gate_db: f64 = 3.0, // classification floor
    slot_gate_db: f64 = 6.0, // region threshold above the global floor
    named_gate_db: f64 = 2.0, // lower gate when probing the canonical 57/67/92 slots
    pilot_gate_db: f64 = 10.0,
    aud_gate_db: f64 = 5.0, // demod-output low/high band power ratio: above ⇒ real audio ⇒ FM
    carr_null_db: f64 = -3.0, // center ≥3 dB below the slot shoulders ⇒ suppressed carrier ⇒ DSB
    cv_hi: f64 = 0.35, // envelope coefficient-of-variation confirming DSB
    sym_hi: f64 = 0.6, // sideband symmetry confirming DSB
    am_snr_db: f64 = 8.0, // AM/DSB is easily faked by noise — demand real SNR
    am_min_bw_hz: f64 = 4000, // DSB of audio is inherently broadband; a narrow symmetric slot is low-dev FM or a data carrier, not DSB
    wide_junk_hz: f64 = 12_000, // a non-standard region wider than this that classifies as nothing is overload/MPX splatter
};

const Region = struct { center_hz: f64, bw_hz: f64, peak_bin: usize };

const named_slots = [_]f64{ 57_000, 67_000, 92_000 };
const max_slots = 12;

pub fn scan(base: std.mem.Allocator, mpx: []const f32, cfg: ScanConfig) !ScanResult {
    var work = std.heap.ArenaAllocator.init(base);
    defer work.deinit();
    const wa = work.allocator();

    var welch = try Welch.init(wa, cfg.fft_n);
    welch.run(mpx);
    const psd = welch.psd; // linear power, length n/2+1
    const psd_db = try wa.alloc(f64, psd.len);
    for (psd, 0..) |p, i| psd_db[i] = 10.0 * std.math.log10(p + 1e-30);

    const fs = cfg.fs_mpx;
    const nyq = fs / 2.0;

    // ── pilot (19 kHz ⇒ stereo) ──
    const pilot_bin = peakBinNear(psd_db, welch.hzBin(18_800, fs), welch.hzBin(19_200, fs));
    const pilot_floor = localFloorDb(psd_db, &welch, fs,19_000);
    const pilot_snr = psd_db[pilot_bin] - pilot_floor;
    const stereo = pilot_snr >= cfg.pilot_gate_db;

    // ── region-based slot detection over [24 kHz, Nyquist guard] ──
    // Group contiguous above-threshold bins (bridging a small gap so a DSB's
    // suppressed-carrier null doesn't split one slot in two); a region's centroid
    // is its center (= the suppressed carrier for DSB), its extent the bandwidth.
    const lo_bin = welch.hzBin(24_000, fs);
    const hi_bin = welch.hzBin(@min(120_000, nyq - 4_000), fs);
    const gfloor = percentileDb(psd_db, lo_bin, hi_bin, 0.30);
    const thr = gfloor + cfg.slot_gate_db;
    const gap_tol = welch.hzBin(1500, fs);
    const pilot_lo = welch.hzBin(18_000, fs);
    const pilot_hi = welch.hzBin(20_000, fs);
    const bin_hz = fs / @as(f64, @floatFromInt(welch.fft.n));

    var regions: [max_slots]Region = undefined;
    var nreg: usize = 0;
    var i = lo_bin;
    while (i <= hi_bin) {
        if (psd_db[i] <= thr) {
            i += 1;
            continue;
        }
        var end = i;
        var peak = i;
        var gap: usize = 0;
        var j = i;
        while (j <= hi_bin) : (j += 1) {
            if (psd_db[j] > thr) {
                end = j;
                gap = 0;
                if (psd_db[j] > psd_db[peak]) peak = j;
            } else {
                gap += 1;
                if (gap > gap_tol) break;
            }
        }
        const overlaps_pilot = !(end < pilot_lo or i > pilot_hi);
        const width_hz = @as(f64, @floatFromInt(end - i + 1)) * bin_hz;
        if (!overlaps_pilot and width_hz <= 25_000 and nreg < max_slots) {
            regions[nreg] = .{ .center_hz = powerCentroid(psd, i, end, &welch, fs), .bw_hz = width_hz, .peak_bin = peak };
            nreg += 1;
        }
        i = end + gap_tol + 1;
    }

    // probe the canonical 57/67/92 slots at a lower gate (catch weak ones)
    for (named_slots) |f| {
        var covered = false;
        for (regions[0..nreg]) |r| {
            if (@abs(r.center_hz - f) <= 3000) covered = true;
        }
        if (covered or nreg >= max_slots) continue;
        const b = peakBinNear(psd_db, welch.hzBin(f - 1500, fs), welch.hzBin(f + 1500, fs));
        const fl = localFloorDb(psd_db, &welch, fs, f);
        if (psd_db[b] - fl >= cfg.named_gate_db) {
            regions[nreg] = .{ .center_hz = f, .bw_hz = bandwidthHz(psd_db, b, fl, &welch, fs), .peak_bin = b };
            nreg += 1;
        }
    }

    // ── per-region reports ──
    var result = std.heap.ArenaAllocator.init(base);
    errdefer result.deinit();
    const ra = result.allocator();

    const mixed = try wa.alloc(C32, mpx.len);
    const zbuf = try wa.alloc(C32, mpx.len);
    const fbuf = try wa.alloc(f32, mpx.len);

    var reports: [max_slots]SlotReport = undefined;
    var nrep: usize = 0;
    for (regions[0..nreg]) |r| {
        const floor = localFloorDb(psd_db, &welch, fs, r.center_hz);
        const snr = psd_db[r.peak_bin] - floor;
        var metrics: SlotMetrics = .{};
        const mod = stdSlotMod(r.center_hz, classify(wa, mpx, psd, &welch, r.center_hz, r.bw_hz, snr, cfg, mixed, zbuf, fbuf, &metrics));
        if (!keepSlot(r.center_hz, snr, r.bw_hz, mod, cfg)) continue;
        reports[nrep] = .{ .center_hz = r.center_hz, .mod = mod, .bw_hz = r.bw_hz, .snr_db = snr, .guess = guessFor(r.center_hz, mod), .metrics = metrics };
        nrep += 1;
    }

    const slots = try ra.alloc(SlotReport, nrep);
    @memcpy(slots, reports[0..nrep]);
    std.mem.sort(SlotReport, slots, {}, lessByCenter);

    return .{ .stereo = stereo, .pilot_snr_db = pilot_snr, .slots = slots, .arena = result };
}

fn lessByCenter(_: void, a: SlotReport, b: SlotReport) bool {
    return a.center_hz < b.center_hz;
}

fn peakBinNear(psd_db: []const f64, lo: usize, hi: usize) usize {
    var best = lo;
    var i = lo;
    while (i <= hi and i < psd_db.len) : (i += 1) {
        if (psd_db[i] > psd_db[best]) best = i;
    }
    return best;
}

/// Median of the dB shoulders [center−6k,−3k] ∪ [center+3k,+6k] — a local noise
/// floor that tracks the rising FM-demod noise and excludes the slot itself.
fn localFloorDb(psd_db: []const f64, welch: *const Welch, fs: f64, center_hz: f64) f64 {
    var buf: [1024]f64 = undefined;
    var n: usize = 0;
    const spans = [_][2]f64{ .{ center_hz - 6000, center_hz - 3000 }, .{ center_hz + 3000, center_hz + 6000 } };
    for (spans) |s| {
        if (s[0] < 0) continue;
        var i = welch.hzBin(s[0], fs);
        const e = welch.hzBin(s[1], fs);
        while (i <= e and i < psd_db.len and n < buf.len) : (i += 1) {
            buf[n] = psd_db[i];
            n += 1;
        }
    }
    if (n == 0) return psd_db[0];
    std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
    return buf[n / 2];
}

/// Power-weighted center of a bin range (the suppressed carrier for a DSB pair).
fn powerCentroid(psd: []const f64, start: usize, end: usize, welch: *const Welch, fs: f64) f64 {
    var num: f64 = 0;
    var den: f64 = 0;
    var i = start;
    while (i <= end and i < psd.len) : (i += 1) {
        num += welch.binHz(i, fs) * psd[i];
        den += psd[i];
    }
    if (den <= 0) return welch.binHz(start, fs);
    return num / den;
}

/// p-quantile (0..1) of psd_db over [lo, hi] — a robust global noise floor.
fn percentileDb(psd_db: []const f64, lo: usize, hi: usize, p: f64) f64 {
    var buf: [4096]f64 = undefined;
    var n: usize = 0;
    var i = lo;
    while (i <= hi and i < psd_db.len and n < buf.len) : (i += 1) {
        buf[n] = psd_db[i];
        n += 1;
    }
    if (n == 0) return psd_db[0];
    std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
    return buf[@intFromFloat(p * @as(f64, @floatFromInt(n - 1)))];
}

/// Occupied bandwidth: walk out until the PSD drops to peak−3 dB or floor+3 dB.
fn bandwidthHz(psd_db: []const f64, k: usize, floor_db: f64, welch: *const Welch, fs: f64) f64 {
    const thresh = @max(psd_db[k] - 3.0, floor_db + 3.0);
    var lo = k;
    while (lo > 0 and psd_db[lo] > thresh) lo -= 1;
    var hi = k;
    while (hi + 1 < psd_db.len and psd_db[hi] > thresh) hi += 1;
    return @as(f64, @floatFromInt(hi - lo)) * fs / @as(f64, @floatFromInt(welch.fft.n));
}

fn classify(
    wa: std.mem.Allocator,
    mpx: []const f32,
    psd: []const f64,
    welch: *const Welch,
    center_hz: f64,
    bw_hz: f64,
    snr_db: f64,
    cfg: ScanConfig,
    mixed: []C32,
    zbuf: []C32,
    fbuf: []f32,
    metrics: *SlotMetrics,
) Modulation {
    if (snr_db < cfg.snr_gate_db) return .unknown;

    const fs = cfg.fs_mpx;
    // Extraction channel wide enough to capture the whole slot (SCA is up to ~8 kHz
    // wide; a too-narrow filter turns FM into spurious envelope variation).
    const cutoff = std.math.clamp(bw_hz * 0.7, 4000.0, 12000.0);
    const decim: usize = @max(1, @as(usize, @intFromFloat(fs / (4.0 * cutoff))));
    const fs_chan = fs / @as(f64, @floatFromInt(decim));

    var nco = Nco.init(center_hz, fs);
    _ = nco.mixReal(mpx, mixed);
    var f2 = fir.build(C32, wa, fs, cutoff, decim) catch return .unknown;
    const nz = f2.process(mixed[0..mpx.len], zbuf);

    if (nz < 1100) return .unknown; // below this the envelope-CV and audio-likeness stats are too noisy to trust
    const warm = @min(nz / 8, 512);
    const z = zbuf[warm..nz];

    // envelope coefficient of variation — large amplitude swing is DSB evidence.
    var sum: f64 = 0;
    for (z) |c| sum += c.mag();
    const mean_env = sum / @as(f64, @floatFromInt(z.len));
    if (mean_env <= 0) return .unknown;
    var var_env: f64 = 0;
    for (z) |c| {
        const d = c.mag() - mean_env;
        var_env += d * d;
    }
    const cv_env = @sqrt(var_env / @as(f64, @floatFromInt(z.len))) / mean_env;
    metrics.cv_env = cv_env;

    // FM-demodulate the slot; the output is the candidate audio program.
    var demod = FmDemod{};
    _ = demod.process(z, fbuf[0..z.len]);

    // B1 — audio-likeness: a real FM subcarrier carries audio, whose demod output
    // concentrates in the low band; FM-demodulated noise (or a DSB's phase flips)
    // has the rising "triangular" PSD (∝ f²), i.e. high-band-heavy. This is the FM
    // discriminant — it is deviation-independent, so low-deviation SCAs still pass.
    const audio_db = audioLikenessDb(wa, fbuf[0..z.len], fs_chan) catch return .unknown;
    metrics.audio_db = audio_db;

    // C — carrier presence: a suppressed-carrier DSB has a spectral null at center
    // while FM/carrier-AM have a center spike. center-bin power vs the slot shoulders.
    const carrier_db = carrierDb(psd, welch, fs, center_hz, bw_hz);
    metrics.carrier_db = carrier_db;

    const sym = sidebandSymmetry(psd, welch, fs, center_hz, bw_hz);
    metrics.sym = sym;

    // D — FM is the default for an audio subcarrier (US SCAs are FM ~always). Commit
    // to am_dsb only on positive DSB evidence: a broadband, symmetric slot with a
    // suppressed carrier and real envelope swing at real SNR (the 38 kHz stereo L−R).
    // Otherwise an audio-like slot is FM; everything else (noise, data, bare carrier)
    // is unknown.
    const am_wide = bw_hz >= cfg.am_min_bw_hz;
    if (am_wide and snr_db >= cfg.am_snr_db and carrier_db < cfg.carr_null_db and
        sym > cfg.sym_hi and cv_env > cfg.cv_hi) return .am_dsb;
    if (audio_db > cfg.aud_gate_db) return .fm;
    return .unknown;
}

/// B1 — ratio (dB) of mean low-band (0.3–3 kHz) to mean high-band (5–20 kHz) power
/// density in an FM-demod output. Audio concentrates low; demod noise rises with f,
/// so noise/DSB read low and a real audio program reads high.
fn audioLikenessDb(wa: std.mem.Allocator, x: []const f32, fs_chan: f64) !f64 {
    var dw = try Welch.init(wa, 1024);
    dw.run(x);
    var lo: f64 = 0;
    var lo_n: usize = 0;
    var k = dw.hzBin(300, fs_chan);
    const lo_hi = dw.hzBin(3000, fs_chan);
    while (k <= lo_hi and k < dw.psd.len) : (k += 1) {
        lo += dw.psd[k];
        lo_n += 1;
    }
    var hi: f64 = 0;
    var hi_n: usize = 0;
    var j = dw.hzBin(5000, fs_chan);
    const hi_hi = @min(dw.hzBin(20000, fs_chan), dw.psd.len - 1);
    while (j <= hi_hi) : (j += 1) {
        hi += dw.psd[j];
        hi_n += 1;
    }
    const lo_mean = lo / @as(f64, @floatFromInt(@max(1, lo_n)));
    const hi_mean = hi / @as(f64, @floatFromInt(@max(1, hi_n)));
    return 10.0 * std.math.log10((lo_mean + 1e-30) / (hi_mean + 1e-30));
}

/// C — center-bin power vs the slot shoulders (±0.3·bw), in dB. A suppressed-carrier
/// DSB reads strongly negative (null at center); FM/carrier-AM read ≥0 (carrier spike).
fn carrierDb(psd: []const f64, welch: *const Welch, fs: f64, center_hz: f64, bw_hz: f64) f64 {
    const cbin = welch.hzBin(center_hz, fs);
    const shoff = welch.hzBin(bw_hz * 0.3, fs);
    if (shoff == 0 or cbin >= psd.len) return 0;
    var sh: f64 = 0;
    var n: usize = 0;
    if (cbin >= shoff) {
        sh += psd[cbin - shoff];
        n += 1;
    }
    if (cbin + shoff < psd.len) {
        sh += psd[cbin + shoff];
        n += 1;
    }
    if (n == 0) return 0;
    return 10.0 * std.math.log10((psd[cbin] + 1e-30) / (sh / @as(f64, @floatFromInt(n)) + 1e-30));
}

fn sidebandSymmetry(psd: []const f64, welch: *const Welch, fs: f64, center_hz: f64, bw_hz: f64) f64 {
    const c = welch.hzBin(center_hz, fs);
    const half = welch.hzBin(bw_hz / 2.0, fs);
    var up: f64 = 0;
    var down: f64 = 0;
    var d: usize = 1;
    while (d <= half) : (d += 1) {
        if (c + d < psd.len) up += psd[c + d];
        if (c >= d) down += psd[c - d];
    }
    const mx = @max(up, down);
    if (mx <= 0) return 1.0;
    return @min(up, down) / mx;
}

fn near(a: f64, b: f64, tol: f64) bool {
    return @abs(a - b) <= tol;
}

fn isNamedSlot(center_hz: f64) bool {
    return near(center_hz, 38_000, 2000) or near(center_hz, 57_000, 1500) or
        near(center_hz, 67_000, 1500) or near(center_hz, 92_000, 1500);
}

/// Drop broadband junk the region detector latches onto (overload spurs / MPX splatter).
/// Standardized slots always pass; otherwise (A) skip noise-level regions and (D) skip
/// wide regions that classified as nothing — real wide signals classify (stereo ⇒ DSB).
fn keepSlot(center_hz: f64, snr_db: f64, bw_hz: f64, mod: Modulation, cfg: ScanConfig) bool {
    if (isNamedSlot(center_hz)) return true;
    if (snr_db < cfg.snr_gate_db) return false;
    if (mod == .unknown and bw_hz > cfg.wide_junk_hz) return false;
    return true;
}

/// Standardized MPX slots have a modulation fixed by the FM standard, so assert it rather
/// than trust the per-slot metric — a strong RDS data clock (~1.2 kHz biphase) lands in
/// the audio band and otherwise fools the audio-likeness test into reading `fm`.
fn stdSlotMod(center_hz: f64, classified: Modulation) Modulation {
    if (near(center_hz, 38_000, 2000)) return .am_dsb; // stereo L−R is DSB-SC
    if (near(center_hz, 57_000, 1500)) return .data; // RDS/RBDS is digital data, not audio
    return classified;
}

/// Best-effort slot identification — standardized MPX assignments (pilot-locked 38 kHz
/// stereo, 57 kHz RDS) and the modulation we measured. Deliberately does NOT guess at
/// content (e.g. whether an audio SCA is a reading service vs music) — we don't decode it.
fn guessFor(center_hz: f64, mod: Modulation) []const u8 {
    if (near(center_hz, 38_000, 2000)) return "stereo subcarrier (L−R)";
    if (near(center_hz, 57_000, 1500)) return "data subcarrier (RDS)";
    const sca = near(center_hz, 67_000, 1500) or near(center_hz, 92_000, 1500);
    return switch (mod) {
        .fm => if (sca) "audio SCA" else "FM subcarrier",
        .am_dsb => "DSB subcarrier",
        .data => "data subcarrier",
        .unknown => "unidentified",
    };
}

// ── tests ──
const testing = std.testing;

test "scan detects pilot + classifies an FM SCA and a DSB slot" {
    const fs = 256_000.0;
    const N = 1_000_000; // ~4 s
    const buf = try testing.allocator.alloc(f32, N);
    defer testing.allocator.free(buf);

    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    const pi = std.math.pi;
    var fm_ph: f64 = 0; // FM subcarrier phase accumulator
    var m_fm: f64 = 0; // bandlimited message (1-pole lowpass of white noise)
    for (buf, 0..) |*s, n| {
        const t = @as(f64, @floatFromInt(n)) / fs;
        m_fm = 0.92 * m_fm + 0.08 * rnd.floatNorm(f64); // ~3 kHz-wide message
        const pilot = 0.30 * @cos(2.0 * pi * 19_000.0 * t);
        fm_ph += 2.0 * pi * (67_000.0 + 14_000.0 * m_fm) / fs; // FM, ~3 kHz deviation
        const fm67 = 0.25 * @cos(fm_ph);
        // DSB-SC: a compact 3-tone message (0.8/1.6/2.4 kHz) ⇒ sidebands at 92k±{.8,1.6,2.4}k,
        // a clean ~4.8 kHz occupied band (>am_min_bw) with no long spectral tails to bias the floor.
        const m_dsb = @cos(2.0 * pi * 800.0 * t) + @cos(2.0 * pi * 1600.0 * t) + @cos(2.0 * pi * 2400.0 * t);
        const dsb92 = 1.2 * m_dsb * @cos(2.0 * pi * 92_000.0 * t);
        s.* = @floatCast(pilot + fm67 + dsb92 + 0.012 * rnd.floatNorm(f64));
    }

    var res = try scan(testing.allocator, buf, .{});
    defer res.deinit();

    try testing.expect(res.stereo);
    var found_fm67 = false;
    var found_dsb92 = false;
    for (res.slots) |sl| {
        if (near(sl.center_hz, 67_000, 1500) and sl.mod == .fm) found_fm67 = true;
        if (near(sl.center_hz, 92_000, 1500) and sl.mod == .am_dsb) found_dsb92 = true;
    }
    try testing.expect(found_fm67);
    try testing.expect(found_dsb92);
}

test "narrowband low-deviation FM classifies as fm (carrier present + audio-like)" {
    // A weak (~+10 dB) low-deviation FM slot ~2.5 kHz wide carrying audio (low-pass
    // noise). Noise inflates cv_env here, so envelope swing alone would mis-call it
    // am_dsb; classification must lean on a present carrier (not a null) and an
    // audio-like demod output ⇒ fm.
    const fs = 256_000.0;
    const N = 1_000_000;
    const buf = try testing.allocator.alloc(f32, N);
    defer testing.allocator.free(buf);
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    const pi = std.math.pi;
    var fm_ph: f64 = 0;
    var msg: f64 = 0;
    for (buf, 0..) |*s, n| {
        const t = @as(f64, @floatFromInt(n)) / fs;
        msg = 0.975 * msg + 0.222 * rnd.floatNorm(f64); // ~1 kHz message
        const pilot = 0.30 * @cos(2.0 * pi * 19_000.0 * t);
        fm_ph += 2.0 * pi * (67_000.0 + 1100.0 * msg) / fs; // low deviation ⇒ ~2.5 kHz occupied
        const fm67 = 0.10 * @cos(fm_ph);
        s.* = @floatCast(pilot + fm67 + 0.18 * rnd.floatNorm(f64));
    }

    var res = try scan(testing.allocator, buf, .{});
    defer res.deinit();
    var found = false;
    for (res.slots) |sl| {
        if (near(sl.center_hz, 67_000, 1500)) {
            try testing.expect(sl.mod == .fm);
            found = true;
        }
    }
    try testing.expect(found);
}

test "standardized slots assert their modulation regardless of the metric" {
    // 57 kHz RDS must never read fm (a strong data clock fools the audio test); 38 kHz
    // stereo L−R is DSB-SC; audio-band slots keep whatever classify decided.
    try testing.expectEqual(Modulation.data, stdSlotMod(57_000, .fm));
    try testing.expectEqual(Modulation.data, stdSlotMod(57_200, .unknown));
    try testing.expectEqual(Modulation.am_dsb, stdSlotMod(38_000, .unknown));
    try testing.expectEqual(Modulation.fm, stdSlotMod(67_000, .fm));
    try testing.expectEqual(Modulation.unknown, stdSlotMod(67_000, .unknown));
}

test "junk filter drops broadband spurs, keeps real and standardized slots" {
    const cfg = ScanConfig{};
    // standardized slots always pass — even the wide 38 kHz stereo and weak named slots
    try testing.expect(keepSlot(38_000, 1, 30_000, .am_dsb, cfg));
    try testing.expect(keepSlot(67_000, 2, 6_000, .fm, cfg));
    // A: non-standard noise-level region (the 101 kHz +1 dB spur)
    try testing.expect(!keepSlot(101_000, 1, 17_400, .unknown, cfg));
    // D: non-standard wide unknown even at decent SNR (the 32 kHz +9 dB / 14.5 kHz spur)
    try testing.expect(!keepSlot(32_000, 9, 14_500, .unknown, cfg));
    // a real non-standard narrow signal that classified is kept
    try testing.expect(keepSlot(80_000, 10, 6_000, .fm, cfg));
}

test "scan finds no slots in plain mono+pilot (no false positives)" {
    const fs = 256_000.0;
    const N = 600_000;
    const buf = try testing.allocator.alloc(f32, N);
    defer testing.allocator.free(buf);
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    for (buf, 0..) |*s, n| {
        const t = @as(f64, @floatFromInt(n)) / fs;
        const mono = 0.5 * @cos(2.0 * std.math.pi * 3000.0 * t) + 0.3 * @cos(2.0 * std.math.pi * 8000.0 * t);
        const pilot = 0.3 * @cos(2.0 * std.math.pi * 19_000.0 * t);
        s.* = @floatCast(mono + pilot + 0.02 * rnd.floatNorm(f64));
    }
    var res = try scan(testing.allocator, buf, .{});
    defer res.deinit();
    try testing.expect(res.stereo);
    try testing.expectEqual(@as(usize, 0), res.slots.len);
}
