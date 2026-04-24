const std = @import("std");
const mem = std.mem;

pub const HealthStatus = enum { healthy, unhealthy };

pub const BackendType = enum { llama_cpp, vllm, openai };

pub const BackendRef = struct {
    pool_index: usize,
};

pub const BackendEntry = struct {
    id: []const u8,
    address: []const u8,
    model: []const u8,
    backend_type: BackendType = .llama_cpp,
    health: HealthStatus = .healthy,
    consecutive_failures: u32 = 0,
    fail_threshold: u32 = 3,
    slots_idle: u32 = 0,
    slots_processing: u32 = 0,
    slots_total: u32 = 0,
    prefix_affinity: u64 = 0,
    prefix_affinity_updated_at_ms: i64 = 0,
    connect_timeout_ms: u32 = 5000,
    request_timeout_ms: u32 = 30000,

    pub const NO_AFFINITY: u64 = 0;

    pub fn defaultTimeouts(self: *BackendEntry) void {
        switch (self.backend_type) {
            .llama_cpp => {
                self.connect_timeout_ms = 5000;
                self.request_timeout_ms = 30000;
            },
            .vllm => {
                self.connect_timeout_ms = 10000;
                self.request_timeout_ms = 120000;
            },
            .openai => {
                self.connect_timeout_ms = 10000;
                self.request_timeout_ms = 60000;
            },
        }
    }

    pub fn isBusy(self: BackendEntry) bool {
        if (self.slots_total == 0) return false;
        return self.slots_processing >= self.slots_total;
    }

    pub fn hasFreeSlots(self: BackendEntry) bool {
        if (self.slots_total == 0) return true;
        return self.slots_idle > 0;
    }

    pub fn busynessRatio(self: BackendEntry) f32 {
        if (self.slots_total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.slots_processing)) / @as(f32, @floatFromInt(self.slots_total));
    }

    pub fn updateAffinity(self: *BackendEntry, hash: u64) void {
        self.prefix_affinity = hash;
    }

    pub fn updateAffinityWithTimestamp(self: *BackendEntry, hash: u64, now_ms: i64) void {
        self.prefix_affinity = hash;
        self.prefix_affinity_updated_at_ms = now_ms;
    }

    pub fn isAffinityExpired(self: BackendEntry, now_ms: i64, ttl_ms: u64) bool {
        if (self.prefix_affinity == NO_AFFINITY) return true;
        if (self.prefix_affinity_updated_at_ms == 0) return false;
        return (now_ms - self.prefix_affinity_updated_at_ms) > @as(i64, @intCast(ttl_ms));
    }

    pub fn recordSuccess(self: *BackendEntry) void {
        self.consecutive_failures = 0;
        self.health = .healthy;
    }

    pub fn recordFailure(self: *BackendEntry) void {
        self.consecutive_failures += 1;
        if (self.consecutive_failures >= self.fail_threshold) {
            self.health = .unhealthy;
        }
    }

    pub fn recordPassiveFailure(self: *BackendEntry) void {
        self.consecutive_failures += 1;
        if (self.consecutive_failures >= self.fail_threshold) {
            self.health = .unhealthy;
        }
    }
};

pub const BackendPool = struct {
    backends: std.ArrayList(BackendEntry),
    allocator: mem.Allocator,
    rr_index: u32,

    pub fn init(allocator: mem.Allocator) BackendPool {
        return .{
            .backends = .empty,
            .allocator = allocator,
            .rr_index = 0,
        };
    }

    pub fn deinit(self: *BackendPool) void {
        self.backends.deinit(self.allocator);
    }

    pub fn addBackend(self: *BackendPool, entry: BackendEntry) !void {
        try self.backends.append(self.allocator, entry);
    }

    pub fn selectBackend(self: *BackendPool) ?*BackendEntry {
        if (self.backends.items.len == 0) return null;
        const len = self.backends.items.len;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const idx = self.rr_index % @as(u32, @intCast(len));
            self.rr_index += 1;
            if (self.backends.items[idx].health == .healthy) {
                return &self.backends.items[idx];
            }
        }
        return null;
    }

    pub fn healthyCount(self: *BackendPool) usize {
        var count: usize = 0;
        for (self.backends.items) |b| {
            if (b.health == .healthy) count += 1;
        }
        return count;
    }
};

test "BackendPool selects backends round-robin" {
    var pool = BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "gpt-4" });

    const first = pool.selectBackend().?;
    const second = pool.selectBackend().?;
    const third = pool.selectBackend().?;
    const fourth = pool.selectBackend().?;

    try std.testing.expectEqualStrings("http://a:8081", first.address);
    try std.testing.expectEqualStrings("http://b:8081", second.address);
    try std.testing.expectEqualStrings("http://c:8081", third.address);
    try std.testing.expectEqualStrings("http://a:8081", fourth.address);
}

test "BackendPool returns null when empty" {
    var pool = BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expect(pool.selectBackend() == null);
}

test "BackendPool single backend always returns same" {
    var pool = BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "only", .address = "http://only:8081", .model = "default" });

    const a = pool.selectBackend().?;
    const b = pool.selectBackend().?;
    try std.testing.expectEqualStrings(a.address, b.address);
}

