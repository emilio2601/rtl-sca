const std = @import("std");
const cli = @import("cli.zig");
const complex = @import("complex.zig");
const C32 = complex.C32;
const fir = @import("firdecim.zig");
const Deemph = @import("deemph.zig").Deemph;
const Subcarrier = @import("subcarrier.zig").Subcarrier;
const rateplan = @import("rateplan.zig");
const Resampler = @import("resampler.zig").Resampler;
const frontend_mod = @import("frontend.zig");
const Frontend = frontend_mod.Frontend;
const source_mod = @import("source.zig");
const Source = source_mod.Source;
const Format = source_mod.Format;
const sink_mod = @import("sink.zig");
const Sink = sink_mod.Sink;
const Running = @import("ring.zig").Running;

const READ_BYTES: usize = 1 << 18; // 256 KiB raw IQ per read

pub const InitError = error{SubcarrierAboveNyquist} || frontend_mod.Error || rateplan.Error;

/// The full offline `rec` chain. Owns an arena holding every DSP buffer, sized
/// once at init; the per-sample path never allocates.
pub const Pipeline = struct {
    arena: std.heap.ArenaAllocator,

    frontend: Frontend,
    sub: Subcarrier,
    deemph: Deemph,
    resampler: Resampler,
    plan: rateplan.RatePlan,
    audio_gain: f32,
    fs_audio: u32,

    // buffers
    reader_buf: []u8,
    block: []u8,
    iq: []C32,
    mpx: []f32,
    chan: []f32, // subcarrier output at fs_chan, pre-resample
    audio: []f32,

    pub fn init(self: *Pipeline, base: std.mem.Allocator, opts: cli.Options) InitError!void {
        self.arena = std.heap.ArenaAllocator.init(base);
        errdefer self.arena.deinit(); // a later guard may reject after we allocate
        const a = self.arena.allocator();
        const max_iq = READ_BYTES / 2;

        // One planner owns the whole rate chain (SPEC §4 rate plan).
        // null reaches here only for `rec` (play resolves the device rate first);
        // file output defaults to 48 kHz.
        const fs_audio_target = opts.audio_rate_hz orelse 48_000;
        const plan = try rateplan.plan(opts.rate_hz, fs_audio_target, opts.bw_hz);
        self.frontend = try Frontend.init(a, plan, max_iq);
        const fs_mpx = plan.fs_mpx;

        const slot_edge: f64 = @floatFromInt(opts.sub_hz + opts.bw_hz / 2);
        if (slot_edge >= fs_mpx * 0.43) return error.SubcarrierAboveNyquist;

        // ── stages ──
        const max_mpx = self.frontend.outCap(max_iq);
        const max_chan = max_mpx / plan.d2 + 2;
        self.sub = try Subcarrier.init(a, opts.sub_hz, opts.bw_hz, fs_mpx, plan.d2, max_mpx, opts.mod);
        // De-emphasis runs at fs_chan; the resampler then converts to fs_audio,
        // preserving the analog corner (SPEC §5).
        self.deemph = Deemph.init(opts.deemph_us, plan.fs_chan);
        const cutoff_rs = 0.45 * @min(plan.fs_chan, @as(f64, @floatFromInt(plan.fs_audio)));
        self.resampler = try Resampler.build(a, plan.fs_chan, plan.resamp.l, plan.resamp.m, cutoff_rs);
        // atan2 emits radians, not ±1; map the expected deviation toward full scale.
        // The main MPX baseband is quieter than a demod'd SCA, so it needs more gain.
        self.audio_gain = if (opts.sub_hz == 0) 3.0 else 1.0;
        self.plan = plan;
        self.fs_audio = plan.fs_audio;

        // ── buffers ──
        self.reader_buf = try a.alloc(u8, 1 << 16);
        self.block = try a.alloc(u8, READ_BYTES);
        self.iq = try a.alloc(C32, max_iq);
        self.mpx = try a.alloc(f32, max_mpx);
        self.chan = try a.alloc(f32, max_chan);
        self.audio = try a.alloc(f32, max_chan * plan.resamp.l / plan.resamp.m + 2);
    }

    pub fn deinit(self: *Pipeline) void {
        self.arena.deinit();
    }

    /// Run one IQ block through demod→decimate→subcarrier→de-emph. The audio
    /// lands in self.audio[0..return]; gain is NOT applied (callers that play it
    /// out apply gain, tests read it raw).
    fn processIq(self: *Pipeline, iq: []const C32) usize {
        const n_mpx = self.frontend.process(iq, self.mpx);
        const n_chan = self.sub.process(self.mpx[0..n_mpx], self.chan);
        self.deemph.process(self.chan[0..n_chan]);
        return self.resampler.process(self.chan[0..n_chan], self.audio);
    }

    fn unpack(self: *Pipeline, fmt: Format, bytes: []const u8) usize {
        return switch (fmt) {
            .cu8 => complex.unpackCu8(bytes, self.iq),
            .cs16 => complex.unpackCs16(bytes, self.iq),
        };
    }

    /// Optional runtime diagnostics for `run` (driven by `-v`/`-vv`). Logged to
    /// `w` (stderr); `periodic` adds an in-flight line roughly every 2 s of stream.
    pub const Debug = struct {
        w: *std.Io.Writer,
        periodic: bool,
    };

    /// Pump `source` through the DSP into `sink` until the source ends (file EOF)
    /// or `running` is cleared (SIGINT for live sources), then finalize the sink.
    pub fn run(self: *Pipeline, io: std.Io, source: Source, sink: Sink, running: *Running, dbg: ?Debug) !void {
        const fmt = source.format();
        var busy_ns: u64 = 0; // wall time spent in the DSP (vs. blocked on I/O)
        var in_samples: u64 = 0;
        const report_every: u64 = @intFromFloat(2.0 * self.plan.fs_iq);
        var report_at = report_every;

        while (running.load(.monotonic)) {
            const nb = try source.read(self.block);
            if (nb == 0) break; // EOF (file source)
            const niq = self.unpack(fmt, self.block[0..nb]);
            const t0 = std.Io.Clock.awake.now(io);
            const na = self.processIq(self.iq[0..niq]);
            for (self.audio[0..na]) |*s| s.* *= self.audio_gain;
            busy_ns += @intCast(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
            try sink.writeAudio(self.audio[0..na]);

            in_samples += niq;
            if (dbg) |d| if (d.periodic and in_samples >= report_at) {
                try self.logStats(d.w, source, sink, in_samples, busy_ns);
                report_at += report_every;
            };
        }
        try sink.finish(io);
        if (dbg) |d| try self.logStats(d.w, source, sink, in_samples, busy_ns);
    }

    /// One-line health snapshot: how much faster than real time the DSP ran, plus
    /// the cross-thread loss counters (USB ring drops, audio underruns) that a
    /// "looks fine but sounds choppy" bug otherwise hides.
    fn logStats(self: *Pipeline, w: *std.Io.Writer, source: Source, sink: Sink, in_samples: u64, busy_ns: u64) !void {
        const stream_s = @as(f64, @floatFromInt(in_samples)) / self.plan.fs_iq;
        const busy_s = @as(f64, @floatFromInt(busy_ns)) / 1e9;
        const rt = if (busy_s > 0) stream_s / busy_s else 0;
        try w.print("stats   : stream {d:.1}s | dsp {d:.1}x realtime", .{ stream_s, rt });
        if (source.stats()) |s| {
            const drop_pct = if (s.rx_bytes > 0)
                100.0 * @as(f64, @floatFromInt(s.dropped_bytes)) / @as(f64, @floatFromInt(s.rx_bytes))
            else
                0.0;
            const hw_pct = 100 * s.ring_high_water / s.ring_capacity;
            try w.print(" | usb {d:.1} MB, drop {d} ({d:.2}%), ring peak {d}%", .{
                @as(f64, @floatFromInt(s.rx_bytes)) / 1e6, s.dropped_bytes, drop_pct, hw_pct,
            });
        }
        if (sink.ringFill()) |rf| {
            try w.print(" | aud ring {d}%, underruns {d}", .{ 100 * rf.used / rf.capacity, sink.underruns() });
        }
        try w.writeAll("\n");
        try w.flush();
    }
};

// ── tests ──
const testing = std.testing;
const tu = @import("testutil.zig");

fn testOpts(sub_hz: u32, bw_hz: u32) cli.Options {
    return .{ .command = .rec, .input = .{ .file = "x.cu8" }, .sub_hz = sub_hz, .bw_hz = bw_hz, .deemph_us = 0, .rate_hz = 1_024_000, .audio_rate_hz = 16_000 };
}

test "non-divisible rate now resamples instead of being rejected" {
    var p: Pipeline = undefined;
    var o = testOpts(67000, 8000);
    o.rate_hz = 1_000_000; // 250k → 16k is 128/125, handled by the resampler
    try p.init(testing.allocator, o);
    defer p.deinit();
    try testing.expectEqual(@as(u32, 16_000), p.fs_audio);
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

test "integration: 48 kHz output recovers the SCA tone through the resampler" {
    var p: Pipeline = undefined;
    var o = testOpts(67000, 8000);
    o.audio_rate_hz = 48_000; // 256k→fs_chan→48k via a 15/16 resampler
    try p.init(testing.allocator, o);
    defer p.deinit();
    try testing.expectEqual(@as(u32, 48_000), p.fs_audio);

    const n = READ_BYTES / 2;
    const iq = try testing.allocator.alloc(C32, n);
    defer testing.allocator.free(iq);
    const fs = 1_024_000.0;
    var ph: f64 = 0;
    for (iq, 0..) |*c, k| {
        const t = @as(f64, @floatFromInt(k)) / fs;
        const pilot = 0.1 * @cos(2.0 * std.math.pi * 19000.0 * t);
        const sca = 0.3 * @cos(2.0 * std.math.pi * 67000.0 * t + 3.0 * @sin(2.0 * std.math.pi * 1000.0 * t));
        ph += 2.0 * std.math.pi * (75000.0 * (pilot + sca)) / fs;
        c.* = .{ .re = @floatCast(@cos(ph)), .im = @floatCast(@sin(ph)) };
    }

    const na = p.processIq(iq);
    const dom = tu.toneDominance(p.audio[768..na], 1000, 2500, 48000);
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
