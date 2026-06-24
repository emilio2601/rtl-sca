const std = @import("std");

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

const testing = std.testing;

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
