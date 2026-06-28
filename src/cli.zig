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
    LowTuneFreq,
};

/// Below this, a tune frequency is almost certainly a missing suffix (`89.9` parses
/// as 89.9 Hz, not MHz) rather than a real band — no RTL-SDR use here tunes sub-MHz.
const min_tune_hz: u32 = 1_000_000;

/// Context captured during parsing for a richer error message: the option being
/// processed and the offending token. Empty fields mean "not applicable".
pub const Diag = struct {
    flag: []const u8 = "",
    token: []const u8 = "",
};

/// Parse the full argv (args[0] is the program name).
pub fn parse(args: []const [:0]const u8) Error!Options {
    var diag: Diag = .{};
    return parseWithDiag(args, &diag);
}

/// Like `parse`, but records the offending option/token into `diag` on error so
/// the caller can print a contextual message (see `reportError`).
pub fn parseWithDiag(args: []const [:0]const u8, diag: *Diag) Error!Options {
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
            diag.flag = name;

            if (verboseCount(name)) |n| {
                o.verbose +|= n; // saturating: -v, -vv, ... and --verbose all add up
            } else if (std.mem.eql(u8, name, "--source")) {
                source_path = try value(args, &i, inline_val, diag);
            } else if (std.mem.eql(u8, name, "--remote")) {
                o.remote = try value(args, &i, inline_val, diag);
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "--sub")) {
                o.sub_hz = try parseFreq(try value(args, &i, inline_val, diag));
            } else if (std.mem.eql(u8, name, "--bw")) {
                o.bw_hz = try parseFreq(try value(args, &i, inline_val, diag));
            } else if (std.mem.eql(u8, name, "--rate")) {
                o.rate_hz = try parseFreq(try value(args, &i, inline_val, diag));
            } else if (std.mem.eql(u8, name, "--audio-rate")) {
                o.audio_rate_hz = try parseFreq(try value(args, &i, inline_val, diag));
            } else if (std.mem.eql(u8, name, "--mod")) {
                o.mod = parseMod(try value(args, &i, inline_val, diag)) orelse return error.BadMod;
            } else if (std.mem.eql(u8, name, "--deemph")) {
                o.deemph_us = parseDeemph(try value(args, &i, inline_val, diag)) catch return error.BadDeemph;
            } else if (std.mem.eql(u8, name, "--gain")) {
                o.gain = std.fmt.parseFloat(f32, try value(args, &i, inline_val, diag)) catch return error.BadGain;
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "--device")) {
                o.device = std.fmt.parseInt(u32, try value(args, &i, inline_val, diag), 10) catch return error.BadDevice;
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "--ppm")) {
                o.ppm = std.fmt.parseInt(i32, try value(args, &i, inline_val, diag), 10) catch return error.BadPpm;
                radio_flag = name;
            } else if (std.mem.eql(u8, name, "-o")) {
                o.out = try value(args, &i, inline_val, diag);
            } else {
                diag.token = name;
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

    // A tune frequency below any radio band is almost always a missing suffix.
    if (o.input == .freq and o.input.freq < min_tune_hz) {
        diag.token = input_token.?;
        return error.LowTuneFreq;
    }

    // Radio-only knobs (gain/ppm/device/remote) make no sense for a file source.
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

/// A token that begins a new option rather than a value: starts with `-` and is
/// not a negative number (so `--bw`/`-v` are flags, but `-12`/`-0.5` are values).
fn looksLikeFlag(s: []const u8) bool {
    return s.len >= 2 and s[0] == '-' and !(std.ascii.isDigit(s[1]) or s[1] == '.');
}

/// Consume a flag's value: inline (`--flag=v`) if present, else the next token.
/// A following token that looks like another option is rejected as a missing
/// value rather than silently swallowed (so `--sub --bw 15k` reports that `--sub`
/// needs a value, not "invalid frequency").
fn value(args: []const [:0]const u8, i: *usize, inline_val: ?[]const u8, diag: *Diag) Error![]const u8 {
    if (inline_val) |v| {
        diag.token = v;
        return v;
    }
    if (i.* + 1 >= args.len) return error.MissingValue;
    const next = args[i.* + 1];
    if (looksLikeFlag(next)) {
        diag.token = next;
        return error.MissingValue;
    }
    i.* += 1;
    diag.token = args[i.*];
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
        error.LowTuneFreq => "tune frequency too low — frequencies are in Hz; add a k/M/G suffix (e.g. 89.9M)",
    };
}

