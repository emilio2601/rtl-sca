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
