const std = @import("std");
const http = std.http;
const mem = std.mem;
const json = std.json;
const backend_pool = @import("backend_pool");

pub const KubeHealthChecker = struct {
    start_time_ns: i64,
    pool: ?*backend_pool.BackendPool,

    pub fn init(pool: ?*backend_pool.BackendPool, start_time_ns: i64) KubeHealthChecker {
        return .{
            .start_time_ns = start_time_ns,
            .pool = pool,
        };
    }

    pub fn livenessResponse(self: *KubeHealthChecker, allocator: mem.Allocator, now_ns: i64) ![]u8 {
        const uptime_ns = now_ns - self.start_time_ns;
        const uptime_seconds: i64 = @divTrunc(uptime_ns, std.time.ns_per_s);
        const response = .{
            .status = "ok",
            .uptime_seconds = uptime_seconds,
        };
        return json.Stringify.valueAlloc(allocator, response, .{});
    }

    pub const ReadinessResult = struct {
        body: []u8,
        status: http.Status,
    };

    pub fn readinessResponseNull(allocator: mem.Allocator) !ReadinessResult {
        const body_str = try json.Stringify.valueAlloc(allocator, .{
            .status = "unhealthy",
            .checks = .{
                .backends = .{
                    .status = "unknown",
                },
            },
        }, .{});
        return .{ .body = body_str, .status = .service_unavailable };
    }

    pub fn readinessResponse(self: *KubeHealthChecker, allocator: mem.Allocator) !ReadinessResult {
        const pool = self.pool orelse {
            const body_str = try json.Stringify.valueAlloc(allocator, .{
                .status = "unhealthy",
                .checks = .{
                    .backends = .{
                        .status = "unknown",
                    },
                },
            }, .{});
            return .{ .body = body_str, .status = .service_unavailable };
        };

        const total = pool.backends.items.len;
        var healthy: usize = 0;
        for (pool.backends.items) |b| {
            if (b.health == .healthy) healthy += 1;
        }

        if (healthy > 0) {
            const body_str = try json.Stringify.valueAlloc(allocator, .{
                .status = "ok",
                .checks = .{
                    .backends = .{
                        .status = "ok",
                        .healthy_count = healthy,
                        .total_count = total,
                    },
                },
            }, .{});
            return .{ .body = body_str, .status = .ok };
        } else {
            const body_str = try json.Stringify.valueAlloc(allocator, .{
                .status = "unhealthy",
                .checks = .{
                    .backends = .{
                        .status = "unhealthy",
                        .healthy_count = healthy,
                        .total_count = total,
                    },
                },
            }, .{});
            return .{ .body = body_str, .status = .service_unavailable };
        }
    }
};

test "KubeHealthChecker liveness always returns ok" {
    const allocator = std.testing.allocator;
    var checker = KubeHealthChecker.init(null, 0);
    const body = try checker.livenessResponse(allocator, std.time.ns_per_s * 42);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
    try std.testing.expect(parsed.value.object.get("uptime_seconds").?.integer == 42);
}

test "KubeHealthChecker readiness returns ok with healthy backends" {
    const allocator = std.testing.allocator;
    var pool = backend_pool.BackendPool.init(allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .health = .unhealthy });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "gpt-4" });

    var checker = KubeHealthChecker.init(&pool, 0);
    const result = try checker.readinessResponse(allocator);
    defer allocator.free(result.body);

    try std.testing.expect(result.status == .ok);

    const parsed = try json.parseFromSlice(json.Value, allocator, result.body, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
    const checks = parsed.value.object.get("checks").?.object;
    const backends = checks.get("backends").?.object;
    try std.testing.expectEqualStrings("ok", backends.get("status").?.string);
    try std.testing.expect(backends.get("healthy_count").?.integer == 2);
    try std.testing.expect(backends.get("total_count").?.integer == 3);
}

test "KubeHealthChecker readiness returns 503 with no healthy backends" {
    const allocator = std.testing.allocator;
    var pool = backend_pool.BackendPool.init(allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy });

    var checker = KubeHealthChecker.init(&pool, 0);
    const result = try checker.readinessResponse(allocator);
    defer allocator.free(result.body);

    try std.testing.expect(result.status == .service_unavailable);

    const parsed = try json.parseFromSlice(json.Value, allocator, result.body, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("unhealthy", parsed.value.object.get("status").?.string);
    const checks = parsed.value.object.get("checks").?.object;
    const backends = checks.get("backends").?.object;
    try std.testing.expectEqualStrings("unhealthy", backends.get("status").?.string);
    try std.testing.expect(backends.get("healthy_count").?.integer == 0);
    try std.testing.expect(backends.get("total_count").?.integer == 1);
}

test "KubeHealthChecker readiness returns 503 with null pool" {
    const allocator = std.testing.allocator;
    var checker = KubeHealthChecker.init(null, 0);
    const result = try checker.readinessResponse(allocator);
    defer allocator.free(result.body);

    try std.testing.expect(result.status == .service_unavailable);

    const parsed = try json.parseFromSlice(json.Value, allocator, result.body, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("unhealthy", parsed.value.object.get("status").?.string);
    const checks = parsed.value.object.get("checks").?.object;
    const backends = checks.get("backends").?.object;
    try std.testing.expectEqualStrings("unknown", backends.get("status").?.string);
    try std.testing.expect(backends.get("healthy_count") == null);
    try std.testing.expect(backends.get("total_count") == null);
}

test "KubeHealthChecker uptime calculation is correct" {
    const allocator = std.testing.allocator;
    const start_ns: i64 = std.time.ns_per_s * 100;
    const now_ns: i64 = std.time.ns_per_s * 145;
    var checker = KubeHealthChecker.init(null, start_ns);
    const body = try checker.livenessResponse(allocator, now_ns);
    defer allocator.free(body);

    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.object.get("uptime_seconds").?.integer == 45);
}
