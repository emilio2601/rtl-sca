const std = @import("std");

pub const Running = std.atomic.Value(bool);

/// Lock-free single-producer / single-consumer ring of f32 audio samples.
/// The producer (DSP thread) calls `push`; the consumer (miniaudio's audio
/// callback thread) calls `pop`. Indices are free-running counters masked on
/// access, so all `buf.len` slots are usable. Capacity must be a power of two.
pub const Ring = struct {
    buf: []f32,
    mask: usize,
    head: std.atomic.Value(usize), // total samples popped (consumer owns)
    tail: std.atomic.Value(usize), // total samples pushed (producer owns)

    pub fn init(buf: []f32) Ring {
        std.debug.assert(std.math.isPowerOfTwo(buf.len));
        return .{ .buf = buf, .mask = buf.len - 1, .head = .init(0), .tail = .init(0) };
    }

    pub fn used(self: *const Ring) usize {
        return self.tail.load(.acquire) -% self.head.load(.acquire);
    }

    pub fn isEmpty(self: *const Ring) bool {
        return self.used() == 0;
    }

    /// Consumer: pop up to `out.len` samples, return the count taken.
    pub fn pop(self: *Ring, out: []f32) usize {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        const n = @min(t -% h, out.len);
        for (0..n) |i| out[i] = self.buf[(h +% i) & self.mask];
        self.head.store(h +% n, .release);
        return n;
    }

    /// Producer: write up to `samples.len`, return the count actually written
    /// (less than len when the ring is full). Non-blocking; the caller paces.
    pub fn tryPush(self: *Ring, samples: []const f32) usize {
        const t = self.tail.load(.monotonic);
        const free = self.buf.len - (t -% self.head.load(.acquire));
        const n = @min(free, samples.len);
        for (0..n) |k| self.buf[(t +% k) & self.mask] = samples[k];
        if (n > 0) self.tail.store(t +% n, .release);
        return n;
    }
};

/// Lock-free single-producer / single-consumer ring of raw bytes, used to hand
/// IQ from a USB reader thread (producer, in librtlsdr's async callback) to the
/// DSP thread (consumer). Unlike `Ring`, a full ring does not block the producer
/// — the callback cannot stall — so the overflow is *counted* in `dropped`
/// instead. Capacity must be a power of two.
pub const ByteRing = struct {
    buf: []u8,
    mask: usize,
    head: std.atomic.Value(usize), // total bytes popped (consumer owns)
    tail: std.atomic.Value(usize), // total bytes pushed (producer owns)
    rx: std.atomic.Value(u64), // total bytes offered by the producer (diagnostics)
    dropped: std.atomic.Value(u64), // bytes discarded because the ring was full
    high_water: std.atomic.Value(usize), // peak bytes queued (diagnostics)

    pub fn init(buf: []u8) ByteRing {
        std.debug.assert(std.math.isPowerOfTwo(buf.len));
        return .{
            .buf = buf,
            .mask = buf.len - 1,
            .head = .init(0),
            .tail = .init(0),
            .rx = .init(0),
            .dropped = .init(0),
            .high_water = .init(0),
        };
    }

    pub fn used(self: *const ByteRing) usize {
        return self.tail.load(.acquire) -% self.head.load(.acquire);
    }

    pub fn isEmpty(self: *const ByteRing) bool {
        return self.used() == 0;
    }

    /// Producer: enqueue as much of `src` as fits. Bytes that don't fit are
    /// counted as `dropped` — an overflow means the consumer (DSP) fell behind.
    pub fn push(self: *ByteRing, src: []const u8) void {
        const t = self.tail.load(.monotonic);
        const queued = t -% self.head.load(.acquire);
        const n = @min(self.buf.len - queued, src.len);
        for (0..n) |k| self.buf[(t +% k) & self.mask] = src[k];
        if (n > 0) self.tail.store(t +% n, .release);
        _ = self.rx.fetchAdd(src.len, .monotonic);
        if (n < src.len) _ = self.dropped.fetchAdd(src.len - n, .monotonic);
        const peak = queued + n;
        if (peak > self.high_water.load(.monotonic)) self.high_water.store(peak, .monotonic);
    }

    /// Consumer: pop up to `out.len` bytes, return the count taken.
    pub fn pop(self: *ByteRing, out: []u8) usize {
        const h = self.head.load(.monotonic);
        const t = self.tail.load(.acquire);
        const n = @min(t -% h, out.len);
        for (0..n) |i| out[i] = self.buf[(h +% i) & self.mask];
        self.head.store(h +% n, .release);
        return n;
    }
};

