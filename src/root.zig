const std = @import("std");
const json = std.json;
const mem = std.mem;

pub const backend_pool = @import("backend_pool");
pub const openai = @import("openai");
pub const config = @import("config");
pub const cli = @import("cli");
pub const proxy = @import("proxy");
pub const request_queue = @import("request_queue");
pub const cache_router = @import("cache_router");
pub const metrics = @import("metrics");
pub const health = @import("health");
pub const logger = @import("logger");
pub const request_id = @import("request_id");
pub const auth = @import("auth");

pub const HealthChecker = struct {
    allocator: std.mem.Allocator,
    pool: *backend_pool.BackendPool,
    interval_ms: u64,
    req_queue: ?*request_queue.RequestQueue,

    pub fn run(self: *HealthChecker, io: std.Io) void {
        while (true) {
            const duration = std.Io.Duration.fromMilliseconds(@intCast(self.interval_ms));
            std.Io.sleep(io, duration, .awake) catch return;
            self.checkAll(io) catch |err| {
                std.log.err("health check error: {}", .{err});
            };
            if (self.req_queue) |rq| {
                const ts = std.Io.Timestamp.now(io, .awake);
                const now_ms = ts.toMilliseconds();
                _ = rq.expireTimedOut(now_ms);
            }
        }
    }

    fn checkAll(self: *HealthChecker, io: std.Io) !void {
        for (self.pool.backends.items) |*entry| {
            self.checkOne(io, entry) catch |err| {
                std.log.debug("health check failed for {s}: {}", .{ entry.id, err });
                entry.recordFailure();
            };
        }
    }

    fn checkOne(self: *HealthChecker, io: std.Io, entry: *backend_pool.BackendEntry) !void {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        const health_uri = try buildHealthUri(self.allocator, entry.address, entry.backend_type);
        defer self.allocator.free(health_uri);

        const uri = std.Uri.parse(health_uri) catch return error.InvalidUri;

        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [4096]u8 = undefined;
        var resp = try req.receiveHead(&redirect_buf);

        if (resp.head.status.class() == .success) {
            if (resp.head.content_length != null or resp.head.transfer_encoding == .chunked) {
                var transfer_buf: [4096]u8 = undefined;
                const reader = resp.reader(&transfer_buf);
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(self.allocator);
                reader.appendRemainingUnlimited(self.allocator, &body_buf) catch {};
                switch (entry.backend_type) {
                    .llama_cpp => parseSlotInfo(self.allocator, entry, body_buf.items) catch {},
                    .vllm => {
                        parseVllmHealthInfo(self.allocator, entry, body_buf.items) catch |parse_err| {
                            if (parse_err == error.Unhealthy) return parse_err;
                        };
                    },
                    .openai => {},
                }
            }
            entry.recordSuccess();
        } else {
            entry.recordFailure();
        }
    }

    pub fn parseSlotInfo(allocator: std.mem.Allocator, entry: *backend_pool.BackendEntry, body: []const u8) !void {
        const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;

        if (parsed.value.object.get("slots_idle")) |val| {
            switch (val) {
                .integer => entry.slots_idle = @intCast(val.integer),
                .float => entry.slots_idle = @intFromFloat(val.float),
                else => {},
            }
        }
        if (parsed.value.object.get("slots_processing")) |val| {
            switch (val) {
                .integer => entry.slots_processing = @intCast(val.integer),
                .float => entry.slots_processing = @intFromFloat(val.float),
                else => {},
            }
        }
        if (parsed.value.object.get("slots_total")) |val| {
            switch (val) {
                .integer => entry.slots_total = @intCast(val.integer),
                .float => entry.slots_total = @intFromFloat(val.float),
                else => {},
            }
        }
    }

    pub fn buildHealthUri(allocator: std.mem.Allocator, address: []const u8, backend_type: backend_pool.BackendType) ![]u8 {
        const suffix: []const u8 = switch (backend_type) {
            .llama_cpp => "/health",
            .vllm => "/health",
            .openai => "/v1/models",
        };
        const total_len = address.len + suffix.len;
        const buf = try allocator.alloc(u8, total_len);
        @memcpy(buf[0..address.len], address);
        @memcpy(buf[address.len..], suffix);
        return buf;
    }

    pub fn parseVllmHealthInfo(allocator: std.mem.Allocator, entry: *backend_pool.BackendEntry, body: []const u8) !void {
        const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;

        if (parsed.value.object.get("status")) |val| {
            switch (val) {
                .string => {
                    const is_healthy = mem.eql(u8, val.string, "ok") or mem.eql(u8, val.string, "running");
                    if (!is_healthy) {
                        entry.recordFailure();
                        return error.Unhealthy;
                    }
                },
                else => {},
            }
        }
    }
};

