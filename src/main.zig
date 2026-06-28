const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const pipeline = @import("pipeline.zig");
const ring_mod = @import("ring.zig");
const Running = ring_mod.Running;
const source_mod = @import("source.zig");
const sink_mod = @import("sink.zig");
const frontend_mod = @import("frontend.zig");
const rateplan = @import("rateplan.zig");
const detect = @import("detect.zig");
const complex = @import("complex.zig");

const usage =
    \\rtl-sca — FM SCA subcarrier decoder
    \\
    \\usage:
    \\  rtl-sca <command> <input> [flags]
    \\
    \\commands:
    \\  scan   survey the MPX and report subcarrier slots
    \\  play   demodulate a subcarrier and play it live
    \\  rec    demodulate a subcarrier and write a WAV
    \\
    \\input (positional, required):
    \\  a frequency (89.9M, 89900000)  -> tune a radio
    \\  a file path  (capture.cu8)     -> read recorded IQ
    \\
    \\flags:
    \\  --source PATH     explicit file source (overrides the positional)
    \\  --rtl-tcp H:PORT  use an rtl_tcp network server (tune <input> over it)
    \\  --sub HZ          subcarrier center: 67k, 92k, ...; 0 = main channel (default 67k)
    \\  --bw HZ           bandwidth to recover: audio for --sub 0, slot for a
    \\                    subcarrier (e.g. 15k main, 8k SCA; default 8k)
    \\  --mod MODE        fm | am-env | am-coherent (default fm)
    \\  --deemph TAU      de-emphasis time constant, e.g. 120us; off=none
    \\                    (default 150us SCA; 75us US, 50us EU main channel)
    \\  --rate HZ         RTL sample rate (default 1.024M)
    \\  --audio-rate HZ   audio output rate (default 48k; e.g. 16k for small files)
    \\  --gain DB         tuner gain (default auto)
    \\  --device N        USB dongle index (default 0)
    \\  --ppm N           crystal frequency correction, ppm (default 0)
    \\  -o FILE           output WAV path (rec)
    \\  -v                verbose: show per-slot classifier metrics (scan)
    \\
    \\examples:
    \\  rtl-sca scan 89.9M
    \\  rtl-sca play 89.9M --sub 67k --mod fm --deemph 150us
    \\  rtl-sca rec  89.9M --sub 67k -o gatewave.wav
    \\  rtl-sca play capture.cu8 --sub 86k --mod am-env --deemph off
    \\  rtl-sca play 89.9M --sub 0 --bw 15k --deemph 75us   # main program audio
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var buf: [2048]u8 = undefined;
    var fw: Io.File.Writer = .init(.stderr(), init.io, &buf);
    const w = &fw.interface;
    defer w.flush() catch {};

    const opts = cli.parse(args) catch |err| {
        try w.print("rtl-sca: {s}\n\n", .{cli.errorText(err)});
        try w.writeAll(usage);
        try w.flush();
        std.process.exit(2);
    };

    switch (opts.command) {
        .rec => try runRec(init, w, opts),
        .play => try runPlay(init, w, opts),
        .scan => try runScan(init, w, opts),
    }
}

fn runRec(init: std.process.Init, w: *Io.Writer, opts: cli.Options) !void {
    const out_path = opts.out.?; // cli.parse guarantees rec has -o

    var p: pipeline.Pipeline = undefined;
    p.init(init.gpa, opts) catch |err| reportInit(w, err);
    defer p.deinit();
    if (opts.verbose > 0) {
        try printRatePlan(w, p.plan, true);
        try w.flush();
    }

    var wsink: sink_mod.WavSink = undefined;
    var wbuf: [1 << 16]u8 = undefined;
    wsink.init(init.io, out_path, &wbuf, p.fs_audio) catch |err| reportRun(w, err);

    var running = Running.init(true);
    installSigint(&running); // Ctrl-C finalizes a live recording cleanly
    driveSource(&p, init, w, opts, .{ .wav = &wsink }, &running) catch |err| reportRun(w, err);
    try w.print("wrote {s}\n", .{out_path});
}

fn runPlay(init: std.process.Init, w: *Io.Writer, opts: cli.Options) !void {
    // Live playback: unless the user pinned --audio-rate, target the device's
    // native rate so our resampler owns the conversion, not miniaudio's mixer.
    var o = opts;
    if (o.audio_rate_hz == null) {
        const native = sink_mod.defaultDeviceRate();
        if (native != 0) o.audio_rate_hz = native;
    }

    var p: pipeline.Pipeline = undefined;
    p.init(init.gpa, o) catch |err| reportInit(w, err);
    defer p.deinit();
    if (opts.verbose > 0) {
        try printRatePlan(w, p.plan, true);
        try w.flush();
    }

    var ring_buf: [1 << 15]f32 = undefined; // ~0.7 s at 48 kHz
    var ring = ring_mod.Ring.init(&ring_buf);
    var running = Running.init(true);
    var asink: sink_mod.AudioSink = undefined;
    asink.init(&ring, &running, p.fs_audio) catch |err| reportRun(w, err);
    installSigint(&running);

    driveSource(&p, init, w, opts, .{ .audio = &asink }, &running) catch |err| reportRun(w, err);
}

