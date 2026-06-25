const std = @import("std");
const net = std.Io.net;

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
        const addr = try net.IpAddress.parseLiteral(host_port);
        const stream = try addr.connect(io, .{ .mode = .stream });
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

/// IQ input endpoint for the pipeline: a recorded file or a live rtl_tcp server.
pub const Source = union(enum) {
    file: *FileSource,
    rtltcp: *RtlTcpSource,

    pub fn read(self: Source, bytes: []u8) !usize {
        return switch (self) {
            .file => |f| f.read(bytes),
            .rtltcp => |r| r.read(bytes),
        };
    }
    pub fn format(self: Source) Format {
        return switch (self) {
            .file => |f| f.format,
            .rtltcp => |r| r.format,
        };
    }
    pub fn close(self: Source, io: std.Io) void {
        switch (self) {
            .file => |f| f.close(io),
            .rtltcp => |r| r.close(io),
        }
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
