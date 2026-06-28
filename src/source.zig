const std = @import("std");
const net = std.Io.net;
const rtlsdr = @import("rtlsdr");
const ring_mod = @import("ring.zig");
const Running = ring_mod.Running;

extern fn usleep(usecs: c_uint) c_int; // libc; pace the consumer when the ring is empty

/// Per-source streaming counters for `-v`/`-vv` diagnostics. Only live sources
/// report these; a file source has nothing to drop.
pub const StreamStats = struct {
    rx_bytes: u64,
    dropped_bytes: u64,
    ring_capacity: usize,
    ring_high_water: usize,
};

pub const Format = enum { cu8, cs16 };

/// Reads raw interleaved IQ from a file in blocks. Constructed in place (the
/// File.Reader must keep a stable address).
pub const FileSource = struct {
    file: std.Io.File,
    fr: std.Io.File.Reader,
    format: Format,

    pub fn init(self: *FileSource, io: std.Io, path: []const u8, rbuf: []u8) !void {
        self.* = .{
            .file = try std.Io.Dir.cwd().openFile(io, path, .{}),
            .fr = undefined,
            .format = detectFormat(path),
        };
        self.fr = self.file.reader(io, rbuf);
    }

    /// Fill `bytes`; returns count read (0 = EOF, short = final partial block).
    pub fn read(self: *FileSource, bytes: []u8) !usize {
        return self.fr.interface.readSliceShort(bytes);
    }

    pub fn close(self: *FileSource, io: std.Io) void {
        self.file.close(io);
    }
};

fn detectFormat(path: []const u8) Format {
    return if (std.mem.endsWith(u8, path, ".cs16")) .cs16 else .cu8;
}

// rtl_tcp command opcodes (param is a big-endian u32).
const CMD_FREQ: u8 = 0x01;
const CMD_RATE: u8 = 0x02;
const CMD_GAIN_MODE: u8 = 0x03; // 1 = manual, 0 = auto
const CMD_GAIN: u8 = 0x04; // tenths of a dB
const CMD_FREQ_CORR: u8 = 0x05; // ppm

fn encodeCmd(cmd: u8, param: u32) [5]u8 {
    var b: [5]u8 = undefined;
    b[0] = cmd;
    std.mem.writeInt(u32, b[1..5], param, .big);
    return b;
}

/// The upstream rtl_tcp default port; used when `--remote` omits one.
const rtl_tcp_port: u16 = 1234;

/// Connect to an rtl_tcp server given `host[:port]`. Tries a literal IP first —
/// the fast path, and the only form that carries `[ipv6]:port` — then falls back
/// to resolving the host as a name through the OS resolver (DNS + /etc/hosts), so
/// `pi4`, Tailscale MagicDNS names, etc. all work. This mirrors getaddrinfo's
/// numeric-host-then-resolve order; std keeps the literal and name paths as
/// separate typed entry points, so the branch (not a single helper) is the idiom.
fn connectHostPort(io: std.Io, host_port: []const u8) !net.Stream {
    if (net.IpAddress.parseLiteral(host_port)) |addr| {
        var a = addr;
        if (a.getPort() == 0) a.setPort(rtl_tcp_port); // bare IP -> default port
        return a.connect(io, .{ .mode = .stream });
    } else |_| {}
    const hp = try splitHostPort(host_port);
    const name = try net.HostName.init(hp.host);
    return name.connect(io, hp.port, .{ .mode = .stream });
}

/// Split `host[:port]` for the hostname path, defaulting the port to the
/// rtl_tcp port when it's omitted.
fn splitHostPort(s: []const u8) !struct { host: []const u8, port: u16 } {
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
        const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return error.InvalidPort;
        return .{ .host = s[0..colon], .port = port };
    }
    return .{ .host = s, .port = rtl_tcp_port };
}

/// Streams cu8 IQ from an `rtl_tcp` server. Connects, reads the 12-byte greeting,
/// sends the tune/rate/gain/ppm commands, then `read()` pulls IQ. Constructed in
/// place (Stream.Reader must keep a stable address). Always cu8 over the wire.
pub const RtlTcpSource = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    format: Format = .cu8,

    pub fn init(
        self: *RtlTcpSource,
        io: std.Io,
        host_port: []const u8,
        freq_hz: u32,
        rate_hz: u32,
        gain_db: ?f32,
        ppm: i32,
        rbuf: []u8,
    ) !void {
        const stream = try connectHostPort(io, host_port);
        self.* = .{ .stream = stream, .reader = undefined };
        self.reader = self.stream.reader(io, rbuf);

        _ = try self.reader.interface.takeArray(12); // greeting: "RTL0" + tuner info

        var wbuf: [64]u8 = undefined;
        var fw = self.stream.writer(io, &wbuf);
        const w = &fw.interface;
        try w.writeAll(&encodeCmd(CMD_RATE, rate_hz));
        try w.writeAll(&encodeCmd(CMD_FREQ, freq_hz));
        if (gain_db) |g| {
            try w.writeAll(&encodeCmd(CMD_GAIN_MODE, 1));
            const tenths: u32 = @intFromFloat(@round(g * 10.0));
            try w.writeAll(&encodeCmd(CMD_GAIN, tenths));
        } else {
            try w.writeAll(&encodeCmd(CMD_GAIN_MODE, 0));
        }
        if (ppm != 0) try w.writeAll(&encodeCmd(CMD_FREQ_CORR, @bitCast(ppm)));
        try w.flush();
    }

    pub fn read(self: *RtlTcpSource, bytes: []u8) !usize {
        return self.reader.interface.readSliceShort(bytes);
    }

    pub fn close(self: *RtlTcpSource, io: std.Io) void {
        self.stream.close(io);
    }
};