/// Open the source selected by `opts` into caller-owned storage (file or rtl_tcp),
/// returning a Source that points at it. Caller closes via `source.close(io)`.
fn openSource(
    io: std.Io,
    gpa: std.mem.Allocator,
    opts: cli.Options,
    running: *const Running,
    fsrc: *source_mod.FileSource,
    rsrc: *source_mod.RtlTcpSource,
    usrc: *source_mod.UsbSource,
    reader_buf: []u8,
) !source_mod.Source {
    if (opts.rtl_tcp) |host_port| {
        const freq = switch (opts.input) {
            .freq => |f| f,
            .file => return error.RtlTcpNeedsFreq,
        };
        try rsrc.init(io, host_port, freq, opts.rate_hz, opts.gain, opts.ppm, reader_buf);
        return .{ .rtltcp = rsrc };
    }
    return switch (opts.input) {
        .file => |path| blk: {
            try fsrc.init(io, path, reader_buf);
            break :blk .{ .file = fsrc };
        },
        .freq => |freq| blk: {
            try usrc.init(gpa, running, opts.device, freq, opts.rate_hz, opts.gain, opts.ppm);
            break :blk .{ .usb = usrc };
        },
    };
}

fn driveSource(p: *pipeline.Pipeline, init: std.process.Init, w: *Io.Writer, opts: cli.Options, sink: sink_mod.Sink, running: *Running) !void {
    var fsrc: source_mod.FileSource = undefined;
    var rsrc: source_mod.RtlTcpSource = undefined;
    var usrc: source_mod.UsbSource = undefined;
    const source = try openSource(init.io, init.gpa, opts, running, &fsrc, &rsrc, &usrc, p.reader_buf);
    defer source.close(init.io);
    const dbg: ?pipeline.Pipeline.Debug = if (opts.verbose > 0)
        .{ .w = w, .periodic = opts.verbose >= 2 }
    else
        null;
    try p.run(init.io, source, sink, running, dbg);
}

const scan_seconds = 4;
const scan_read_bytes = 1 << 18;

fn runScan(init: std.process.Init, w: *Io.Writer, opts: cli.Options) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const max_iq = scan_read_bytes / 2;
    const plan = rateplan.plan(opts.rate_hz, opts.audio_rate_hz orelse 48_000, opts.sub_hz, opts.bw_hz) catch |err| reportInit(w, err);
    var fe = frontend_mod.Frontend.init(a, plan, max_iq) catch |err| reportInit(w, err);
    if (opts.verbose > 0) {
        try printRatePlan(w, plan, false);
        try w.flush();
    }

    const cap: usize = scan_seconds * @as(usize, @intFromFloat(fe.fs_mpx));
    const mpx = try a.alloc(f32, cap);
    const block = try a.alloc(u8, scan_read_bytes);
    const iq = try a.alloc(complex.C32, max_iq);
    const reader_buf = try a.alloc(u8, 1 << 16);
    const mpx_tmp = try a.alloc(f32, fe.outCap(max_iq));

    var running = Running.init(true);
    installSigint(&running);

    var fsrc: source_mod.FileSource = undefined;
    var rsrc: source_mod.RtlTcpSource = undefined;
    var usrc: source_mod.UsbSource = undefined;
    const source = openSource(io, init.gpa, opts, &running, &fsrc, &rsrc, &usrc, reader_buf) catch |err| reportRun(w, err);
    defer source.close(io);

    var filled: usize = 0;
    while (running.load(.monotonic) and filled < cap) {
        const nb = source.read(block) catch |err| reportRun(w, err);
        if (nb == 0) break;
        const niq = switch (source.format()) {
            .cu8 => complex.unpackCu8(block[0..nb], iq),
            .cs16 => complex.unpackCs16(block[0..nb], iq),
        };
        const n256 = fe.process(iq[0..niq], mpx_tmp);
        const take = @min(n256, cap - filled);
        @memcpy(mpx[filled .. filled + take], mpx_tmp[0..take]);
        filled += take;
    }

    if (opts.verbose > 0) if (source.stats()) |s| {
        const drop_pct = if (s.rx_bytes > 0)
            100.0 * @as(f64, @floatFromInt(s.dropped_bytes)) / @as(f64, @floatFromInt(s.rx_bytes))
        else
            0.0;
        try w.print("usb     : {d:.1} MB, drop {d} ({d:.2}%), ring peak {d}%\n", .{
            @as(f64, @floatFromInt(s.rx_bytes)) / 1e6, s.dropped_bytes, drop_pct, 100 * s.ring_high_water / s.ring_capacity,
        });
        try w.flush();
    };

    var res = detect.scan(init.gpa, mpx[0..filled], .{ .fs_mpx = fe.fs_mpx }) catch |err| reportRun(w, err);
    defer res.deinit();
    try printScan(w, res, opts.verbose);
}

