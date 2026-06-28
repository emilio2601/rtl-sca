const std = @import("std");
const audio = @import("audio");
const Ring = @import("ring.zig").Ring;
const Running = @import("ring.zig").Running;

extern fn usleep(usecs: c_uint) c_int; // libc; backpressure pacing for the producer

/// Writes a canonical 16-bit PCM mono WAV. For a real file the 44-byte header is
/// written with placeholder sizes that `finish` seeks back and patches. The path
/// `-` writes to stdout: a pipe isn't seekable, so the sizes are advertised as
/// unknown (0xFFFFFFFF) up front and never patched — players read to EOF.
/// Constructed in place (the File.Writer must keep a stable address).
pub const WavSink = struct {
    file: std.Io.File,
    fw: std.Io.File.Writer,
    sample_rate: u32,
    frames: u32 = 0,
    streaming: bool = false, // non-seekable output (stdout): can't back-patch sizes

    pub fn init(self: *WavSink, io: std.Io, path: []const u8, wbuf: []u8, sample_rate: u32) !void {
        const to_stdout = std.mem.eql(u8, path, "-");
        self.* = .{
            .file = if (to_stdout) std.Io.File.stdout() else try std.Io.Dir.cwd().createFile(io, path, .{}),
            .fw = undefined,
            .sample_rate = sample_rate,
            .frames = 0,
            .streaming = to_stdout,
        };
        self.fw = self.file.writer(io, wbuf);
        try self.writeHeader();
    }

    fn writeHeader(self: *WavSink) !void {
        const w = &self.fw.interface;
        // Real file: 0 now, patched in finish(). Stdout: 0xFFFFFFFF (unknown length).
        const data_bytes: u32 = if (self.streaming) 0xFFFF_FFFF else 0;
        const riff_bytes: u32 = if (self.streaming) 0xFFFF_FFFF else 36;
        try w.writeAll("RIFF");
        try w.writeInt(u32, riff_bytes, .little);
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
        if (!self.streaming) {
            const data_bytes = self.frames * 2;
            try self.fw.seekTo(4);
            try self.fw.interface.writeInt(u32, 36 + data_bytes, .little);
            try self.fw.seekTo(40);
            try self.fw.interface.writeInt(u32, data_bytes, .little);
        }
        try self.fw.interface.flush();
        if (!self.streaming) self.file.close(io); // leave stdout open for the shell
    }
};

/// Plays mono f32 audio live through the default device (miniaudio, via the C
/// shim). The DSP thread calls `writeAudio` (producer); miniaudio's audio thread
/// pulls from the ring in `pullCb` (consumer). The ring is caller-owned and must
/// outlive the device.
pub const AudioSink = struct {
    handle: *audio.sca_audio,
    ring: *Ring,
    running: *const Running,
    underruns: std.atomic.Value(u64), // audio callbacks that hit an empty ring
    primed: std.atomic.Value(bool), // false until the ring first fills to prime_frames
    prime_frames: usize, // initial cushion before playback starts (avoids startup underruns)

    pub fn init(self: *AudioSink, ring: *Ring, running: *const Running, sample_rate: u32) !void {
        const h = audio.sca_audio_create() orelse return error.AudioInit;
        self.* = .{
            .handle = h,
            .ring = ring,
            .running = running,
            .underruns = .init(0),
            .primed = .init(false),
            .prime_frames = sample_rate / 20, // ~50 ms; the device warms up faster than the first IQ arrives
        };
        if (audio.sca_audio_start(h, sample_rate, pullCb, @ptrCast(self)) != 0) {
            audio.sca_audio_destroy(h);
            return error.AudioStart;
        }
    }

    pub fn writeAudio(self: *AudioSink, samples: []const f32) !void {
        var i: usize = 0;
        while (i < samples.len) {
            i += self.ring.tryPush(samples[i..]);
            if (i < samples.len) {
                if (!self.running.load(.monotonic)) return; // shutting down
                _ = usleep(2000); // ~2 ms; the audio period is ~27 ms
            }
        }
        // Release the callback once a cushion exists, so playback starts on a full
        // buffer instead of underrunning while the device pulls ahead of the DSP.
        if (!self.primed.load(.monotonic) and self.ring.used() >= self.prime_frames)
            self.primed.store(true, .release);
    }

    pub fn finish(self: *AudioSink, io: std.Io) !void {
        _ = io;
        // let the device play out what's buffered before tearing down
        while (self.running.load(.monotonic) and !self.ring.isEmpty()) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        audio.sca_audio_destroy(self.handle);
    }
};

fn pullCb(ctx: ?*anyopaque, out: [*c]f32, frames: c_uint) callconv(.c) void {
    const self: *AudioSink = @ptrCast(@alignCast(ctx.?));
    const buf = out[0..frames];
    if (!self.primed.load(.acquire)) {
        @memset(buf, 0); // priming: clean silence, not counted as an underrun
        return;
    }
    const n = self.ring.pop(buf);
    for (buf[n..]) |*s| s.* = 0; // underrun -> silence
    if (n < frames) _ = self.underruns.fetchAdd(1, .monotonic);
}

/// Native sample rate of the default playback device, or 0 if none is available.
/// Lets the caller resample to the device rate instead of leaving an opaque
/// conversion to miniaudio's mixer.
pub fn defaultDeviceRate() u32 {
    return @intCast(audio.sca_audio_default_rate());
}

/// Output endpoint for the pipeline: a WAV file or the live audio device.
pub const Sink = union(enum) {
    wav: *WavSink,
    audio: *AudioSink,

    pub fn writeAudio(self: Sink, samples: []const f32) !void {
        switch (self) {
            .wav => |w| try w.writeAudio(samples),
            .audio => |a| try a.writeAudio(samples),
        }
    }
    pub fn finish(self: Sink, io: std.Io) !void {
        switch (self) {
            .wav => |w| try w.finish(io),
            .audio => |a| try a.finish(io),
        }
    }
    /// Count of output-starvation events (audio only); a WAV sink can't underrun.
    pub fn underruns(self: Sink) u64 {
        return switch (self) {
            .audio => |a| a.underruns.load(.monotonic),
            .wav => 0,
        };
    }
    /// Output-buffer occupancy (audio only), the live end-to-end latency cushion.
    pub fn ringFill(self: Sink) ?struct { used: usize, capacity: usize } {
        return switch (self) {
            .audio => |a| .{ .used = a.ring.used(), .capacity = a.ring.buf.len },
            .wav => null,
        };
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