const testing = std.testing;

test "tryPush/pop within capacity" {
    var mem: [8]f32 = undefined;
    var r = Ring.init(&mem);
    try testing.expect(r.isEmpty());
    try testing.expectEqual(@as(usize, 4), r.tryPush(&.{ 1, 2, 3, 4 }));
    try testing.expectEqual(@as(usize, 4), r.used());
    var out: [4]f32 = undefined;
    try testing.expectEqual(@as(usize, 4), r.pop(&out));
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, &out);
    try testing.expect(r.isEmpty());
}

test "tryPush reports partial when full" {
    var mem: [4]f32 = undefined;
    var r = Ring.init(&mem);
    try testing.expectEqual(@as(usize, 4), r.tryPush(&.{ 1, 2, 3, 4, 5, 6 })); // only 4 fit
    try testing.expectEqual(@as(usize, 0), r.tryPush(&.{9})); // full
}

test "wrap-around over many small push/pop cycles" {
    var mem: [8]f32 = undefined;
    var r = Ring.init(&mem);
    var next: f32 = 0;
    var expect: f32 = 0;
    var out: [3]f32 = undefined;
    for (0..1000) |_| {
        try testing.expectEqual(@as(usize, 3), r.tryPush(&.{ next, next + 1, next + 2 }));
        next += 3;
        try testing.expectEqual(@as(usize, 3), r.pop(&out));
        try testing.expectEqual(expect, out[0]);
        expect += 3;
    }
}

fn consumer(r: *Ring, dst: []f32, run: *const Running) void {
    var got: usize = 0;
    var tmp: [64]f32 = undefined;
    while (got < dst.len) {
        const n = r.pop(&tmp);
        if (n == 0) {
            if (!run.load(.monotonic) and r.isEmpty()) break;
            std.Thread.yield() catch std.atomic.spinLoopHint();
            continue;
        }
        @memcpy(dst[got .. got + n], tmp[0..n]);
        got += n;
    }
}

test "ByteRing push/pop and overflow accounting" {
    var mem: [8]u8 = undefined;
    var r = ByteRing.init(&mem);
    r.push(&.{ 1, 2, 3, 4, 5, 6 });
    try testing.expectEqual(@as(usize, 6), r.used());
    try testing.expectEqual(@as(u64, 0), r.dropped.load(.monotonic));

    r.push(&.{ 7, 8, 9, 10 }); // only 2 of 4 fit (ring holds 8)
    try testing.expectEqual(@as(usize, 8), r.used());
    try testing.expectEqual(@as(u64, 2), r.dropped.load(.monotonic));
    try testing.expectEqual(@as(u64, 10), r.rx.load(.monotonic));
    try testing.expectEqual(@as(usize, 8), r.high_water.load(.monotonic));

    var out: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), r.pop(&out));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &out);
}

test "SPSC: spawned consumer receives the exact stream in order" {
    const N = 100_000;
    var mem: [1024]f32 = undefined;
    var r = Ring.init(&mem);
    var run = Running.init(true);

    const dst = try testing.allocator.alloc(f32, N);
    defer testing.allocator.free(dst);

    const t = try std.Thread.spawn(.{}, consumer, .{ &r, dst, &run });
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const s: f32 = @floatFromInt(i & 0xffff);
        while (r.tryPush(&.{s}) == 0) std.Thread.yield() catch std.atomic.spinLoopHint();
    }
    run.store(false, .release);
    t.join();

    for (dst, 0..) |v, k| try testing.expectEqual(@as(f32, @floatFromInt(k & 0xffff)), v);
}
