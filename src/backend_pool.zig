const std = @import("std");
const mem = std.mem;

pub const HealthStatus = enum { healthy, unhealthy };

pub const BackendType = enum { llama_cpp, vllm, openai };

pub const RoutingStrategy = enum {
    round_robin,
    least_connections,
    weighted,
    random,
    latency_based,

    pub fn fromString(s: []const u8) ?RoutingStrategy {
        if (mem.eql(u8, s, "round_robin") or mem.eql(u8, s, "round-robin")) return .round_robin;
        if (mem.eql(u8, s, "least_connections") or mem.eql(u8, s, "least-connections")) return .least_connections;
        if (mem.eql(u8, s, "weighted")) return .weighted;
        if (mem.eql(u8, s, "random")) return .random;
        if (mem.eql(u8, s, "latency_based") or mem.eql(u8, s, "latency-based")) return .latency_based;
        return null;
    }
};

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
    weight: u32 = 1,
    avg_latency_us: u64 = 0,
    total_requests: u64 = 0,
    active_requests: u32 = 0,

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

    pub fn recordLatency(self: *BackendEntry, latency_us: u64) void {
        self.total_requests += 1;
        if (self.total_requests == 1) {
            self.avg_latency_us = latency_us;
        } else {
            self.avg_latency_us = self.avg_latency_us -% (self.avg_latency_us / self.total_requests) +% (latency_us / self.total_requests);
        }
    }

    pub fn beginRequest(self: *BackendEntry) void {
        self.active_requests += 1;
    }

    pub fn endRequest(self: *BackendEntry) void {
        if (self.active_requests > 0) {
            self.active_requests -= 1;
        }
    }

    pub fn connectionCount(self: BackendEntry) u32 {
        return self.active_requests + self.slots_processing;
    }
};

