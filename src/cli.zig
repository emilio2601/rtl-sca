const std = @import("std");

pub const Command = enum { scan, play, rec };

pub const Mod = enum { fm, am_env, am_coherent };

/// Where IQ comes from: a tuned radio frequency, or a recorded file.
pub const Input = union(enum) {
    freq: u32, // main FM carrier, Hz
    file: []const u8, // path to recorded IQ
};

pub const Options = struct {
    command: Command,
    input: Input,
    remote: ?[]const u8 = null, // rtl_tcp server as host:port (literal IP or hostname)
    sub_hz: u32 = 67_000, // 0 = main program channel
    /// Unique bandwidth to recover, Hz: the audio bandwidth for the main channel
    /// (`sub` 0), or the slot width for a subcarrier (~8k SCA voice, ~15k main).
    bw_hz: u32 = 8_000,
    mod: Mod = .fm,
    /// De-emphasis time constant in microseconds; 0 = off. Feeds
    /// alpha = dt/(tau+dt), computed at the audio rate. Default 150us (SCA).
    deemph_us: f64 = 150,
    rate_hz: u32 = 1_024_000,
    /// Audio output sample rate in Hz, or null to resolve per command: file
    /// output defaults to 48000; live playback negotiates the device's native
    /// rate. A rational resampler bridges the internal content rate to it.
    audio_rate_hz: ?u32 = null,
    gain: ?f32 = null, // null = auto
    device: u32 = 0, // USB dongle index
    ppm: i32 = 0, // crystal correction
    out: ?[]const u8 = null,
    verbose: u8 = 0, // -v count: 0 normal, 1 per-slot classifier metrics (scan)
};

pub const Error = error{
    NoCommand,
    UnknownCommand,
    NoInput,
    UnknownFlag,
    MissingValue,
    BadFreq,
    BadMod,
    BadDeemph,
    BadGain,
    BadDevice,
    BadPpm,
    RadioFlagWithFile,
    MissingOutput,
};

/// Parse the full argv (args[0] is the program name).
pub fn parse(args: []const [:0]const u8) Error!Options {
    if (args.len < 2) return error.NoCommand;
    const command = std.meta.stringToEnum(Command, args[1]) orelse return error.UnknownCommand;

    var input_token: ?[]const u8 = null;
    var source_path: ?[]const u8 = null;
    var radio_flag: ?[]const u8 = null; // a radio-only flag seen, for file conflict check
    var o = Options{ .command = command, .input = undefined };

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const tok = args[i];
        if (tok.len > 0 and tok[0] == '-') {
            // Support both "--flag value" and "--flag=value".
            var name: []const u8 = tok;
            var inline_val: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
                name = tok[0..eq];
                inline_val = tok[eq + 1 ..];
            }

            if (verboseCount(name)) |n| {
                o.verbose +|= n; // saturating: -v, -vv, ... and --verbose all add up
            } else if (std.mem.eql(u8, name, "--source")) {
                source_path = try value(args, &i, inline_val);
            } else if (std.mem.eql(u8, name, "--remote")) {
                o.remote = try value(args, &i, inline_val);
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "--sub")) {
                o.sub_hz = try parseFreq(try value(args, &i, inline_val));
            } else if (std.mem.eql(u8, name, "--bw")) {
                o.bw_hz = try parseFreq(try value(args, &i, inline_val));
            } else if (std.mem.eql(u8, name, "--rate")) {
                o.rate_hz = try parseFreq(try value(args, &i, inline_val));
            } else if (std.mem.eql(u8, name, "--audio-rate")) {
                o.audio_rate_hz = try parseFreq(try value(args, &i, inline_val));
            } else if (std.mem.eql(u8, name, "--mod")) {
                o.mod = parseMod(try value(args, &i, inline_val)) orelse return error.BadMod;
            } else if (std.mem.eql(u8, name, "--deemph")) {
                o.deemph_us = parseDeemph(try value(args, &i, inline_val)) catch return error.BadDeemph;
            } else if (std.mem.eql(u8, name, "--gain")) {
                o.gain = std.fmt.parseFloat(f32, try value(args, &i, inline_val)) catch return error.BadGain;
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "--device")) {
                o.device = std.fmt.parseInt(u32, try value(args, &i, inline_val), 10) catch return error.BadDevice;
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "--ppm")) {
                o.ppm = std.fmt.parseInt(i32, try value(args, &i, inline_val), 10) catch return error.BadPpm;
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "-o")) {
                o.out = try value(args, &i, inline_val);
            } else {
                return error.UnknownFlag;
            }
        } else {
            input_token = tok; // last positional wins
        }
    }

    // Resolve the input: explicit --source overrides; otherwise auto-detect the
    // positional as a frequency (parses as a number) or else a file path.
    if (source_path) |p| {
        o.input = .{ .file = p };
    } else if (input_token) |t| {
        o.input = if (parseFreq(t)) |hz| .{ .freq = hz } else |_| .{ .file = t };
    } else {
        return error.NoInput;
    }

    // Radio-only knobs (gain/ppm/device/rtl-tcp) make no sense for a file source.
    if (o.input == .file and radio_flag != null) return error.RadioFlagWithFile;

    if (command == .rec and o.out == null) return error.MissingOutput;
    return o;
}

