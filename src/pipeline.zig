const std = @import("std");
const cli = @import("cli.zig");
const complex = @import("complex.zig");
const C32 = complex.C32;
const fir = @import("firdecim.zig");
const Deemph = @import("deemph.zig").Deemph;
const Subcarrier = @import("subcarrier.zig").Subcarrier;
const frontend_mod = @import("frontend.zig");
const Frontend = frontend_mod.Frontend;
const source_mod = @import("source.zig");
const Source = source_mod.Source;
const Format = source_mod.Format;
const sink_mod = @import("sink.zig");
const Sink = sink_mod.Sink;
const Running = @import("ring.zig").Running;

const READ_BYTES: usize = 1 << 18; // 256 KiB raw IQ per read
const AUDIO_RATE: u32 = 16_000; // §12

pub const InitError = error{SubcarrierAboveNyquist} || frontend_mod.Error;

/// The full offline `rec` chain. Owns an arena holding every DSP buffer, sized
/// once at init; the per-sample path never allocates.
pub const Pipeline = struct {
    arena: std.heap.ArenaAllocator,

    frontend: Frontend,
    sub: Subcarrier,
    deemph: Deemph,
    audio_gain: f32,
    fs_audio: u32,

    // buffers
    reader_buf: []u8,
    block: []u8,
    iq: []C32,
    mpx256: []f32,
    audio: []f32,

    pub fn init(self: *Pipeline, base: std.mem.Allocator, opts: cli.Options) InitError!void {
        self.arena = std.heap.ArenaAllocator.init(base);
        errdefer self.arena.deinit(); // a later guard may reject after we allocate
        const a = self.arena.allocator();
        const max_iq = READ_BYTES / 2;

        // Front-end derives d1/fs_mpx and owns IQ→MPX (SPEC §4 rate plan).
        self.frontend = try Frontend.init(a, opts.rate_hz, max_iq);
        const fs_mpx = self.frontend.fs_mpx;
        const d1 = self.frontend.d1;

        const slot_edge: f64 = @floatFromInt(opts.sub_hz + opts.bw_hz / 2);
        if (slot_edge >= fs_mpx * 0.43) return error.SubcarrierAboveNyquist;

        const fs_mpx_u: u32 = @intFromFloat(fs_mpx);
        if (fs_mpx_u % AUDIO_RATE != 0) return error.RateNotDivisible;
        const d2: usize = fs_mpx_u / AUDIO_RATE;

        // ── stages ──
        const max_mpx256 = max_iq / d1 + 2;
        self.sub = try Subcarrier.init(a, opts.sub_hz, opts.bw_hz, fs_mpx, d2, max_mpx256);
        self.deemph = Deemph.init(opts.deemph_us, AUDIO_RATE);
        // atan2 emits radians, not ±1; map the expected deviation toward full scale.
        // Tuned during bring-up; the main MPX baseband is quieter than a demod'd SCA.
        self.audio_gain = if (opts.sub_hz == 0) 3.0 else 1.0;
        self.fs_audio = AUDIO_RATE;

        // ── buffers ──
        self.reader_buf = try a.alloc(u8, 1 << 16);
        self.block = try a.alloc(u8, READ_BYTES);
        self.iq = try a.alloc(C32, max_iq);
        self.mpx256 = try a.alloc(f32, max_mpx256);
        self.audio = try a.alloc(f32, max_iq / (d1 * d2) + 4);
    }

    pub fn deinit(self: *Pipeline) void {
        self.arena.deinit();
    }

    /// Run one IQ block through demod→decimate→subcarrier→de-emph. The audio
    /// lands in self.audio[0..return]; gain is NOT applied (callers that play it
    /// out apply gain, tests read it raw).
    fn processIq(self: *Pipeline, iq: []const C32) usize {
        const n256 = self.frontend.process(iq, self.mpx256);
        const na = self.sub.process(self.mpx256[0..n256], self.audio);
        self.deemph.process(self.audio[0..na]);
        return na;
    }

    fn unpack(self: *Pipeline, fmt: Format, bytes: []const u8) usize {
        return switch (fmt) {
            .cu8 => complex.unpackCu8(bytes, self.iq),
            .cs16 => complex.unpackCs16(bytes, self.iq),
        };
    }

    /// Pump `source` through the DSP into `sink` until the source ends (file EOF)
    /// or `running` is cleared (SIGINT for live sources), then finalize the sink.
    pub fn run(self: *Pipeline, io: std.Io, source: Source, sink: Sink, running: *Running) !void {
        const fmt = source.format();
        while (running.load(.monotonic)) {
            const nb = try source.read(self.block);
            if (nb == 0) break; // EOF (file source)
            const niq = self.unpack(fmt, self.block[0..nb]);
            const na = self.processIq(self.iq[0..niq]);
            for (self.audio[0..na]) |*s| s.* *= self.audio_gain;
            try sink.writeAudio(self.audio[0..na]);
        }
        try sink.finish(io);
    }
};