test "BackendPool skips unhealthy backends" {
    var pool = BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .health = .unhealthy });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "gpt-4" });

    var seen_a: bool = false;
    var seen_c: bool = false;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const be = pool.selectBackend().?;
        try std.testing.expect(be.health == .healthy);
        if (mem.eql(u8, be.id, "a")) seen_a = true;
        if (mem.eql(u8, be.id, "c")) seen_c = true;
    }
    try std.testing.expect(seen_a);
    try std.testing.expect(seen_c);
}

test "BackendPool returns null when all backends unhealthy" {
    var pool = BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy });

    try std.testing.expect(pool.selectBackend() == null);
}

test "BackendEntry recordFailure marks unhealthy after 3 consecutive failures" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4" };
    try std.testing.expect(entry.health == .healthy);
    try std.testing.expect(entry.consecutive_failures == 0);

    entry.recordFailure();
    try std.testing.expect(entry.health == .healthy);
    try std.testing.expect(entry.consecutive_failures == 1);

    entry.recordFailure();
    try std.testing.expect(entry.health == .healthy);
    try std.testing.expect(entry.consecutive_failures == 2);

    entry.recordFailure();
    try std.testing.expect(entry.health == .unhealthy);
    try std.testing.expect(entry.consecutive_failures == 3);
}

test "BackendEntry recordSuccess resets failures and marks healthy" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .health = .unhealthy, .consecutive_failures = 3 };

    entry.recordSuccess();
    try std.testing.expect(entry.health == .healthy);
    try std.testing.expect(entry.consecutive_failures == 0);
}

test "round-robin distributes evenly across 3 healthy backends" {
    var pool = BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "gpt-4" });

    var counts = [3]u32{ 0, 0, 0 };
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const be = pool.selectBackend().?;
        if (mem.eql(u8, be.id, "a")) counts[0] += 1;
        if (mem.eql(u8, be.id, "b")) counts[1] += 1;
        if (mem.eql(u8, be.id, "c")) counts[2] += 1;
    }
    try std.testing.expect(counts[0] == 10);
    try std.testing.expect(counts[1] == 10);
    try std.testing.expect(counts[2] == 10);
}

test "backend recovers to healthy after successful health check" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .health = .unhealthy, .consecutive_failures = 5 };
    entry.recordSuccess();
    try std.testing.expect(entry.health == .healthy);
    try std.testing.expect(entry.consecutive_failures == 0);
}

test "BackendEntry isBusy returns true when all slots are processing" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .slots_total = 4, .slots_processing = 4, .slots_idle = 0 };
    try std.testing.expect(entry.isBusy());

    entry.slots_processing = 3;
    try std.testing.expect(!entry.isBusy());
}

test "BackendEntry isBusy returns false when slots_total is zero" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .slots_total = 0 };
    try std.testing.expect(!entry.isBusy());
}

test "BackendEntry hasFreeSlots returns true when idle slots exist" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .slots_total = 4, .slots_idle = 2 };
    try std.testing.expect(entry.hasFreeSlots());

    entry.slots_idle = 0;
    try std.testing.expect(!entry.hasFreeSlots());
}

test "BackendEntry hasFreeSlots returns true when slots_total is zero" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .slots_total = 0 };
    try std.testing.expect(entry.hasFreeSlots());
}

test "BackendEntry defaults to llama_cpp backend type" {
    const entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4" };
    try std.testing.expect(entry.backend_type == .llama_cpp);
}

test "BackendEntry can be configured with vllm backend type" {
    const entry = BackendEntry{ .id = "vllm-1", .address = "http://vllm:8000", .model = "llama3", .backend_type = .vllm };
    try std.testing.expect(entry.backend_type == .vllm);
}

test "BackendEntry can be configured with openai backend type" {
    const entry = BackendEntry{ .id = "openai-1", .address = "https://api.openai.com", .model = "gpt-4", .backend_type = .openai };
    try std.testing.expect(entry.backend_type == .openai);
}

test "BackendEntry defaultTimeouts sets llama_cpp timeouts" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4" };
    entry.defaultTimeouts();
    try std.testing.expect(entry.connect_timeout_ms == 5000);
    try std.testing.expect(entry.request_timeout_ms == 30000);
}

test "BackendEntry defaultTimeouts sets vllm timeouts" {
    var entry = BackendEntry{ .id = "test", .address = "http://vllm:8000", .model = "llama3", .backend_type = .vllm };
    entry.defaultTimeouts();
    try std.testing.expect(entry.connect_timeout_ms == 10000);
    try std.testing.expect(entry.request_timeout_ms == 120000);
}

test "BackendEntry defaultTimeouts sets openai timeouts" {
    var entry = BackendEntry{ .id = "test", .address = "https://api.openai.com", .model = "gpt-4", .backend_type = .openai };
    entry.defaultTimeouts();
    try std.testing.expect(entry.connect_timeout_ms == 10000);
    try std.testing.expect(entry.request_timeout_ms == 60000);
}