fn printScan(w: *Io.Writer, res: detect.ScanResult, verbose: u8) !void {
    if (res.stereo) {
        try w.print("stereo : yes (pilot +{d:.0} dB)\n", .{res.pilot_snr_db});
    } else {
        try w.writeAll("stereo : no\n");
    }
    if (res.slots.len == 0) {
        try w.writeAll("no subcarriers detected above the noise floor\n");
        return;
    }
    try w.writeAll("\nslot      mod       bw         snr     guess\n");
    for (res.slots) |s| {
        try w.print("{f}\n", .{s});
        if (verbose >= 1) try printSlotMetrics(w, s.metrics);
    }
}

/// `-v`: the metrics behind each verdict — FM keys on `carrier` clearing carr_present,
/// DSB on it going below carr_null (suppressed) with high `sym`. NaN sym ⇒ slot fell out
/// below the SNR gate; NaN carrier ⇒ shoulders off the analyzed band.
fn printSlotMetrics(w: *Io.Writer, m: detect.SlotMetrics) !void {
    const g = detect.ScanConfig{};
    if (std.math.isNan(m.sym)) {
        try w.writeAll("          \u{2514} (not classified — below SNR gate)\n");
        return;
    }
    if (std.math.isNan(m.carrier_db)) {
        try w.print("          \u{2514} carrier n/a (shoulders off-band)  sym {d:.2}\n", .{m.sym});
        return;
    }
    try w.print("          \u{2514} carrier {d:.1} dB (FM > {d:.1}, DSB < {d:.1})  sym {d:.2}\n", .{
        m.carrier_db, g.carr_present_db, g.carr_null_db, m.sym,
    });
}

var g_running: ?*Running = null;

fn onSigint(_: std.posix.SIG) callconv(.c) void {
    if (g_running) |r| r.store(false, .release);
}

fn installSigint(running: *Running) void {
    g_running = running;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn reportInit(w: *Io.Writer, err: pipeline.InitError) noreturn {
    w.print("rtl-sca: {s}\n", .{pipelineErrorText(err)}) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

fn reportRun(w: *Io.Writer, err: anyerror) noreturn {
    const msg: []const u8 = switch (err) {
        error.RtlTcpNeedsFreq => "--rtl-tcp needs a frequency as the input, not a file",
        error.AudioInit, error.AudioStart => "could not open the audio output device",
        error.UsbOpen => "could not open the RTL-SDR (is it plugged in? try --device N)",
        error.UsbConfig => "could not configure the RTL-SDR (sample rate / freq / gain)",
        error.UsbRead => "RTL-SDR read failed (device unplugged?)",
        error.UsbThread => "could not start the RTL-SDR reader thread",
        else => @errorName(err),
    };
    w.print("rtl-sca: {s}\n", .{msg}) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

fn pipelineErrorText(err: pipeline.InitError) []const u8 {
    return switch (err) {
        error.NyquistTrap => "sample rate too low to extract the subcarrier safely",
        error.SubcarrierAboveNyquist => "subcarrier + bandwidth falls outside the usable MPX band",
        error.FilterTooSharp => "requested bandwidth needs an impractically sharp filter",
        error.BadBandwidth => "invalid --bw for this rate",
        error.OutOfMemory => "out of memory",
    };
}

/// Dump the derived rate chain (under -v). `audio_stages` is false for `scan`,
/// which only runs the IQ→MPX front-end and never reaches the channel/output.
fn printRatePlan(w: *Io.Writer, p: rateplan.RatePlan, audio_stages: bool) !void {
    try w.print("plan    : IQ {d:.0} → demod {d:.0} (÷{d}) → MPX {d:.0} (÷{d})", .{ p.fs_iq, p.fs_demod, p.d0, p.fs_mpx, p.d1 });
    if (audio_stages) {
        try w.print(" → chan {d:.0} (÷{d}) → out {d} (×{d}/{d})", .{ p.fs_chan, p.d2, p.fs_audio, p.resamp.l, p.resamp.m });
    }
    try w.writeAll(" Hz\n");
}

test {
    _ = cli;
    _ = @import("complex.zig");
    _ = @import("fmdemod.zig");
    _ = @import("firdecim.zig");
    _ = @import("nco.zig");
    _ = @import("deemph.zig");
    _ = @import("sink.zig");
    _ = @import("source.zig");
    _ = @import("subcarrier.zig");
    _ = @import("pipeline.zig");
    _ = @import("ring.zig");
    _ = @import("fft.zig");
    _ = @import("frontend.zig");
    _ = @import("detect.zig");
    _ = @import("complex.zig");
    _ = @import("demod_am.zig");
}
