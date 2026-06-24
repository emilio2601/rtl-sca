const std = @import("std");

/// Writes a canonical 16-bit PCM mono WAV. The 44-byte header is written up front
/// with placeholder sizes; `finish` seeks back and patches the RIFF and data sizes.
/// Constructed in place (the File.Writer must keep a stable address).
pub const WavSink = struct {
    file: std.Io.File,
    fw: std.Io.File.Writer,
    sample_rate: u32,
    frames: u32 = 0,

    pub fn init(self: *WavSink, io: std.Io, path: []const u8, wbuf: []u8, sample_rate: u32) !void {
        self.* = .{
            .file = try std.Io.Dir.cwd().createFile(io, path, .{}),
            .fw = undefined,
            .sample_rate = sample_rate,
            .frames = 0,
        };
        self.fw = self.file.writer(io, wbuf);
        try self.writeHeader(0);
    }

    fn writeHeader(self: *WavSink, data_bytes: u32) !void {
        const w = &self.fw.interface;
        try w.writeAll("RIFF");
        try w.writeInt(u32, 36 + data_bytes, .little);
        try w.writeAll("WAVE");
        try w.writeAll("fmt ");
        try w.writeInt(u32, 16, .little); // PCM fmt chunk size
        try w.writeInt(u16, 1, .little); // PCM
        try w.writeInt(u16, 1, .little); // mono
        try w.writeInt(u32, self.sample_rate, .little);
        try w.writeInt(u32, self.sample_rate * 2, .little); // byte rate = fs * ch * 2
        try w.writeInt(u16, 2, .little); // block align = ch * 2
        try w.writeInt(u16, 16, .little); // bits per sample
        try w.writeAll("data");
        try w.writeInt(u32, data_bytes, .little);
    }

    pub fn writeAudio(self: *WavSink, samples: []const f32) !void {
        const w = &self.fw.interface;
        for (samples) |s| {
            const v: i16 = @round(std.math.clamp(s, -1.0, 1.0) * 32767.0);
            try w.writeInt(i16, v, .little);
        }
        self.frames += @intCast(samples.len);
    }

    pub fn finish(self: *WavSink, io: std.Io) !void {
        const data_bytes = self.frames * 2;
        try self.fw.seekTo(4);
        try self.fw.interface.writeInt(u32, 36 + data_bytes, .little);
        try self.fw.seekTo(40);
        try self.fw.interface.writeInt(u32, data_bytes, .little);
        try self.fw.interface.flush();
        self.file.close(io);
    }
};

const testing = std.testing;

test "WavSink round-trips header and samples" {
    const io = testing.io;
    const path = "rtl_sca_wavsink_test.wav";

    var wbuf: [512]u8 = undefined;
    var sink: WavSink = undefined;
    try sink.init(io, path, &wbuf, 16000);
    try sink.writeAudio(&.{ 0.0, 1.0, -1.0, 0.5 });
    try sink.finish(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var rbuf: [128]u8 = undefined;
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var fr = f.reader(io, &rbuf);
    var buf: [44 + 8]u8 = undefined;
    try fr.interface.readSliceAll(&buf);

    try testing.expectEqualSlices(u8, "RIFF", buf[0..4]);
    try testing.expectEqualSlices(u8, "WAVE", buf[8..12]);
    try testing.expectEqualSlices(u8, "data", buf[36..40]);
    try testing.expectEqual(@as(u32, 16000), std.mem.readInt(u32, buf[24..28], .little));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, buf[40..44], .little)); // 4 frames * 2
    try testing.expectEqual(@as(u32, 36 + 8), std.mem.readInt(u32, buf[4..8], .little));
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, buf[44..46], .little));
    try testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, buf[46..48], .little));
    try testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, buf[48..50], .little));
    try testing.expectEqual(@as(i16, 16384), std.mem.readInt(i16, buf[50..52], .little)); // 0.5*32767≈16384
}
