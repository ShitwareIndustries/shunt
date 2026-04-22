const std = @import("std");
const mem = std.mem;

pub const TTFT_RING_CAPACITY: usize = 1000;

pub const Metrics = struct {
    mutex: std.Io.Mutex,
    cache_hits_total: u64,
    cache_misses_total: u64,
    requests_total: u64,
    ttft_cache_hit_samples: [TTFT_RING_CAPACITY]u64,
    ttft_cache_hit_count: usize,
    ttft_cache_hit_write_idx: usize,
    ttft_cache_miss_samples: [TTFT_RING_CAPACITY]u64,
    ttft_cache_miss_count: usize,
    ttft_cache_miss_write_idx: usize,

    pub fn init() Metrics {
        return .{
            .mutex = .init,
            .cache_hits_total = 0,
            .cache_misses_total = 0,
            .requests_total = 0,
            .ttft_cache_hit_samples = @splat(0),
            .ttft_cache_hit_count = 0,
            .ttft_cache_hit_write_idx = 0,
            .ttft_cache_miss_samples = @splat(0),
            .ttft_cache_miss_count = 0,
            .ttft_cache_miss_write_idx = 0,
        };
    }

    pub fn recordRequest(self: *Metrics, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.requests_total += 1;
    }

    pub fn recordCacheHit(self: *Metrics, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cache_hits_total += 1;
    }

    pub fn recordCacheMiss(self: *Metrics, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cache_misses_total += 1;
    }

    pub fn recordTTFTCacheHit(self: *Metrics, io: std.Io, ttft_us: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.ttft_cache_hit_samples[self.ttft_cache_hit_write_idx] = ttft_us;
        self.ttft_cache_hit_write_idx = (self.ttft_cache_hit_write_idx + 1) % TTFT_RING_CAPACITY;
        if (self.ttft_cache_hit_count < TTFT_RING_CAPACITY) {
            self.ttft_cache_hit_count += 1;
        }
    }

    pub fn recordTTFTCacheMiss(self: *Metrics, io: std.Io, ttft_us: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.ttft_cache_miss_samples[self.ttft_cache_miss_write_idx] = ttft_us;
        self.ttft_cache_miss_write_idx = (self.ttft_cache_miss_write_idx + 1) % TTFT_RING_CAPACITY;
        if (self.ttft_cache_miss_count < TTFT_RING_CAPACITY) {
            self.ttft_cache_miss_count += 1;
        }
    }

    pub fn cacheHitRate(self: *Metrics, io: std.Io) f64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return hitRateUnlocked(self.cache_hits_total, self.cache_misses_total);
    }

    pub fn ttftCacheHitAvgUs(self: *Metrics, io: std.Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return ringBufferAvg(self.ttft_cache_hit_samples, self.ttft_cache_hit_count, self.ttft_cache_hit_write_idx);
    }

    pub fn ttftCacheMissAvgUs(self: *Metrics, io: std.Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return ringBufferAvg(self.ttft_cache_miss_samples, self.ttft_cache_miss_count, self.ttft_cache_miss_write_idx);
    }

    pub fn snapshot(self: *Metrics, io: std.Io) Snapshot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{
            .cache_hits_total = self.cache_hits_total,
            .cache_misses_total = self.cache_misses_total,
            .requests_total = self.requests_total,
            .cache_hit_rate = hitRateUnlocked(self.cache_hits_total, self.cache_misses_total),
            .ttft_cache_hit_avg_us = ringBufferAvg(self.ttft_cache_hit_samples, self.ttft_cache_hit_count, self.ttft_cache_hit_write_idx),
            .ttft_cache_miss_avg_us = ringBufferAvg(self.ttft_cache_miss_samples, self.ttft_cache_miss_count, self.ttft_cache_miss_write_idx),
        };
    }

    pub fn reset(self: *Metrics, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cache_hits_total = 0;
        self.cache_misses_total = 0;
        self.requests_total = 0;
        self.ttft_cache_hit_samples = @splat(0);
        self.ttft_cache_hit_count = 0;
        self.ttft_cache_hit_write_idx = 0;
        self.ttft_cache_miss_samples = @splat(0);
        self.ttft_cache_miss_count = 0;
        self.ttft_cache_miss_write_idx = 0;
    }

    pub fn formatPrometheus(self: *Metrics, allocator: mem.Allocator, io: std.Io) ![]u8 {
        const snap = self.snapshot(io);
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        try buf.print(allocator, "shunt_cache_hits_total {d}\n", .{snap.cache_hits_total});
        try buf.print(allocator, "shunt_cache_misses_total {d}\n", .{snap.cache_misses_total});
        try buf.print(allocator, "shunt_requests_total {d}\n", .{snap.requests_total});
        try buf.print(allocator, "shunt_cache_hit_rate {d:.2}\n", .{snap.cache_hit_rate});
        try buf.print(allocator, "shunt_ttft_cache_hit_avg_us {d}\n", .{snap.ttft_cache_hit_avg_us});
        try buf.print(allocator, "shunt_ttft_cache_miss_avg_us {d}\n", .{snap.ttft_cache_miss_avg_us});

        return try buf.toOwnedSlice(allocator);
    }

    fn hitRateUnlocked(hits: u64, misses: u64) f64 {
        const total = hits + misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
    }

    fn ringBufferAvg(samples: [TTFT_RING_CAPACITY]u64, count: usize, write_idx: usize) u64 {
        if (count == 0) return 0;
        var sum: u64 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const idx = if (count >= TTFT_RING_CAPACITY)
                (write_idx + i) % TTFT_RING_CAPACITY
            else
                i;
            sum += samples[idx];
        }
        return sum / count;
    }
};

