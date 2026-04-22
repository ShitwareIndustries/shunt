const std = @import("std");
const mem = std.mem;
const json = std.json;
const backend_pool = @import("backend_pool");

pub const BackendRef = backend_pool.BackendRef;

pub fn buildMetricsResponse(allocator: mem.Allocator, metrics: CacheMetrics) ![]u8 {
    const response = .{
        .cache_hits = metrics.hits,
        .cache_misses = metrics.misses,
        .cache_hit_rate = metrics.hitRate(),
    };
    return json.Stringify.valueAlloc(allocator, response, .{});
}

pub const CacheMetrics = struct {
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn hitRate(self: CacheMetrics) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn recordHit(self: *CacheMetrics) void {
        self.hits += 1;
    }

    pub fn recordMiss(self: *CacheMetrics) void {
        self.misses += 1;
    }

    pub fn reset(self: *CacheMetrics) void {
        self.hits = 0;
        self.misses = 0;
    }
};

pub fn fnv1a64(input: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (input) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

pub fn extractSystemPrompt(allocator: mem.Allocator, body: []const u8) !?[]const u8 {
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const messages = parsed.value.object.get("messages") orelse return null;
    if (messages != .array) return null;

    for (messages.array.items) |msg| {
        if (msg == .object) {
            const role = msg.object.get("role") orelse continue;
            if (role == .string and mem.eql(u8, role.string, "system")) {
                const content = msg.object.get("content") orelse continue;
                if (content == .string) {
                    return try allocator.dupe(u8, content.string);
                }
            }
        }
    }
    return null;
}

pub fn extractSystemPromptAlloc(allocator: mem.Allocator, body: []const u8) !?[]const u8 {
    return extractSystemPrompt(allocator, body);
}

pub const CacheRouter = struct {
    metrics: CacheMetrics = .{},
    cache_ttl_ms: u64 = 300000,
    disabled: bool = false,

    pub fn selectBackend(
        self: *CacheRouter,
        pool: *backend_pool.BackendPool,
        group_backends: []const BackendRef,
        prefix_hash: u64,
        now_ms: i64,
    ) ?*backend_pool.BackendEntry {
        if (self.disabled) return null;
        if (group_backends.len == 0) return null;

        var affinity_match: ?*backend_pool.BackendEntry = null;
        var best_ratio: f32 = 2.0;
        var least_busy: ?*backend_pool.BackendEntry = null;

        for (group_backends) |ref| {
            if (ref.pool_index >= pool.backends.items.len) continue;
            const entry = &pool.backends.items[ref.pool_index];
            if (entry.health != .healthy) continue;

            if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY and
                entry.prefix_affinity == prefix_hash and
                !entry.isAffinityExpired(now_ms, self.cache_ttl_ms) and
                entry.hasFreeSlots())
            {
                if (affinity_match == null) {
                    affinity_match = entry;
                }
            }

            const ratio = entry.busynessRatio();
            if (ratio < best_ratio) {
                best_ratio = ratio;
                least_busy = entry;
            }
        }

        if (affinity_match != null) {
            self.metrics.recordHit();
            return affinity_match;
        }
        if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY) {
            self.metrics.recordMiss();
        }
        return least_busy;
    }

    pub fn selectBackendNoTime(
        self: *CacheRouter,
        pool: *backend_pool.BackendPool,
        group_backends: []const BackendRef,
        prefix_hash: u64,
    ) ?*backend_pool.BackendEntry {
        if (self.disabled) return null;
        if (group_backends.len == 0) return null;

        var affinity_match: ?*backend_pool.BackendEntry = null;
        var best_ratio: f32 = 2.0;
        var least_busy: ?*backend_pool.BackendEntry = null;

        for (group_backends) |ref| {
            if (ref.pool_index >= pool.backends.items.len) continue;
            const entry = &pool.backends.items[ref.pool_index];
            if (entry.health != .healthy) continue;

            if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY and
                entry.prefix_affinity == prefix_hash and
                entry.hasFreeSlots())
            {
                if (affinity_match == null) {
                    affinity_match = entry;
                }
            }

            const ratio = entry.busynessRatio();
            if (ratio < best_ratio) {
                best_ratio = ratio;
                least_busy = entry;
            }
        }

        if (affinity_match != null) {
            self.metrics.recordHit();
            return affinity_match;
        }
        if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY) {
            self.metrics.recordMiss();
        }
        return least_busy;
    }
};

test "fnv1a64 produces consistent hashes" {
    const h1 = fnv1a64("hello");
    const h2 = fnv1a64("hello");
    try std.testing.expect(h1 == h2);
}