/// Count repeated-`v` verbosity: `-v`→1, `-vv`→2, …, and `--verbose`→1. Returns null
/// for anything else (so `-o`, `--source`, etc. fall through to their own handlers).
fn verboseCount(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "--verbose")) return 1;
    if (name.len >= 2 and name[0] == '-' and name[1] != '-') {
        for (name[1..]) |c| if (c != 'v') return null;
        return @intCast(name.len - 1);
    }
    return null;
}

/// Consume a flag's value: inline (`--flag=v`) if present, else the next token.
fn value(args: []const [:0]const u8, i: *usize, inline_val: ?[]const u8) Error![]const u8 {
    if (inline_val) |v| return v;
    if (i.* + 1 >= args.len) return error.MissingValue;
    i.* += 1;
    return args[i.*];
}

/// Parse a frequency token: a decimal with an optional k/M/G suffix, or raw Hz.
/// Case-insensitive suffix (these are frequencies — no milli ambiguity).
pub fn parseFreq(s: []const u8) Error!u32 {
    if (s.len == 0) return error.BadFreq;
    var mult: f64 = 1;
    var num = s;
    switch (s[s.len - 1]) {
        'k', 'K' => mult = 1e3,
        'm', 'M' => mult = 1e6,
        'g', 'G' => mult = 1e9,
        else => mult = 1,
    }
    if (mult != 1) num = s[0 .. s.len - 1];

    const base = std.fmt.parseFloat(f64, num) catch return error.BadFreq;
    const hz = base * mult;
    if (hz < 0 or hz > @as(f64, std.math.maxInt(u32))) return error.BadFreq;
    // 0.16: @round converts float->int directly given a u32 result type.
    const rounded: u32 = @round(hz);
    return rounded;
}

fn parseMod(s: []const u8) ?Mod {
    if (std.mem.eql(u8, s, "fm")) return .fm;
    if (std.mem.eql(u8, s, "am-env")) return .am_env;
    if (std.mem.eql(u8, s, "am-coherent")) return .am_coherent;
    return null;
}

/// Parse a de-emphasis time constant into microseconds; `off` is tau = 0.
/// Accepts a number with an optional `us` suffix (e.g. `120us` or `120`).
fn parseDeemph(s: []const u8) Error!f64 {
    if (std.mem.eql(u8, s, "off")) return 0;
    const num = if (std.mem.endsWith(u8, s, "us")) s[0 .. s.len - 2] else s;
    const us = std.fmt.parseFloat(f64, num) catch return error.BadDeemph;
    if (us < 0) return error.BadDeemph;
    return us;
}