pub const Snapshot = struct {
    cache_hits_total: u64,
    cache_misses_total: u64,
    requests_total: u64,
    cache_hit_rate: f64,
    ttft_cache_hit_avg_us: u64,
    ttft_cache_miss_avg_us: u64,
};

test "Metrics init has zero counters" {
    const m = Metrics.init();
    try std.testing.expect(m.cache_hits_total == 0);
    try std.testing.expect(m.cache_misses_total == 0);
    try std.testing.expect(m.requests_total == 0);
    try std.testing.expect(m.ttft_cache_hit_count == 0);
    try std.testing.expect(m.ttft_cache_miss_count == 0);
}

test "Metrics recordRequest increments requests_total" {
    var m = Metrics.init();
    m.recordRequest(std.testing.io);
    m.recordRequest(std.testing.io);
    m.recordRequest(std.testing.io);
    try std.testing.expect(m.requests_total == 3);
}

test "Metrics recordCacheHit increments cache_hits_total" {
    var m = Metrics.init();
    m.recordCacheHit(std.testing.io);
    m.recordCacheHit(std.testing.io);
    try std.testing.expect(m.cache_hits_total == 2);
}

test "Metrics recordCacheMiss increments cache_misses_total" {
    var m = Metrics.init();
    m.recordCacheMiss(std.testing.io);
    try std.testing.expect(m.cache_misses_total == 1);
}

test "Metrics cacheHitRate computes correctly" {
    var m = Metrics.init();
    m.recordCacheHit(std.testing.io);
    m.recordCacheHit(std.testing.io);
    m.recordCacheMiss(std.testing.io);
    const rate = m.cacheHitRate(std.testing.io);
    try std.testing.expect(@abs(rate - 0.6666666666666666) < 0.001);
}

test "Metrics cacheHitRate returns 0 when no requests" {
    var m = Metrics.init();
    try std.testing.expect(m.cacheHitRate(std.testing.io) == 0.0);
}

test "Metrics recordTTFTCacheHit stores samples in ring buffer" {
    var m = Metrics.init();
    m.recordTTFTCacheHit(std.testing.io, 100);
    m.recordTTFTCacheHit(std.testing.io, 200);
    m.recordTTFTCacheHit(std.testing.io, 300);
    try std.testing.expect(m.ttft_cache_hit_count == 3);
    try std.testing.expect(m.ttft_cache_hit_samples[0] == 100);
    try std.testing.expect(m.ttft_cache_hit_samples[1] == 200);
    try std.testing.expect(m.ttft_cache_hit_samples[2] == 300);
}

test "Metrics recordTTFTCacheMiss stores samples in ring buffer" {
    var m = Metrics.init();
    m.recordTTFTCacheMiss(std.testing.io, 500);
    m.recordTTFTCacheMiss(std.testing.io, 600);
    try std.testing.expect(m.ttft_cache_miss_count == 2);
    try std.testing.expect(m.ttft_cache_miss_samples[0] == 500);
    try std.testing.expect(m.ttft_cache_miss_samples[1] == 600);
}

