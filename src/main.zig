const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const pipeline = @import("pipeline.zig");
const ring_mod = @import("ring.zig");
const Running = ring_mod.Running;
const source_mod = @import("source.zig");
const sink_mod = @import("sink.zig");

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
    \\  --bw HZ           channel bandwidth: 8k SCA, 15k main (default 8k)
    \\  --mod MODE        fm | am-env | am-coherent (default fm)
    \\  --deemph TAU      de-emphasis time constant, e.g. 120us; off=none
    \\                    (default 150us SCA; 75us US, 50us EU main channel)
    \\  --rate HZ         RTL sample rate (default 1.024M)
    \\  --gain DB         tuner gain (default auto)
    \\  --device N        USB dongle index (default 0)
    \\  --ppm N           crystal frequency correction, ppm (default 0)
    \\  -o FILE           output WAV path (rec)
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
        .scan => {
            try printPlan(w, opts);
            try w.writeAll("\n('scan' is not implemented yet — Phase 4)\n");
        },
    }
}

fn runRec(init: std.process.Init, w: *Io.Writer, opts: cli.Options) !void {
    const out_path = opts.out.?; // cli.parse guarantees rec has -o

    var p: pipeline.Pipeline = undefined;
    p.init(init.gpa, opts) catch |err| reportInit(w, err);
    defer p.deinit();

    var wsink: sink_mod.WavSink = undefined;
    var wbuf: [1 << 16]u8 = undefined;
    wsink.init(init.io, out_path, &wbuf, p.fs_audio) catch |err| reportRun(w, err);

    var running = Running.init(true);
    installSigint(&running); // Ctrl-C finalizes a live recording cleanly
    driveSource(&p, init, opts, .{ .wav = &wsink }, &running) catch |err| reportRun(w, err);
    try w.print("wrote {s}\n", .{out_path});
}

fn runPlay(init: std.process.Init, w: *Io.Writer, opts: cli.Options) !void {
    var p: pipeline.Pipeline = undefined;
    p.init(init.gpa, opts) catch |err| reportInit(w, err);
    defer p.deinit();

    var ring_buf: [1 << 15]f32 = undefined; // ~2 s at 16 kHz
    var ring = ring_mod.Ring.init(&ring_buf);
    var running = Running.init(true);
    var asink: sink_mod.AudioSink = undefined;
    asink.init(&ring, &running, p.fs_audio) catch |err| reportRun(w, err);
    installSigint(&running);

    driveSource(&p, init, opts, .{ .audio = &asink }, &running) catch |err| reportRun(w, err);
}

/// Build the right source (file or rtl_tcp) as a local and pump it into `sink`.
fn driveSource(p: *pipeline.Pipeline, init: std.process.Init, opts: cli.Options, sink: sink_mod.Sink, running: *Running) !void {
    const io = init.io;
    if (opts.rtl_tcp) |host_port| {
        const freq = switch (opts.input) {
            .freq => |f| f,
            .file => return error.RtlTcpNeedsFreq,
        };
        var rs: source_mod.RtlTcpSource = undefined;
        try rs.init(io, host_port, freq, opts.rate_hz, opts.gain, opts.ppm, p.reader_buf);
        defer rs.close(io);
        try p.run(io, .{ .rtltcp = &rs }, sink, running);
    } else switch (opts.input) {
        .file => |path| {
            var fs: source_mod.FileSource = undefined;
            try fs.init(io, path, p.reader_buf);
            defer fs.close(io);
            try p.run(io, .{ .file = &fs }, sink, running);
        },
        .freq => return error.LiveFreqNeedsRtlTcp,
    }
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
        error.LiveFreqNeedsRtlTcp => "a live radio frequency needs --rtl-tcp host:port (USB is a later phase)",
        error.RtlTcpNeedsFreq => "--rtl-tcp needs a frequency as the input, not a file",
        error.AudioInit, error.AudioStart => "could not open the audio output device",
        else => @errorName(err),
    };
    w.print("rtl-sca: {s}\n", .{msg}) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

fn pipelineErrorText(err: pipeline.InitError) []const u8 {
    return switch (err) {
        error.RateNotDivisible => "sample rate must divide to 16 kHz audio (try --rate 1.024M)",
        error.NyquistTrap => "sample rate too low to extract the subcarrier safely",
        error.SubcarrierAboveNyquist => "subcarrier + bandwidth falls outside the usable MPX band",
        error.FilterTooSharp => "requested bandwidth needs an impractically sharp filter",
        error.BadBandwidth => "invalid --bw for this rate",
        error.OutOfMemory => "out of memory",
    };
}

fn printPlan(w: *Io.Writer, o: cli.Options) !void {
    try w.print("command : {t}\n", .{o.command});
    switch (o.input) {
        .freq => |hz| {
            if (o.rtl_tcp) |hp| {
                try w.print("source  : rtl_tcp {s} @ {d} Hz\n", .{ hp, hz });
            } else {
                try w.print("source  : radio dev {d} @ {d} Hz\n", .{ o.device, hz });
            }
            if (o.gain) |g| {
                try w.print("gain    : {d} dB\n", .{g});
            } else {
                try w.writeAll("gain    : auto\n");
            }
            try w.print("ppm     : {d}\n", .{o.ppm});
        },
        .file => |path| try w.print("source  : file {s}\n", .{path}),
    }
    if (o.sub_hz == 0) {
        try w.writeAll("sub     : 0 Hz (main channel)\n");
    } else {
        try w.print("sub     : {d} Hz\n", .{o.sub_hz});
    }
    try w.print("bw      : {d} Hz\n", .{o.bw_hz});
    try w.print("mod     : {t}\n", .{o.mod});
    if (o.deemph_us == 0) {
        try w.writeAll("deemph  : off\n");
    } else {
        try w.print("deemph  : {d}us\n", .{o.deemph_us});
    }
    try w.print("rate    : {d} Hz\n", .{o.rate_hz});
    if (o.out) |path| try w.print("out     : {s}\n", .{path});
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
}