/// Streams cu8 IQ off a local RTL-SDR dongle via `librtlsdr`. A dedicated reader
/// thread runs the blocking `rtlsdr_read_async`, whose callback pushes IQ into a
/// lock-free ring; the DSP thread pops it in `read()`. This decoupling keeps the
/// USB serviced continuously: `rtlsdr_read_sync` only transfers while the caller
/// is inside the call, so any time the DSP spent processing left the dongle's
/// FIFO unserviced and silently dropped samples. Always cu8 over USB.
pub const UsbSource = struct {
    dev: *rtlsdr.rtlsdr_dev_t,
    gpa: std.mem.Allocator,
    ring_buf: []u8,
    ring: ring_mod.ByteRing,
    running: *const Running, // shared shutdown flag (SIGINT)
    reader: std.Thread,
    stopped: std.atomic.Value(bool), // reader thread has returned (cancel or error)
    reader_ret: c_int, // rtlsdr_read_async result; published before `stopped`
    format: Format = .cu8,

    // ~0.5 s of IQ at 1.024 Msps; absorbs DSP/scheduler jitter on top of
    // librtlsdr's own 15-buffer libusb pool. Must be a power of two.
    const RING_BYTES: usize = 1 << 20;

    pub fn init(
        self: *UsbSource,
        gpa: std.mem.Allocator,
        running: *const Running,
        device_index: u32,
        freq_hz: u32,
        rate_hz: u32,
        gain_db: ?f32,
        ppm: i32,
    ) !void {
        var dev: ?*rtlsdr.rtlsdr_dev_t = null;
        if (rtlsdr.rtlsdr_open(&dev, device_index) != 0) return error.UsbOpen;
        const d = dev.?;
        errdefer _ = rtlsdr.rtlsdr_close(d);

        if (rtlsdr.rtlsdr_set_sample_rate(d, rate_hz) != 0) return error.UsbConfig;
        if (rtlsdr.rtlsdr_set_center_freq(d, freq_hz) != 0) return error.UsbConfig;
        if (ppm != 0 and rtlsdr.rtlsdr_set_freq_correction(d, ppm) != 0) return error.UsbConfig;
        if (gain_db) |g| {
            if (rtlsdr.rtlsdr_set_tuner_gain_mode(d, 1) != 0) return error.UsbConfig;
            const tenths: c_int = @intFromFloat(@round(g * 10.0));
            if (rtlsdr.rtlsdr_set_tuner_gain(d, tenths) != 0) return error.UsbConfig;
        } else if (rtlsdr.rtlsdr_set_tuner_gain_mode(d, 0) != 0) { // auto
            return error.UsbConfig;
        }
        // Flush the dongle's stale internal buffers before streaming.
        if (rtlsdr.rtlsdr_reset_buffer(d) != 0) return error.UsbConfig;

        const ring_buf = try gpa.alloc(u8, RING_BYTES);
        errdefer gpa.free(ring_buf);
        self.* = .{
            .dev = d,
            .gpa = gpa,
            .ring_buf = ring_buf,
            .ring = ring_mod.ByteRing.init(ring_buf),
            .running = running,
            .reader = undefined,
            .stopped = .init(false),
            .reader_ret = 0,
        };
        self.reader = std.Thread.spawn(.{}, readerMain, .{self}) catch return error.UsbThread;
    }

    fn readerMain(self: *UsbSource) void {
        // Blocks until close() calls rtlsdr_cancel_async (or the device errors).
        self.reader_ret = rtlsdr.rtlsdr_read_async(self.dev, asyncCb, self, 0, 0);
        self.stopped.store(true, .release);
    }

    fn asyncCb(buf: [*c]u8, len: u32, ctx: ?*anyopaque) callconv(.c) void {
        const self: *UsbSource = @ptrCast(@alignCast(ctx.?));
        if (len > 0) self.ring.push(buf[0..len]);
    }

    /// Pop IQ from the ring; blocks until data is available, or returns 0 once
    /// the stream is shutting down and the ring is drained.
    pub fn read(self: *UsbSource, bytes: []u8) !usize {
        while (true) {
            const n = self.ring.pop(bytes);
            if (n > 0) return n;
            if (self.stopped.load(.acquire)) {
                if (!self.ring.isEmpty()) continue; // drain what's left
                return if (self.reader_ret != 0) error.UsbRead else 0;
            }
            if (!self.running.load(.monotonic)) return 0;
            _ = usleep(1000);
        }
    }

    pub fn stats(self: *const UsbSource) StreamStats {
        return .{
            .rx_bytes = self.ring.rx.load(.monotonic),
            .dropped_bytes = self.ring.dropped.load(.monotonic),
            .ring_capacity = self.ring_buf.len,
            .ring_high_water = self.ring.high_water.load(.monotonic),
        };
    }

    pub fn close(self: *UsbSource, io: std.Io) void {
        _ = io; // USB teardown is internal to librtlsdr
        _ = rtlsdr.rtlsdr_cancel_async(self.dev); // unblocks the reader thread
        self.reader.join();
        _ = rtlsdr.rtlsdr_close(self.dev);
        self.gpa.free(self.ring_buf);
    }
};