/// Human-readable message for a parse error (for the CLI front-end).
pub fn errorText(err: Error) []const u8 {
    return switch (err) {
        error.NoCommand => "missing subcommand",
        error.UnknownCommand => "unknown subcommand",
        error.NoInput => "missing input (a frequency like 89.9M or a file path)",
        error.UnknownFlag => "unknown flag",
        error.MissingValue => "flag is missing its value",
        error.BadFreq => "invalid frequency",
        error.BadMod => "invalid --mod (expected fm, am-env, am-coherent)",
        error.BadDeemph => "invalid --deemph (expected a time constant like 120us, or off)",
        error.BadGain => "invalid --gain",
        error.BadDevice => "invalid --device (expected an integer index)",
        error.BadPpm => "invalid --ppm (expected an integer)",
        error.RadioFlagWithFile => "radio-only flag (--gain/--ppm/--device/--remote) used with a file source",
        error.MissingOutput => "rec requires -o <file.wav>",
    };
}

const testing = std.testing;

test "parseFreq suffixes and raw Hz" {
    try testing.expectEqual(@as(u32, 89_900_000), try parseFreq("89.9M"));
    try testing.expectEqual(@as(u32, 67_000), try parseFreq("67k"));
    try testing.expectEqual(@as(u32, 1_024_000), try parseFreq("1.024M"));
    try testing.expectEqual(@as(u32, 89_900_000), try parseFreq("89900000"));
    try testing.expectError(error.BadFreq, parseFreq("capture.cu8"));
    try testing.expectError(error.BadFreq, parseFreq(""));
}

test "scan with positional frequency" {
    const args = [_][:0]const u8{ "rtl-sca", "scan", "89.9M" };
    const o = try parse(&args);
    try testing.expectEqual(Command.scan, o.command);
    try testing.expectEqual(@as(u32, 89_900_000), o.input.freq);
    try testing.expectEqual(@as(u32, 67_000), o.sub_hz); // default
    try testing.expectEqual(@as(u32, 8_000), o.bw_hz); // default
    try testing.expectEqual(Mod.fm, o.mod);
    try testing.expectEqual(@as(f64, 150), o.deemph_us); // default
}

test "main channel: --sub 0 with wider bandwidth" {
    const args = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--sub", "0", "--bw", "15k", "--deemph", "75us" };
    const o = try parse(&args);
    try testing.expectEqual(@as(u32, 0), o.sub_hz);
    try testing.expectEqual(@as(u32, 15_000), o.bw_hz);
    try testing.expectEqual(@as(f64, 75), o.deemph_us);
}

test "deemph: arbitrary value, presets, and off share one path" {
    const arbitrary = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--deemph", "120us" };
    try testing.expectEqual(@as(f64, 120), (try parse(&arbitrary)).deemph_us);

    const preset = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--deemph", "75us" };
    try testing.expectEqual(@as(f64, 75), (try parse(&preset)).deemph_us);

    const off = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--deemph", "off" };
    try testing.expectEqual(@as(f64, 0), (try parse(&off)).deemph_us);

    const bare = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--deemph", "50" };
    try testing.expectEqual(@as(f64, 50), (try parse(&bare)).deemph_us);

    const bad = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--deemph", "loud" };
    try testing.expectError(error.BadDeemph, parse(&bad));
}

test "play from file with flags" {
    const args = [_][:0]const u8{ "rtl-sca", "play", "capture.cu8", "--sub", "86k", "--mod", "am-env", "--deemph", "off" };
    const o = try parse(&args);
    try testing.expectEqualStrings("capture.cu8", o.input.file);
    try testing.expectEqual(@as(u32, 86_000), o.sub_hz);
    try testing.expectEqual(Mod.am_env, o.mod);
    try testing.expectEqual(@as(f64, 0), o.deemph_us);
}