test "fnv1a64 produces different hashes for different inputs" {
    const h1 = fnv1a64("hello");
    const h2 = fnv1a64("world");
    try std.testing.expect(h1 != h2);
}

test "fnv1a64 returns non-zero for non-empty input" {
    const h = fnv1a64("system prompt");
    try std.testing.expect(h != 0);
}

test "extractSystemPrompt finds system message content" {
    const body =
        \\{"model":"gpt-4","messages":[{"role":"system","content":"You are helpful"},{"role":"user","content":"hi"}]}
    ;
    const prompt = try extractSystemPrompt(std.testing.allocator, body);
    try std.testing.expect(prompt != null);
    defer std.testing.allocator.free(prompt.?);
    try std.testing.expectEqualStrings("You are helpful", prompt.?);
}

test "extractSystemPrompt returns null when no system message" {
    const body =
        \\{"model":"gpt-4","messages":[{"role":"user","content":"hi"}]}
    ;
    const prompt = try extractSystemPrompt(std.testing.allocator, body);
    try std.testing.expect(prompt == null);
}

test "extractSystemPrompt returns null for invalid JSON" {
    const prompt = try extractSystemPrompt(std.testing.allocator, "not json");
    try std.testing.expect(prompt == null);
}

test "CacheRouter selects backend with matching affinity" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4, .prefix_affinity = fnv1a64("You are helpful") });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4, .prefix_affinity = fnv1a64("Different prompt") });

    var router = CacheRouter{};
    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");
    const selected = router.selectBackendNoTime(&pool, &refs, hash);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("http://a:8081", selected.?.address);
}

test "CacheRouter falls back to least-busy when no affinity match" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 1, .slots_processing = 3, .slots_total = 4, .prefix_affinity = fnv1a64("Other prompt") });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 3, .slots_processing = 1, .slots_total = 4, .prefix_affinity = fnv1a64("Another prompt") });

    var router = CacheRouter{};
    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("New prompt");
    const selected = router.selectBackendNoTime(&pool, &refs, hash);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("http://b:8081", selected.?.address);
}

test "CacheRouter falls back to least-busy when affinity match is full" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 0, .slots_processing = 4, .slots_total = 4, .prefix_affinity = fnv1a64("You are helpful") });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 2, .slots_processing = 2, .slots_total = 4, .prefix_affinity = 0 });

    var router = CacheRouter{};
    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");
    const selected = router.selectBackendNoTime(&pool, &refs, hash);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("http://b:8081", selected.?.address);
}

test "CacheRouter two requests with same prefix route to same backend" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4 });

    var router = CacheRouter{};
    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");

    const first = router.selectBackendNoTime(&pool, &refs, hash).?;
    first.updateAffinity(hash);

    const second = router.selectBackendNoTime(&pool, &refs, hash).?;
    try std.testing.expectEqualStrings(first.address, second.address);
}

test "CacheRouter returns null when all backends unhealthy" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy });

    var router = CacheRouter{};
    const refs = [_]BackendRef{.{ .pool_index = 0 }};
    const hash = fnv1a64("test");
    try std.testing.expect(router.selectBackendNoTime(&pool, &refs, hash) == null);
}

test "CacheRouter returns null for empty backend group" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    var router = CacheRouter{};
    const refs = [_]BackendRef{};
    const hash = fnv1a64("test");
    try std.testing.expect(router.selectBackendNoTime(&pool, &refs, hash) == null);
}

test "CacheRouter prefers affinity match over least-busy" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 1, .slots_processing = 3, .slots_total = 4, .prefix_affinity = fnv1a64("You are helpful") });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 4, .slots_processing = 0, .slots_total = 4, .prefix_affinity = 0 });

    var router = CacheRouter{};
    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");
    const selected = router.selectBackendNoTime(&pool, &refs, hash).?;
    try std.testing.expectEqualStrings("http://a:8081", selected.address);
}

test "routing decision completes in under 1ms" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try pool.addBackend(.{
            .id = "backend-?",
            .address = "http://backend:8081",
            .model = "gpt-4",
            .slots_idle = 2,
            .slots_total = 4,
            .prefix_affinity = if (i % 3 == 0) fnv1a64("prompt-A") else if (i % 3 == 1) fnv1a64("prompt-B") else 0,
        });
    }

    var refs = std.ArrayList(BackendRef).empty;
    defer refs.deinit(std.testing.allocator);
    i = 0;
    while (i < 20) : (i += 1) {
        try refs.append(std.testing.allocator, .{ .pool_index = i });
    }

    const hash = fnv1a64("prompt-A");

    var router = CacheRouter{};

    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    var iter: usize = 0;
    while (iter < 10000) : (iter += 1) {
        _ = router.selectBackendNoTime(&pool, refs.items, hash);
    }
    const end = std.Io.Timestamp.now(std.testing.io, .awake);

    const elapsed_ns = end.toNanoseconds() - start.toNanoseconds();
    const per_decision_ns: u64 = @intCast(@divTrunc(elapsed_ns, 10000));
    const per_decision_us: u64 = @divTrunc(per_decision_ns, 1000);

    try std.testing.expect(per_decision_us < 1000);
}

