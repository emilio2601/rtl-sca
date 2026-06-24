const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");

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

    try printPlan(w, opts);
    try w.writeAll("\n(DSP pipeline not implemented yet — Phase 1 in progress)\n");
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
}