pub const BackendPool = struct {
    backends: std.ArrayList(BackendEntry),
    allocator: mem.Allocator,
    rr_index: u32,
    strategy: RoutingStrategy = .round_robin,
    rng_seed: u64 = 0,

    pub fn init(allocator: mem.Allocator) BackendPool {
        return .{
            .backends = .empty,
            .allocator = allocator,
            .rr_index = 0,
        };
    }

    pub fn initWithStrategy(allocator: mem.Allocator, strategy: RoutingStrategy) BackendPool {
        return .{
            .backends = .empty,
            .allocator = allocator,
            .rr_index = 0,
            .strategy = strategy,
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
        return switch (self.strategy) {
            .round_robin => self.selectRoundRobin(),
            .least_connections => self.selectLeastConnections(),
            .weighted => self.selectWeighted(),
            .random => self.selectRandom(),
            .latency_based => self.selectLatencyBased(),
        };
    }

    fn selectRoundRobin(self: *BackendPool) ?*BackendEntry {
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

    fn selectLeastConnections(self: *BackendPool) ?*BackendEntry {
        var best: ?*BackendEntry = null;
        var best_count: u32 = std.math.maxInt(u32);
        for (self.backends.items) |*entry| {
            if (entry.health != .healthy) continue;
            const count = entry.connectionCount();
            if (count < best_count) {
                best_count = count;
                best = entry;
            }
        }
        return best;
    }

    fn selectWeighted(self: *BackendPool) ?*BackendEntry {
        var total_weight: u64 = 0;
        for (self.backends.items) |*entry| {
            if (entry.health != .healthy) continue;
            total_weight += entry.weight;
        }
        if (total_weight == 0) return null;

        var seed = self.rng_seed;
        if (seed == 0) seed = @intCast(std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds());
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        self.rng_seed = seed;
        const choice = (seed >> 33) % total_weight;

        var running: u64 = 0;
        for (self.backends.items) |*entry| {
            if (entry.health != .healthy) continue;
            running += entry.weight;
            if (choice < running) return entry;
        }
        return null;
    }

    fn selectRandom(self: *BackendPool) ?*BackendEntry {
        var healthy_count: u32 = 0;
        for (self.backends.items) |entry| {
            if (entry.health == .healthy) healthy_count += 1;
        }
        if (healthy_count == 0) return null;

        var seed = self.rng_seed;
        if (seed == 0) seed = @intCast(std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds());
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        self.rng_seed = seed;
        const choice = (seed >> 33) % @as(u64, healthy_count);

        var seen: u32 = 0;
        for (self.backends.items) |*entry| {
            if (entry.health != .healthy) continue;
            if (seen == choice) return entry;
            seen += 1;
        }
        return null;
    }

    fn selectLatencyBased(self: *BackendPool) ?*BackendEntry {
        var best: ?*BackendEntry = null;
        var best_latency: u64 = std.math.maxInt(u64);
        for (self.backends.items) |*entry| {
            if (entry.health != .healthy) continue;
            const latency = if (entry.total_requests > 0) entry.avg_latency_us else 0;
            if (latency < best_latency) {
                best_latency = latency;
                best = entry;
            }
        }
        return best;
    }

    pub fn selectBackendFromGroup(self: *BackendPool, group_backends: []const BackendRef) ?*BackendEntry {
        if (group_backends.len == 0) return null;
        return switch (self.strategy) {
            .round_robin => self.selectRoundRobinFromGroup(group_backends),
            .least_connections => self.selectLeastConnectionsFromGroup(group_backends),
            .weighted => self.selectWeightedFromGroup(group_backends),
            .random => self.selectRandomFromGroup(group_backends),
            .latency_based => self.selectLatencyBasedFromGroup(group_backends),
        };
    }

    fn selectRoundRobinFromGroup(self: *BackendPool, group_backends: []const BackendRef) ?*BackendEntry {
        const len = group_backends.len;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const idx = self.rr_index % @as(u32, @intCast(len));
            self.rr_index += 1;
            const pool_idx = group_backends[idx].pool_index;
            if (pool_idx < self.backends.items.len) {
                const entry = &self.backends.items[pool_idx];
                if (entry.health == .healthy) return entry;
            }
        }
        return null;
    }

    fn selectLeastConnectionsFromGroup(self: *BackendPool, group_backends: []const BackendRef) ?*BackendEntry {
        var best: ?*BackendEntry = null;
        var best_count: u32 = std.math.maxInt(u32);
        for (group_backends) |ref| {
            if (ref.pool_index >= self.backends.items.len) continue;
            const entry = &self.backends.items[ref.pool_index];
            if (entry.health != .healthy) continue;
            const count = entry.connectionCount();
            if (count < best_count) {
                best_count = count;
                best = entry;
            }
        }
        return best;
    }

    fn selectWeightedFromGroup(self: *BackendPool, group_backends: []const BackendRef) ?*BackendEntry {
        var total_weight: u64 = 0;
        for (group_backends) |ref| {
            if (ref.pool_index >= self.backends.items.len) continue;
            const entry = &self.backends.items[ref.pool_index];
            if (entry.health != .healthy) continue;
            total_weight += entry.weight;
        }
        if (total_weight == 0) return null;

        var seed = self.rng_seed;
        if (seed == 0) seed = @intCast(std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds());
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        self.rng_seed = seed;
        const choice = (seed >> 33) % total_weight;

        var running: u64 = 0;
        for (group_backends) |ref| {
            if (ref.pool_index >= self.backends.items.len) continue;
            const entry = &self.backends.items[ref.pool_index];
            if (entry.health != .healthy) continue;
            running += entry.weight;
            if (choice < running) return entry;
        }
        return null;
    }

    fn selectRandomFromGroup(self: *BackendPool, group_backends: []const BackendRef) ?*BackendEntry {
        var healthy_count: u32 = 0;
        for (group_backends) |ref| {
            if (ref.pool_index >= self.backends.items.len) continue;
            const entry = &self.backends.items[ref.pool_index];
            if (entry.health == .healthy) healthy_count += 1;
        }
        if (healthy_count == 0) return null;

        var seed = self.rng_seed;
        if (seed == 0) seed = @intCast(std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds());
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        self.rng_seed = seed;
        const choice = (seed >> 33) % @as(u64, healthy_count);

        var seen: u32 = 0;
        for (group_backends) |ref| {
            if (ref.pool_index >= self.backends.items.len) continue;
            const entry = &self.backends.items[ref.pool_index];
            if (entry.health != .healthy) continue;
            if (seen == choice) return entry;
            seen += 1;
        }
        return null;
    }

    fn selectLatencyBasedFromGroup(self: *BackendPool, group_backends: []const BackendRef) ?*BackendEntry {
        var best: ?*BackendEntry = null;
        var best_latency: u64 = std.math.maxInt(u64);
        for (group_backends) |ref| {
            if (ref.pool_index >= self.backends.items.len) continue;
            const entry = &self.backends.items[ref.pool_index];
            if (entry.health != .healthy) continue;
            const latency = if (entry.total_requests > 0) entry.avg_latency_us else 0;
            if (latency < best_latency) {
                best_latency = latency;
                best = entry;
            }
        }
        return best;
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

test "RoutingStrategy.fromString parses all strategies" {
    try std.testing.expect(RoutingStrategy.fromString("round_robin") == .round_robin);
    try std.testing.expect(RoutingStrategy.fromString("round-robin") == .round_robin);
    try std.testing.expect(RoutingStrategy.fromString("least_connections") == .least_connections);
    try std.testing.expect(RoutingStrategy.fromString("least-connections") == .least_connections);
    try std.testing.expect(RoutingStrategy.fromString("weighted") == .weighted);
    try std.testing.expect(RoutingStrategy.fromString("random") == .random);
    try std.testing.expect(RoutingStrategy.fromString("latency_based") == .latency_based);
    try std.testing.expect(RoutingStrategy.fromString("latency-based") == .latency_based);
    try std.testing.expect(RoutingStrategy.fromString("invalid") == null);
}

test "BackendEntry weight defaults to 1" {
    const entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4" };
    try std.testing.expect(entry.weight == 1);
}

test "BackendEntry recordLatency updates avg_latency_us" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4" };
    try std.testing.expect(entry.avg_latency_us == 0);
    try std.testing.expect(entry.total_requests == 0);

    entry.recordLatency(1000);
    try std.testing.expect(entry.avg_latency_us == 1000);
    try std.testing.expect(entry.total_requests == 1);

    entry.recordLatency(3000);
    try std.testing.expect(entry.total_requests == 2);
}

test "BackendEntry beginRequest/endRequest track active_requests" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4" };
    try std.testing.expect(entry.active_requests == 0);
    entry.beginRequest();
    try std.testing.expect(entry.active_requests == 1);
    entry.beginRequest();
    try std.testing.expect(entry.active_requests == 2);
    entry.endRequest();
    try std.testing.expect(entry.active_requests == 1);
    entry.endRequest();
    try std.testing.expect(entry.active_requests == 0);
}

test "BackendEntry connectionCount includes active_requests and slots_processing" {
    var entry = BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .slots_processing = 2 };
    entry.active_requests = 3;
    try std.testing.expect(entry.connectionCount() == 5);
}

