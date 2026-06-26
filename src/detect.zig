const std = @import("std");
const C32 = @import("complex.zig").C32;
const Welch = @import("fft.zig").Welch;
const Nco = @import("nco.zig").Nco;
const fir = @import("firdecim.zig");
const FmDemod = @import("fmdemod.zig").FmDemod;

pub const Modulation = enum { fm, am_dsb, unknown };

pub const SlotReport = struct {
    center_hz: f64,
    mod: Modulation,
    bw_hz: f64,
    snr_db: f64,
    guess: []const u8,

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
    cv_hi: f64 = 0.35, // envelope coefficient-of-variation: above ⇒ AM/DSB
    cv_lo: f64 = 0.30, // below ⇒ constant envelope ⇒ FM
    dev_hi_hz: f64 = 1500, // freq-deviation std confirming FM
    sym_hi: f64 = 0.6, // sideband symmetry confirming DSB
    am_snr_db: f64 = 8.0, // AM/DSB is easily faked by noise — demand real SNR
    min_bw_hz: f64 = 2000, // a real modulated slot, not a bare carrier/data spike
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
        const mod = classify(wa, mpx, psd, &welch, r.center_hz, r.bw_hz, snr, cfg, mixed, zbuf, fbuf);
        reports[nrep] = .{ .center_hz = r.center_hz, .mod = mod, .bw_hz = r.bw_hz, .snr_db = snr, .guess = guessFor(r.center_hz, mod) };
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

    if (nz < 1100) return .unknown; // too little data
    const warm = @min(nz / 8, 512);
    const z = zbuf[warm..nz];

    // envelope coefficient of variation
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

    // instantaneous-frequency deviation, gated to high-envelope samples so DSB
    // zero-crossing phase flips don't masquerade as FM deviation.
    var demod = FmDemod{};
    _ = demod.process(z, fbuf[0..z.len]);
    const gate = 0.2 * mean_env;
    var fsum: f64 = 0;
    var fcount: usize = 0;
    for (z, 0..) |c, j| {
        if (c.mag() >= gate) {
            fsum += fbuf[j];
            fcount += 1;
        }
    }
    if (fcount < 100) return .unknown;
    const fmean = fsum / @as(f64, @floatFromInt(fcount));
    var fvar: f64 = 0;
    for (z, 0..) |c, j| {
        if (c.mag() >= gate) {
            const d = fbuf[j] - fmean;
            fvar += d * d;
        }
    }
    const dev_rad = @sqrt(fvar / @as(f64, @floatFromInt(fcount)));
    const dev_hz = dev_rad * fs_chan / (2.0 * std.math.pi);

    const sym = sidebandSymmetry(psd, welch, fs, center_hz, bw_hz);

    // Only commit to a modulation for a slot with real modulated bandwidth — a
    // bare carrier or data spike, or a noise-swamped slot, stays `unknown`.
    // cv_env is the primary discriminant (constant envelope ⇒ FM, high amplitude
    // variation ⇒ AM/DSB); dev confirms FM, symmetry + SNR confirm DSB (which noise
    // otherwise mimics).
    const wide = bw_hz >= cfg.min_bw_hz;
    if (wide and cv_env < cfg.cv_lo and dev_hz > cfg.dev_hi_hz) return .fm;
    if (wide and snr_db >= cfg.am_snr_db and cv_env > cfg.cv_hi and sym > cfg.sym_hi) return .am_dsb;
    return .unknown;
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

fn guessFor(center_hz: f64, mod: Modulation) []const u8 {
    if (near(center_hz, 38_000, 2000)) return "stereo subcarrier (L−R)";
    if (near(center_hz, 57_000, 1500)) return "data (RDS)";
    const sca = near(center_hz, 67_000, 1500) or near(center_hz, 92_000, 1500);
    return switch (mod) {
        .fm => if (sca) "audio SCA (reading service)" else "FM subcarrier",
        .am_dsb => "AM/DSB — possible bleedthrough",
        .unknown => "weak — unidentified",
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
    var m_dsb: f64 = 0;
    for (buf, 0..) |*s, n| {
        const t = @as(f64, @floatFromInt(n)) / fs;
        m_fm = 0.92 * m_fm + 0.08 * rnd.floatNorm(f64); // ~3 kHz-wide message
        m_dsb = 0.96 * m_dsb + 0.04 * rnd.floatNorm(f64); // narrower ⇒ concentrated DSB
        const pilot = 0.30 * @cos(2.0 * pi * 19_000.0 * t);
        fm_ph += 2.0 * pi * (67_000.0 + 14_000.0 * m_fm) / fs; // FM, ~3 kHz deviation
        const fm67 = 0.25 * @cos(fm_ph);
        const dsb92 = 4.0 * m_dsb * @cos(2.0 * pi * 92_000.0 * t); // DSB-SC, broadband
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