test "buildHealthUri appends /health to backend address" {
    const allocator = std.testing.allocator;
    const uri = try HealthChecker.buildHealthUri(allocator, "http://127.0.0.1:8081", .llama_cpp);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("http://127.0.0.1:8081/health", uri);
}

test "buildHealthUri appends /health for vllm backend" {
    const allocator = std.testing.allocator;
    const uri = try HealthChecker.buildHealthUri(allocator, "http://127.0.0.1:8000", .vllm);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("http://127.0.0.1:8000/health", uri);
}

test "buildHealthUri appends /v1/models for openai backend" {
    const allocator = std.testing.allocator;
    const uri = try HealthChecker.buildHealthUri(allocator, "https://api.openai.com", .openai);
    defer allocator.free(uri);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/models", uri);
}

test "parseSlotInfo extracts slots from llama.cpp health response" {
    var entry = backend_pool.BackendEntry{
        .id = "test",
        .address = "http://test:8081",
        .model = "gpt-4",
    };

    const body =
        \\{"status":"ok","slots_idle":2,"slots_processing":1,"slots_total":4}
    ;
    try HealthChecker.parseSlotInfo(std.testing.allocator, &entry, body);

    try std.testing.expect(entry.slots_idle == 2);
    try std.testing.expect(entry.slots_processing == 1);
    try std.testing.expect(entry.slots_total == 4);
}

test "parseSlotInfo handles response without slot fields" {
    var entry = backend_pool.BackendEntry{
        .id = "test",
        .address = "http://test:8081",
        .model = "gpt-4",
        .slots_idle = 5,
        .slots_processing = 3,
        .slots_total = 8,
    };

    const body =
        \\{"status":"ok"}
    ;
    try HealthChecker.parseSlotInfo(std.testing.allocator, &entry, body);

    try std.testing.expect(entry.slots_idle == 5);
    try std.testing.expect(entry.slots_processing == 3);
    try std.testing.expect(entry.slots_total == 8);
}

test "parseSlotInfo handles invalid JSON gracefully" {
    var entry = backend_pool.BackendEntry{
        .id = "test",
        .address = "http://test:8081",
        .model = "gpt-4",
        .slots_idle = 5,
    };

    try HealthChecker.parseSlotInfo(std.testing.allocator, &entry, "not json");

    try std.testing.expect(entry.slots_idle == 5);
}

test "parseVllmHealthInfo handles vLLM health response" {
    var entry = backend_pool.BackendEntry{
        .id = "vllm-1",
        .address = "http://vllm:8000",
        .model = "llama3",
        .backend_type = .vllm,
    };

    const body =
        \\{"status":"ok"}
    ;
    try HealthChecker.parseVllmHealthInfo(std.testing.allocator, &entry, body);
}

test "parseVllmHealthInfo handles vLLM running status" {
    var entry = backend_pool.BackendEntry{
        .id = "vllm-1",
        .address = "http://vllm:8000",
        .model = "llama3",
        .backend_type = .vllm,
    };

    const body =
        \\{"status":"running"}
    ;
    try HealthChecker.parseVllmHealthInfo(std.testing.allocator, &entry, body);
}

test "parseVllmHealthInfo handles invalid JSON gracefully" {
    var entry = backend_pool.BackendEntry{
        .id = "vllm-1",
        .address = "http://vllm:8000",
        .model = "llama3",
        .backend_type = .vllm,
    };

    try HealthChecker.parseVllmHealthInfo(std.testing.allocator, &entry, "not json");
}

test "parseVllmHealthInfo returns Unhealthy for bad status" {
    var entry = backend_pool.BackendEntry{
        .id = "vllm-1",
        .address = "http://vllm:8000",
        .model = "llama3",
        .backend_type = .vllm,
    };

    const body =
        \\{"status":"error"}
    ;
    const result = HealthChecker.parseVllmHealthInfo(std.testing.allocator, &entry, body);
    try std.testing.expect(result == error.Unhealthy);
    try std.testing.expect(entry.consecutive_failures == 1);
}

test "parseVllmHealthInfo ok status does not record failure" {
    var entry = backend_pool.BackendEntry{
        .id = "vllm-1",
        .address = "http://vllm:8000",
        .model = "llama3",
        .backend_type = .vllm,
    };

    const body =
        \\{"status":"ok"}
    ;
    try HealthChecker.parseVllmHealthInfo(std.testing.allocator, &entry, body);
    try std.testing.expect(entry.consecutive_failures == 0);
}

test "parseVllmHealthInfo running status does not record failure" {
    var entry = backend_pool.BackendEntry{
        .id = "vllm-1",
        .address = "http://vllm:8000",
        .model = "llama3",
        .backend_type = .vllm,
    };

    const body =
        \\{"status":"running"}
    ;
    try HealthChecker.parseVllmHealthInfo(std.testing.allocator, &entry, body);
    try std.testing.expect(entry.consecutive_failures == 0);
}