test "BackendPool initWithStrategy sets strategy" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .least_connections);
    defer pool.deinit();
    try std.testing.expect(pool.strategy == .least_connections);
}

test "BackendPool least_connections selects backend with fewest connections" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .least_connections);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .active_requests = 5 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .active_requests = 1 });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "gpt-4", .active_requests = 3 });

    const be = pool.selectBackend().?;
    try std.testing.expectEqualStrings("http://b:8081", be.address);
}

test "BackendPool least_connections skips unhealthy" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .least_connections);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy, .active_requests = 0 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .active_requests = 2 });

    const be = pool.selectBackend().?;
    try std.testing.expectEqualStrings("http://b:8081", be.address);
}

test "BackendPool weighted favors higher weight backends" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .weighted);
    defer pool.deinit();
    pool.rng_seed = 42;

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .weight = 1 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .weight = 9 });

    var b_count: u32 = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const be = pool.selectBackend().?;
        if (mem.eql(u8, be.id, "b")) b_count += 1;
    }
    try std.testing.expect(b_count > 60);
}

test "BackendPool random selects only healthy backends" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .random);
    defer pool.deinit();
    pool.rng_seed = 123;

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "gpt-4", .health = .unhealthy });

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const be = pool.selectBackend().?;
        try std.testing.expect(be.health == .healthy);
        try std.testing.expectEqualStrings("http://b:8081", be.address);
    }
}

test "BackendPool latency_based selects lowest latency backend" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .latency_based);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .avg_latency_us = 5000, .total_requests = 10 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .avg_latency_us = 1000, .total_requests = 10 });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "gpt-4", .avg_latency_us = 3000, .total_requests = 10 });

    const be = pool.selectBackend().?;
    try std.testing.expectEqualStrings("http://b:8081", be.address);
}

test "BackendPool latency_based prefers untried backends (zero latency = no data)" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .latency_based);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .avg_latency_us = 5000, .total_requests = 10 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .avg_latency_us = 0, .total_requests = 0 });

    const be = pool.selectBackend().?;
    try std.testing.expectEqualStrings("http://b:8081", be.address);
}

test "BackendPool selectBackendFromGroup routes by strategy" {
    var pool = BackendPool.initWithStrategy(std.testing.allocator, .least_connections);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .active_requests = 5 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .active_requests = 1 });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "llama3", .active_requests = 0 });

    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const be = pool.selectBackendFromGroup(&refs).?;
    try std.testing.expectEqualStrings("http://b:8081", be.address);
}

test "BackendPool selectBackendFromGroup returns null for empty group" {
    var pool = BackendPool.init(std.testing.allocator);
    defer pool.deinit();
    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });

    const refs = [_]BackendRef{};
    try std.testing.expect(pool.selectBackendFromGroup(&refs) == null);
}

test "BackendPool all strategies return null when all unhealthy" {
    inline for (.{ .round_robin, .least_connections, .weighted, .random, .latency_based }) |s| {
        var pool = BackendPool.initWithStrategy(std.testing.allocator, s);
        defer pool.deinit();
        pool.rng_seed = 1;
        try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy });
        try std.testing.expect(pool.selectBackend() == null);
    }
}