// ── tests ──
const testing = std.testing;
const tu = @import("testutil.zig");

fn testOpts(sub_hz: u32, bw_hz: u32) cli.Options {
    return .{ .command = .rec, .input = .{ .file = "x.cu8" }, .sub_hz = sub_hz, .bw_hz = bw_hz, .deemph_us = 0, .rate_hz = 1_024_000 };
}

test "rate derivation rejects non-divisible rates" {
    var p: Pipeline = undefined;
    var o = testOpts(67000, 8000);
    o.rate_hz = 1_000_000; // 250k/16000 not integer
    try testing.expectError(error.RateNotDivisible, p.init(testing.allocator, o));
}

test "integration: full chain recovers a 1 kHz tone through a 67 kHz SCA" {
    var p: Pipeline = undefined;
    try p.init(testing.allocator, testOpts(67000, 8000));
    defer p.deinit();

    // synthetic IQ: an FM carrier modulated by an MPX = 19k pilot + a 67k
    // subcarrier that is itself FM-modulated by a 1 kHz tone.
    const n = READ_BYTES / 2;
    const iq = try testing.allocator.alloc(C32, n);
    defer testing.allocator.free(iq);
    const fs = 1_024_000.0;
    var ph: f64 = 0;
    for (iq, 0..) |*c, k| {
        const t = @as(f64, @floatFromInt(k)) / fs;
        const pilot = 0.1 * @cos(2.0 * std.math.pi * 19000.0 * t);
        const sca = 0.3 * @cos(2.0 * std.math.pi * 67000.0 * t + 3.0 * @sin(2.0 * std.math.pi * 1000.0 * t));
        const mpx = pilot + sca;
        ph += 2.0 * std.math.pi * (75000.0 * mpx) / fs; // ~FM, ≤30k dev
        c.* = .{ .re = @floatCast(@cos(ph)), .im = @floatCast(@sin(ph)) };
    }

    const na = p.processIq(iq);
    const dom = tu.toneDominance(p.audio[256..na], 1000, 2500, 16000);
    try testing.expect(dom > 30);
}

test "integration: main channel recovers a baseband tone" {
    var p: Pipeline = undefined;
    try p.init(testing.allocator, testOpts(0, 15000));
    defer p.deinit();

    const n = READ_BYTES / 2;
    const iq = try testing.allocator.alloc(C32, n);
    defer testing.allocator.free(iq);
    const fs = 1_024_000.0;
    var ph: f64 = 0;
    for (iq, 0..) |*c, k| {
        const t = @as(f64, @floatFromInt(k)) / fs;
        const mpx = 0.5 * @cos(2.0 * std.math.pi * 1000.0 * t); // mono tone in 0–15k
        ph += 2.0 * std.math.pi * (75000.0 * mpx) / fs;
        c.* = .{ .re = @floatCast(@cos(ph)), .im = @floatCast(@sin(ph)) };
    }

    const na = p.processIq(iq);
    const dom = tu.toneDominance(p.audio[256..na], 1000, 2500, 16000);
    try testing.expect(dom > 30);
}