/// IQ input endpoint for the pipeline: a recorded file, an rtl_tcp server, or a
/// local USB dongle.
pub const Source = union(enum) {
    file: *FileSource,
    rtltcp: *RtlTcpSource,
    usb: *UsbSource,

    pub fn read(self: Source, bytes: []u8) !usize {
        return switch (self) {
            .file => |f| f.read(bytes),
            .rtltcp => |r| r.read(bytes),
            .usb => |u| u.read(bytes),
        };
    }
    /// A live feed (radio/network) that can drop mid-stream, vs. a file that
    /// ends only at EOF. A mid-stream read failure on a live source is a clean
    /// end-of-stream, not a fatal error (see Pipeline.run).
    pub fn isLive(self: Source) bool {
        return self != .file;
    }
    pub fn format(self: Source) Format {
        return switch (self) {
            .file => |f| f.format,
            .rtltcp => |r| r.format,
            .usb => |u| u.format,
        };
    }
    pub fn close(self: Source, io: std.Io) void {
        switch (self) {
            .file => |f| f.close(io),
            .rtltcp => |r| r.close(io),
            .usb => |u| u.close(io),
        }
    }
    /// Live streaming counters, or null for sources that can't drop (files).
    pub fn stats(self: Source) ?StreamStats {
        return switch (self) {
            .usb => |u| u.stats(),
            else => null,
        };
    }
};

const testing = std.testing;

test "encodeCmd big-endian framing" {
    const c = encodeCmd(CMD_FREQ, 104_300_000);
    try testing.expectEqual(@as(u8, 0x01), c[0]);
    try testing.expectEqual(@as(u32, 104_300_000), std.mem.readInt(u32, c[1..5], .big));
    // ppm round-trips through the bit-cast path
    const p = encodeCmd(CMD_FREQ_CORR, @bitCast(@as(i32, -12)));
    try testing.expectEqual(@as(i32, -12), @as(i32, @bitCast(std.mem.readInt(u32, p[1..5], .big))));
}

test "splitHostPort defaults the port to 1234 when omitted" {
    const a = try splitHostPort("pi4");
    try testing.expectEqualStrings("pi4", a.host);
    try testing.expectEqual(@as(u16, 1234), a.port);

    const b = try splitHostPort("pi4.local:5678");
    try testing.expectEqualStrings("pi4.local", b.host);
    try testing.expectEqual(@as(u16, 5678), b.port);

    try testing.expectError(error.InvalidPort, splitHostPort("pi4:nope"));
}

test "detectFormat" {
    try testing.expectEqual(Format.cu8, detectFormat("capture.cu8"));
    try testing.expectEqual(Format.cs16, detectFormat("capture.cs16"));
    try testing.expectEqual(Format.cu8, detectFormat("noext"));
}

test "FileSource reads back written bytes and signals EOF" {
    const io = testing.io;
    const path = "rtl_sca_filesource_test.cu8";
    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        var wbuf: [64]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        try fw.interface.writeAll(&payload);
        try fw.interface.flush();
        f.close(io);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var rbuf: [64]u8 = undefined;
    var src: FileSource = undefined;
    try src.init(io, path, &rbuf);
    defer src.close(io);
    try testing.expectEqual(Format.cu8, src.format);

    var got: [10]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try src.read(got[total..]);
        if (n == 0) break;
        total += n;
    }
    try testing.expectEqual(@as(usize, 10), total);
    try testing.expectEqualSlices(u8, &payload, &got);
}