test "Metrics TTFT ring buffer overwrites oldest at capacity" {
    var m = Metrics.init();
    var i: usize = 0;
    while (i < TTFT_RING_CAPACITY + 10) : (i += 1) {
        m.recordTTFTCacheHit(std.testing.io, @intCast(i + 1));
    }
    try std.testing.expect(m.ttft_cache_hit_count == TTFT_RING_CAPACITY);
    try std.testing.expect(m.ttft_cache_hit_write_idx == 10);
    try std.testing.expect(m.ttft_cache_hit_samples[0] == TTFT_RING_CAPACITY + 1);
}

test "Metrics ttftCacheHitAvgUs computes average correctly" {
    var m = Metrics.init();
    m.recordTTFTCacheHit(std.testing.io, 100);
    m.recordTTFTCacheHit(std.testing.io, 200);
    m.recordTTFTCacheHit(std.testing.io, 300);
    const avg = m.ttftCacheHitAvgUs(std.testing.io);
    try std.testing.expect(avg == 200);
}

test "Metrics ttftCacheMissAvgUs returns 0 with no samples" {
    var m = Metrics.init();
    try std.testing.expect(m.ttftCacheMissAvgUs(std.testing.io) == 0);
}

test "Metrics reset clears all counters and ring buffers" {
    var m = Metrics.init();
    m.recordRequest(std.testing.io);
    m.recordCacheHit(std.testing.io);
    m.recordCacheMiss(std.testing.io);
    m.recordTTFTCacheHit(std.testing.io, 100);
    m.recordTTFTCacheMiss(std.testing.io, 200);
    m.reset(std.testing.io);
    try std.testing.expect(m.requests_total == 0);
    try std.testing.expect(m.cache_hits_total == 0);
    try std.testing.expect(m.cache_misses_total == 0);
    try std.testing.expect(m.ttft_cache_hit_count == 0);
    try std.testing.expect(m.ttft_cache_miss_count == 0);
}

test "Metrics formatPrometheus returns valid exposition format" {
    var m = Metrics.init();
    m.recordCacheHit(std.testing.io);
    m.recordCacheHit(std.testing.io);
    m.recordCacheMiss(std.testing.io);
    m.recordRequest(std.testing.io);
    m.recordRequest(std.testing.io);
    m.recordRequest(std.testing.io);
    m.recordTTFTCacheHit(std.testing.io, 150);
    m.recordTTFTCacheMiss(std.testing.io, 400);

    const body = try m.formatPrometheus(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(body);

    const text = std.mem.sliceTo(body, 0);
    _ = text;
    try std.testing.expect(std.mem.indexOf(u8, body, "shunt_cache_hits_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "shunt_cache_misses_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "shunt_requests_total 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "shunt_cache_hit_rate") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "shunt_ttft_cache_hit_avg_us 150") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "shunt_ttft_cache_miss_avg_us 400") != null);
}

test "ringBufferAvg handles wrapped ring buffer" {
    var samples: [TTFT_RING_CAPACITY]u64 = @splat(0);
    samples[0] = 1000;
    samples[1] = 2000;
    const avg = Metrics.ringBufferAvg(samples, 2, 0);
    try std.testing.expect(avg == 1500);
}

test "Snapshot captures consistent state" {
    var m = Metrics.init();
    m.recordCacheHit(std.testing.io);
    m.recordCacheHit(std.testing.io);
    m.recordCacheMiss(std.testing.io);
    m.recordRequest(std.testing.io);
    m.recordTTFTCacheHit(std.testing.io, 100);
    m.recordTTFTCacheMiss(std.testing.io, 300);

    const snap = m.snapshot(std.testing.io);
    try std.testing.expect(snap.cache_hits_total == 2);
    try std.testing.expect(snap.cache_misses_total == 1);
    try std.testing.expect(snap.requests_total == 1);
    try std.testing.expect(@abs(snap.cache_hit_rate - 0.6666666666666666) < 0.001);
    try std.testing.expect(snap.ttft_cache_hit_avg_us == 100);
    try std.testing.expect(snap.ttft_cache_miss_avg_us == 300);
}