test "CacheRouter TTL expires stale affinity entries" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    const hash = fnv1a64("You are helpful");
    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 1, .slots_processing = 3, .slots_total = 4, .prefix_affinity = hash, .prefix_affinity_updated_at_ms = 1000 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 4, .slots_processing = 0, .slots_total = 4, .prefix_affinity = 0 });

    var router = CacheRouter{ .cache_ttl_ms = 5000 };
    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };

    const selected = router.selectBackend(&pool, &refs, hash, 7000).?;
    try std.testing.expectEqualStrings("http://b:8081", selected.address);
}

test "CacheRouter TTL keeps fresh affinity entries" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    const hash = fnv1a64("You are helpful");
    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 1, .slots_processing = 3, .slots_total = 4, .prefix_affinity = hash, .prefix_affinity_updated_at_ms = 3000 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 4, .slots_processing = 0, .slots_total = 4, .prefix_affinity = 0 });

    var router = CacheRouter{ .cache_ttl_ms = 5000 };
    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };

    const selected = router.selectBackend(&pool, &refs, hash, 7000).?;
    try std.testing.expectEqualStrings("http://a:8081", selected.address);
}

test "CacheMetrics tracks hits and misses" {
    var metrics = CacheMetrics{};
    try std.testing.expect(metrics.hits == 0);
    try std.testing.expect(metrics.misses == 0);

    metrics.recordHit();
    metrics.recordHit();
    metrics.recordMiss();
    try std.testing.expect(metrics.hits == 2);
    try std.testing.expect(metrics.misses == 1);
    try std.testing.expect(metrics.hitRate() > 0.0);
}

test "CacheMetrics hitRate returns 0 when no requests" {
    var metrics = CacheMetrics{};
    try std.testing.expect(metrics.hitRate() == 0.0);
}

test "CacheMetrics reset clears counters" {
    var metrics = CacheMetrics{};
    metrics.recordHit();
    metrics.recordMiss();
    metrics.reset();
    try std.testing.expect(metrics.hits == 0);
    try std.testing.expect(metrics.misses == 0);
}

test "CacheRouter records cache hit on affinity match" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    const hash = fnv1a64("You are helpful");
    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4, .prefix_affinity = hash });

    var router = CacheRouter{};
    const refs = [_]BackendRef{.{ .pool_index = 0 }};
    _ = router.selectBackendNoTime(&pool, &refs, hash);
    try std.testing.expect(router.metrics.hits == 1);
    try std.testing.expect(router.metrics.misses == 0);
}

test "CacheRouter records cache miss on no affinity match" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4, .prefix_affinity = fnv1a64("Other prompt") });

    var router = CacheRouter{};
    const refs = [_]BackendRef{.{ .pool_index = 0 }};
    _ = router.selectBackendNoTime(&pool, &refs, fnv1a64("You are helpful"));
    try std.testing.expect(router.metrics.hits == 0);
    try std.testing.expect(router.metrics.misses == 1);
}

test "BackendEntry isAffinityExpired returns false when no timestamp" {
    var entry = backend_pool.BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .prefix_affinity = fnv1a64("test") };
    try std.testing.expect(!entry.isAffinityExpired(10000, 5000));
}

test "BackendEntry isAffinityExpired returns true when TTL exceeded" {
    var entry = backend_pool.BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4", .prefix_affinity = fnv1a64("test"), .prefix_affinity_updated_at_ms = 1000 };
    try std.testing.expect(entry.isAffinityExpired(7000, 5000));
}

test "BackendEntry updateAffinityWithTimestamp sets both fields" {
    var entry = backend_pool.BackendEntry{ .id = "test", .address = "http://test:8081", .model = "gpt-4" };
    const hash = fnv1a64("system prompt");
    entry.updateAffinityWithTimestamp(hash, 5000);
    try std.testing.expect(entry.prefix_affinity == hash);
    try std.testing.expect(entry.prefix_affinity_updated_at_ms == 5000);
}
