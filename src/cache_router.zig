const std = @import("std");
const mem = std.mem;
const json = std.json;
const backend_pool = @import("backend_pool");

pub const BackendRef = struct {
    pool_index: usize,
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
    pub fn selectBackend(
        pool: *backend_pool.BackendPool,
        group_backends: []const BackendRef,
        prefix_hash: u64,
    ) ?*backend_pool.BackendEntry {
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

        if (affinity_match) |match| return match;
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

    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");
    const selected = CacheRouter.selectBackend(&pool, &refs, hash);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("http://a:8081", selected.?.address);
}

test "CacheRouter falls back to least-busy when no affinity match" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 1, .slots_processing = 3, .slots_total = 4, .prefix_affinity = fnv1a64("Other prompt") });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 3, .slots_processing = 1, .slots_total = 4, .prefix_affinity = fnv1a64("Another prompt") });

    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("New prompt");
    const selected = CacheRouter.selectBackend(&pool, &refs, hash);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("http://b:8081", selected.?.address);
}

test "CacheRouter falls back to least-busy when affinity match is full" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 0, .slots_processing = 4, .slots_total = 4, .prefix_affinity = fnv1a64("You are helpful") });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 2, .slots_processing = 2, .slots_total = 4, .prefix_affinity = 0 });

    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");
    const selected = CacheRouter.selectBackend(&pool, &refs, hash);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("http://b:8081", selected.?.address);
}

test "CacheRouter two requests with same prefix route to same backend" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4 });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4 });

    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");

    const first = CacheRouter.selectBackend(&pool, &refs, hash).?;
    first.updateAffinity(hash);

    const second = CacheRouter.selectBackend(&pool, &refs, hash).?;
    try std.testing.expectEqualStrings(first.address, second.address);
}

test "CacheRouter returns null when all backends unhealthy" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy });

    const refs = [_]BackendRef{.{ .pool_index = 0 }};
    const hash = fnv1a64("test");
    try std.testing.expect(CacheRouter.selectBackend(&pool, &refs, hash) == null);
}

test "CacheRouter returns null for empty backend group" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    const refs = [_]BackendRef{};
    const hash = fnv1a64("test");
    try std.testing.expect(CacheRouter.selectBackend(&pool, &refs, hash) == null);
}

test "CacheRouter prefers affinity match over least-busy" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 1, .slots_processing = 3, .slots_total = 4, .prefix_affinity = fnv1a64("You are helpful") });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 4, .slots_processing = 0, .slots_total = 4, .prefix_affinity = 0 });

    const refs = [_]BackendRef{ .{ .pool_index = 0 }, .{ .pool_index = 1 } };
    const hash = fnv1a64("You are helpful");
    const selected = CacheRouter.selectBackend(&pool, &refs, hash).?;
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

    const start = std.Io.Timestamp.now(std.testing.io, .awake);
    var iter: usize = 0;
    while (iter < 10000) : (iter += 1) {
        _ = CacheRouter.selectBackend(&pool, refs.items, hash);
    }
    const end = std.Io.Timestamp.now(std.testing.io, .awake);

    const elapsed_ns = end.toNanoseconds() - start.toNanoseconds();
    const per_decision_ns: u64 = @intCast(@divTrunc(elapsed_ns, 10000));
    const per_decision_us: u64 = @divTrunc(per_decision_ns, 1000);

    try std.testing.expect(per_decision_us < 1000);
}