test "--remote sets the rtl_tcp server (host:port kept verbatim)" {
    const ip = [_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--remote", "192.168.1.50:1234" };
    try testing.expectEqualStrings("192.168.1.50:1234", (try parse(&ip)).remote.?);

    const host = [_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--remote=pi4:1234" };
    try testing.expectEqualStrings("pi4:1234", (try parse(&host)).remote.?);

    // --remote is radio-only: rejected with a file source.
    const withFile = [_][:0]const u8{ "rtl-sca", "scan", "capture.cu8", "--remote", "pi4:1234" };
    try testing.expectError(error.RadioFlagWithFile, parse(&withFile));
}

test "radio knobs: device, ppm, gain" {
    const args = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--device", "2", "--ppm", "-12", "--gain", "28.0" };
    const o = try parse(&args);
    try testing.expectEqual(@as(u32, 2), o.device);
    try testing.expectEqual(@as(i32, -12), o.ppm);
    try testing.expectEqual(@as(f32, 28.0), o.gain.?);
}

test "radio-only flag with a file source is rejected" {
    const args = [_][:0]const u8{ "rtl-sca", "play", "capture.cu8", "--ppm", "10" };
    try testing.expectError(error.RadioFlagWithFile, parse(&args));
}

test "rate is allowed with a file source" {
    const args = [_][:0]const u8{ "rtl-sca", "play", "capture.cu8", "--rate", "1.024M" };
    const o = try parse(&args);
    try testing.expectEqual(@as(u32, 1_024_000), o.rate_hz);
}

test "audio-rate flag and its default" {
    // Unset: resolved per command downstream (file 48k / device-native), not here.
    const dflt = [_][:0]const u8{ "rtl-sca", "play", "89.9M" };
    try testing.expectEqual(@as(?u32, null), (try parse(&dflt)).audio_rate_hz);

    const set = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--audio-rate", "16k" };
    try testing.expectEqual(@as(?u32, 16_000), (try parse(&set)).audio_rate_hz);
}

test "verbose count: -v, -vv, --verbose, and non-verbose short flags" {
    try testing.expectEqual(@as(u8, 1), (try parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "-v" })).verbose);
    try testing.expectEqual(@as(u8, 2), (try parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "-vv" })).verbose);
    try testing.expectEqual(@as(u8, 1), (try parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--verbose" })).verbose);
    try testing.expectEqual(@as(u8, 0), (try parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M" })).verbose);
    // -o is not a verbose flag
    try testing.expectEqualStrings("o.wav", (try parse(&[_][:0]const u8{ "rtl-sca", "rec", "89.9M", "-o", "o.wav" })).out.?);
    // a non-all-v short token is still an unknown flag
    try testing.expectError(error.UnknownFlag, parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "-vx" }));
}

test "inline --flag=value form" {
    const args = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--sub=92k" };
    const o = try parse(&args);
    try testing.expectEqual(@as(u32, 92_000), o.sub_hz);
}

test "explicit --source overrides positional" {
    const args = [_][:0]const u8{ "rtl-sca", "play", "89.9M", "--source", "weird-name" };
    const o = try parse(&args);
    try testing.expectEqualStrings("weird-name", o.input.file);
}

test "rec requires output and accepts -o" {
    const ok = [_][:0]const u8{ "rtl-sca", "rec", "89.9M", "-o", "out.wav" };
    const o = try parse(&ok);
    try testing.expectEqualStrings("out.wav", o.out.?);

    const missing = [_][:0]const u8{ "rtl-sca", "rec", "89.9M" };
    try testing.expectError(error.MissingOutput, parse(&missing));
}

test "error cases" {
    try testing.expectError(error.UnknownCommand, parse(&[_][:0]const u8{ "rtl-sca", "frob" }));
    try testing.expectError(error.UnknownFlag, parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--nope" }));
    try testing.expectError(error.MissingValue, parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--sub" }));
    try testing.expectError(error.NoInput, parse(&[_][:0]const u8{ "rtl-sca", "scan" }));
}