/// Write a one-line error message (no trailing newline), naming the offending
/// option and token from `diag` where it adds clarity. Falls back to the static
/// `errorText` for errors without per-flag context.
pub fn reportError(w: *std.Io.Writer, err: Error, diag: Diag) std.Io.Writer.Error!void {
    switch (err) {
        error.MissingValue => if (diag.token.len > 0)
            try w.print("option '{s}' needs a value, but found '{s}'", .{ diag.flag, diag.token })
        else
            try w.print("option '{s}' needs a value", .{diag.flag}),
        error.UnknownFlag => try w.print("unknown flag '{s}'", .{diag.token}),
        error.BadFreq => try w.print("invalid frequency '{s}' for '{s}'", .{ diag.token, diag.flag }),
        error.BadMod => try w.print("invalid '{s}' for --mod (expected fm, am-env, am-coherent)", .{diag.token}),
        error.BadDeemph => try w.print("invalid '{s}' for --deemph (expected a time constant like 120us, or off)", .{diag.token}),
        error.BadGain => try w.print("invalid '{s}' for --gain", .{diag.token}),
        error.BadDevice => try w.print("invalid '{s}' for --device (expected an integer index)", .{diag.token}),
        error.BadPpm => try w.print("invalid '{s}' for --ppm (expected an integer)", .{diag.token}),
        error.LowTuneFreq => try w.print("tune frequency '{s}' is too low for a radio — frequencies are in Hz; add a k/M/G suffix (e.g. 89.9M)", .{diag.token}),
        else => try w.writeAll(errorText(err)),
    }
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

test "a flag does not swallow a following option as its value" {
    // `--sub --bw 15k`: --sub has no value -> MissingValue (not BadFreq on '--bw').
    var diag: Diag = .{};
    try testing.expectError(error.MissingValue, parseWithDiag(&[_][:0]const u8{ "rtl-sca", "play", "89.9M", "--sub", "--bw", "15k" }, &diag));
    try testing.expectEqualStrings("--sub", diag.flag);
    try testing.expectEqualStrings("--bw", diag.token);
}

test "negative numbers are values, not flags" {
    const o = try parse(&[_][:0]const u8{ "rtl-sca", "play", "89.9M", "--ppm", "-12" });
    try testing.expectEqual(@as(i32, -12), o.ppm);
}

test "a bad value records the flag and offending token" {
    var d1: Diag = .{};
    try testing.expectError(error.BadFreq, parseWithDiag(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--sub", "loud" }, &d1));
    try testing.expectEqualStrings("--sub", d1.flag);
    try testing.expectEqualStrings("loud", d1.token);

    var d2: Diag = .{};
    try testing.expectError(error.UnknownFlag, parseWithDiag(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--nope" }, &d2));
    try testing.expectEqualStrings("--nope", d2.token);
}

test "a bare FM frequency without a suffix is caught as too low" {
    var d: Diag = .{};
    try testing.expectError(error.LowTuneFreq, parseWithDiag(&[_][:0]const u8{ "rtl-sca", "scan", "89.9" }, &d));
    try testing.expectEqualStrings("89.9", d.token);
    // the suffixed form parses fine, and a file source is never range-checked
    try testing.expectEqual(@as(u32, 89_900_000), (try parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M" })).input.freq);
    try testing.expectEqualStrings("capture.cu8", (try parse(&[_][:0]const u8{ "rtl-sca", "scan", "capture.cu8" })).input.file);
}

test "error cases" {
    try testing.expectError(error.UnknownCommand, parse(&[_][:0]const u8{ "rtl-sca", "frob" }));
    try testing.expectError(error.UnknownFlag, parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--nope" }));
    try testing.expectError(error.MissingValue, parse(&[_][:0]const u8{ "rtl-sca", "scan", "89.9M", "--sub" }));
    try testing.expectError(error.NoInput, parse(&[_][:0]const u8{ "rtl-sca", "scan" }));
}
