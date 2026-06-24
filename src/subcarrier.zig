const std = @import("std");
const C32 = @import("complex.zig").C32;
const FmDemod = @import("fmdemod.zig").FmDemod;
const fir = @import("firdecim.zig");
const Nco = @import("nco.zig").Nco;

const FirR = fir.FirDecim(f32);
const FirC = fir.FirDecim(C32);

pub const Error = fir.BuildError;

/// Stage 2 of the chain: take the 256 ksps MPX down to 16 ksps audio. The SCA
/// branch mixes the slot to DC, filters complex, and FM-demods it; the main
/// branch (sub_hz==0) filters+decimates the real MPX baseband — which already is
/// the mono program — with no NCO and no second demod.
pub const Subcarrier = union(enum) {
    sca: Sca,
    main: Main,

    const Sca = struct {
        nco: Nco,
        fir2: FirC,
        demod: FmDemod,
        mixed: []C32,
        chan: []C32,
    };
    const Main = struct {
        fir2a: FirR,
        fir2b: FirR,
        mid: []f32,
    };

    pub fn init(
        a: std.mem.Allocator,
        sub_hz: u32,
        bw_hz: u32,
        fs_mpx: f64,
        d2: usize,
        max_in: usize,
    ) Error!Subcarrier {
        const cutoff: f64 = @as(f64, @floatFromInt(bw_hz)) / 2.0;
        if (cutoff <= 0) return error.BadBandwidth;

        if (sub_hz == 0) {
            // Main channel: split D2 into two near-equal substages so the sharp
            // ~bw/2 cut at the 8k fold doesn't explode the tap count.
            const f = factorPair(d2);
            const fs_mid = fs_mpx / @as(f64, @floatFromInt(f.a));
            const fir2a = try fir.build(f32, a, fs_mpx, cutoff, f.a);
            const fir2b = try fir.build(f32, a, fs_mid, cutoff, f.b);
            const mid = try a.alloc(f32, max_in / f.a + 2);
            return .{ .main = .{ .fir2a = fir2a, .fir2b = fir2b, .mid = mid } };
        }

        const fir2 = try fir.build(C32, a, fs_mpx, cutoff, d2);
        const mixed = try a.alloc(C32, max_in);
        const chan = try a.alloc(C32, max_in / d2 + 2);
        return .{ .sca = .{
            .nco = Nco.init(@floatFromInt(sub_hz), fs_mpx),
            .fir2 = fir2,
            .demod = .{},
            .mixed = mixed,
            .chan = chan,
        } };
    }

    /// Consume a 256 ksps MPX block, append 16 ksps audio to `audio`, return count.
    pub fn process(self: *Subcarrier, mpx: []const f32, audio: []f32) usize {
        switch (self.*) {
            .sca => |*s| {
                const nm = s.nco.mixReal(mpx, s.mixed);
                const nc = s.fir2.process(s.mixed[0..nm], s.chan);
                return s.demod.process(s.chan[0..nc], audio);
            },
            .main => |*m| {
                const na = m.fir2a.process(mpx, m.mid);
                return m.fir2b.process(m.mid[0..na], audio);
            },
        }
    }
};

const FactorPair = struct { a: usize, b: usize };

/// Split `d` into a×b with a as close to sqrt(d) as possible (a ≤ b).
fn factorPair(d: usize) FactorPair {
    var a: usize = std.math.sqrt(d);
    while (a > 1 and d % a != 0) a -= 1;
    return .{ .a = a, .b = d / a };
}

const testing = std.testing;
const tu = @import("testutil.zig");

test "factorPair" {
    try testing.expectEqual(FactorPair{ .a = 4, .b = 4 }, factorPair(16));
    try testing.expectEqual(FactorPair{ .a = 2, .b = 4 }, factorPair(8));
    try testing.expectEqual(FactorPair{ .a = 1, .b = 7 }, factorPair(7)); // prime
}

test "SCA branch recovers a 1 kHz tone from a 67 kHz FM subcarrier" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = 32768;
    var mpx: [n]f32 = undefined;
    tu.fmTone(&mpx, 67000, 1000, 3000, 256000); // 67k carrier, 1k tone, 3k dev

    var sub = try Subcarrier.init(arena.allocator(), 67000, 8000, 256000, 16, n);
    var audio: [n / 16 + 2]f32 = undefined;
    const na = sub.process(&mpx, &audio);

    // skip filter warm-up, then confirm the 1 kHz tone dominates
    const dom = tu.toneDominance(audio[256..na], 1000, 2500, 16000);
    try testing.expect(dom > 50);
}

test "main branch recovers a baseband tone with no NCO/second demod" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const n = 32768;
    var mpx: [n]f32 = undefined;
    for (&mpx, 0..) |*s, i| {
        s.* = @floatCast(@cos(2.0 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / 256000.0));
    }

    var sub = try Subcarrier.init(arena.allocator(), 0, 15000, 256000, 16, n);
    var audio: [n / 16 + 2]f32 = undefined;
    const na = sub.process(&mpx, &audio);

    const dom = tu.toneDominance(audio[256..na], 1000, 2500, 16000);
    try testing.expect(dom > 50);
}
