const std = @import("std");
const http = std.http;
const mem = std.mem;
const json = std.json;
const log = std.log;
const backend_pool = @import("backend_pool");
const cache_router = @import("cache_router");

pub const BackendRef = backend_pool.BackendRef;

pub const ModelGroup = struct {
    name: []const u8,
    backends: std.ArrayList(BackendRef),
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, name: []const u8) ModelGroup {
        return .{
            .name = name,
            .backends = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModelGroup) void {
        self.backends.deinit(self.allocator);
    }

    pub fn addBackend(self: *ModelGroup, ref: BackendRef) !void {
        try self.backends.append(self.allocator, ref);
    }
};

pub const ModelRouter = struct {
    groups: std.ArrayList(ModelGroup),
    group_map: std.StringArrayHashMapUnmanaged(usize),
    allocator: mem.Allocator,
    rr_counters: std.ArrayList(u32),
    cache_router: cache_router.CacheRouter,

    pub fn init(allocator: mem.Allocator) ModelRouter {
        return .{
            .groups = .empty,
            .group_map = .empty,
            .allocator = allocator,
            .rr_counters = .empty,
            .cache_router = .{},
        };
    }

    pub fn initWithTTL(allocator: mem.Allocator, cache_ttl_ms: u64) ModelRouter {
        return .{
            .groups = .empty,
            .group_map = .empty,
            .allocator = allocator,
            .rr_counters = .empty,
            .cache_router = .{ .cache_ttl_ms = cache_ttl_ms },
        };
    }

    pub fn initDisabled(allocator: mem.Allocator) ModelRouter {
        return .{
            .groups = .empty,
            .group_map = .empty,
            .allocator = allocator,
            .rr_counters = .empty,
            .cache_router = .{ .cache_ttl_ms = 0, .disabled = true },
        };
    }

    pub fn deinit(self: *ModelRouter) void {
        for (self.groups.items) |*g| g.deinit();
        self.groups.deinit(self.allocator);
        self.group_map.deinit(self.allocator);
        self.rr_counters.deinit(self.allocator);
    }

    pub fn registerGroup(self: *ModelRouter, name: []const u8) !usize {
        const idx = self.groups.items.len;
        var group = ModelGroup.init(self.allocator, name);
        errdefer group.deinit();
        try self.groups.append(self.allocator, group);
        try self.group_map.put(self.allocator, name, idx);
        try self.rr_counters.append(self.allocator, 0);
        return idx;
    }

    pub fn addBackendToGroup(self: *ModelRouter, group_name: []const u8, pool_index: usize) !void {
        const idx = self.group_map.get(group_name) orelse {
            const new_idx = try self.registerGroup(group_name);
            try self.groups.items[new_idx].addBackend(.{ .pool_index = pool_index });
            return;
        };
        try self.groups.items[idx].addBackend(.{ .pool_index = pool_index });
    }

    pub fn selectBackendForModel(self: *ModelRouter, model: []const u8, pool: *backend_pool.BackendPool, prefix_hash: u64) ?*backend_pool.BackendEntry {
        const group_idx = self.group_map.get(model) orelse return null;
        const group = &self.groups.items[group_idx];
        if (group.backends.items.len == 0) return null;

        if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY) {
            const cache_result = self.cache_router.selectBackendNoTime(pool, group.backends.items, prefix_hash);
            if (cache_result) |entry| return entry;
        }

        const rr = &self.rr_counters.items[group_idx];
        const start = rr.* % group.backends.items.len;
        var i: usize = 0;
        while (i < group.backends.items.len) : (i += 1) {
            const try_idx = (start + i) % group.backends.items.len;
            const pool_idx = group.backends.items[try_idx].pool_index;
            if (pool_idx < pool.backends.items.len) {
                const entry = &pool.backends.items[pool_idx];
                if (entry.health != .healthy) continue;
                rr.* = @intCast(try_idx + 1);
                return entry;
            }
        }
        return null;
    }

    pub fn selectBackendForModelWithTime(self: *ModelRouter, model: []const u8, pool: *backend_pool.BackendPool, prefix_hash: u64, now_ms: i64) ?*backend_pool.BackendEntry {
        const group_idx = self.group_map.get(model) orelse return null;
        const group = &self.groups.items[group_idx];
        if (group.backends.items.len == 0) return null;

        if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY) {
            const cache_result = self.cache_router.selectBackend(pool, group.backends.items, prefix_hash, now_ms);
            if (cache_result) |entry| return entry;
        }

        const rr = &self.rr_counters.items[group_idx];
        const start = rr.* % group.backends.items.len;
        var i: usize = 0;
        while (i < group.backends.items.len) : (i += 1) {
            const try_idx = (start + i) % group.backends.items.len;
            const pool_idx = group.backends.items[try_idx].pool_index;
            if (pool_idx < pool.backends.items.len) {
                const entry = &pool.backends.items[pool_idx];
                if (entry.health != .healthy) continue;
                rr.* = @intCast(try_idx + 1);
                return entry;
            }
        }
        return null;
    }

    pub fn modelNames(self: *ModelRouter, allocator: mem.Allocator) ![]const []const u8 {
        var names = std.ArrayList([]const u8).empty;
        errdefer names.deinit(allocator);
        var it = self.group_map.iterator();
        while (it.next()) |entry| {
            try names.append(allocator, entry.key_ptr.*);
        }
        return names.items;
    }
};

pub const ChatCompletionRequest = struct {
    model: []const u8,
    stream: bool = false,
    owned: bool = false,
    prefix_hash: u64 = backend_pool.BackendEntry.NO_AFFINITY,

    pub fn deinit(self: *ChatCompletionRequest, allocator: mem.Allocator) void {
        if (self.owned and self.model.len > 0) {
            allocator.free(self.model);
            self.model = "";
            self.owned = false;
        }
    }

    pub fn parse(allocator: mem.Allocator, body: []const u8) !ChatCompletionRequest {
        const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();
        const root = parsed.value;

        if (root != .object) return error.InvalidJson;
        const model_val = root.object.get("model") orelse return error.MissingModel;
        if (model_val != .string) return error.InvalidModel;

        const stream_val = root.object.get("stream");
        const is_stream = if (stream_val) |sv| switch (sv) {
            .bool => |b| b,
            else => false,
        } else false;

        const model_owned = try allocator.dupe(u8, model_val.string);

        var prefix_hash: u64 = backend_pool.BackendEntry.NO_AFFINITY;
        if (root.object.get("messages")) |messages| {
            if (messages == .array) {
                for (messages.array.items) |msg| {
                    if (msg == .object) {
                        const role = msg.object.get("role") orelse continue;
                        if (role == .string and mem.eql(u8, role.string, "system")) {
                            const content = msg.object.get("content") orelse continue;
                            if (content == .string) {
                                prefix_hash = cache_router.fnv1a64(content.string);
                                break;
                            }
                        }
                    }
                }
            }
        }

        return .{
            .model = model_owned,
            .stream = is_stream,
            .owned = true,
            .prefix_hash = prefix_hash,
        };
    }
};

pub const OpenAIModel = struct {
    id: []const u8,
    object: []const u8 = "model",
    owned: bool = true,
    created: u64 = 0,
};

pub const OpenAIModelsResponse = struct {
    object: []const u8 = "list",
    data: []OpenAIModel,
};

pub fn routePath(target: []const u8) ?Route {
    if (mem.eql(u8, target, "/v1/chat/completions") or
        mem.startsWith(u8, target, "/v1/chat/completions?"))
    {
        return .chat_completions;
    }
    if (mem.eql(u8, target, "/v1/completions") or
        mem.startsWith(u8, target, "/v1/completions?"))
    {
        return .completions;
    }
    if (mem.eql(u8, target, "/v1/models") or
        mem.startsWith(u8, target, "/v1/models?"))
    {
        return .models;
    }
    if (mem.eql(u8, target, "/health") or
        mem.startsWith(u8, target, "/health?"))
    {
        return .health;
    }
    return null;
}

pub const Route = enum {
    chat_completions,
    completions,
    models,
    health,
};

pub fn buildModelsResponse(allocator: mem.Allocator, router: *ModelRouter) ![]u8 {
    var models = std.ArrayList(OpenAIModel).empty;
    defer models.deinit(allocator);

    var it = router.group_map.iterator();
    while (it.next()) |entry| {
        try models.append(allocator, .{
            .id = entry.key_ptr.*,
        });
    }

    const response = OpenAIModelsResponse{
        .data = models.items,
    };
    return json.Stringify.valueAlloc(allocator, response, .{});
}

pub fn buildHealthResponse(allocator: mem.Allocator, healthy: bool) ![]u8 {
    const response = .{
        .status = if (healthy) "ok" else "unhealthy",
    };
    return json.Stringify.valueAlloc(allocator, response, .{});
}

test "routePath matches OpenAI endpoints" {
    try std.testing.expect(routePath("/v1/chat/completions") != null);
    try std.testing.expect(routePath("/v1/chat/completions") == .chat_completions);
    try std.testing.expect(routePath("/v1/models") == .models);
    try std.testing.expect(routePath("/v1/completions") == .completions);
    try std.testing.expect(routePath("/health") == .health);
    try std.testing.expect(routePath("/v1/chat/completions?foo=bar") == .chat_completions);
    try std.testing.expect(routePath("/unknown") == null);
}

test "ChatCompletionRequest parses model and stream from JSON" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"stream":true}
    ;
    var req = try ChatCompletionRequest.parse(allocator, body);
    defer req.deinit(allocator);
    try std.testing.expectEqualStrings("gpt-4", req.model);
    try std.testing.expect(req.stream == true);
    try std.testing.expect(req.prefix_hash == backend_pool.BackendEntry.NO_AFFINITY);
}

test "ChatCompletionRequest extracts prefix hash from system prompt" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"gpt-4","messages":[{"role":"system","content":"You are helpful"},{"role":"user","content":"hi"}]}
    ;
    var req = try ChatCompletionRequest.parse(allocator, body);
    defer req.deinit(allocator);
    try std.testing.expectEqualStrings("gpt-4", req.model);
    try std.testing.expect(req.prefix_hash == cache_router.fnv1a64("You are helpful"));
}

test "ChatCompletionRequest defaults stream to false" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"llama3","messages":[{"role":"user","content":"test"}]}
    ;
    var req = try ChatCompletionRequest.parse(allocator, body);
    defer req.deinit(allocator);
    try std.testing.expectEqualStrings("llama3", req.model);
    try std.testing.expect(req.stream == false);
}

test "ChatCompletionRequest returns error on missing model" {
    const allocator = std.testing.allocator;
    const body =
        \\{"messages":[{"role":"user","content":"hi"}]}
    ;
    const result = ChatCompletionRequest.parse(allocator, body);
    try std.testing.expect(result == error.MissingModel);
}

test "ChatCompletionRequest returns error on invalid JSON" {
    const allocator = std.testing.allocator;
    const result = ChatCompletionRequest.parse(allocator, "not json");
    try std.testing.expect(result == error.InvalidJson);
}

test "ModelRouter routes to correct backend group" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "c", .address = "http://c:8081", .model = "llama3" });

    var router = ModelRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.addBackendToGroup("gpt-4", 0);
    try router.addBackendToGroup("gpt-4", 1);
    try router.addBackendToGroup("llama3", 2);

    const be = router.selectBackendForModel("gpt-4", &pool, backend_pool.BackendEntry.NO_AFFINITY).?;
    try std.testing.expect(mem.eql(u8, be.address, "http://a:8081") or
        mem.eql(u8, be.address, "http://b:8081"));

    const be2 = router.selectBackendForModel("llama3", &pool, backend_pool.BackendEntry.NO_AFFINITY).?;
    try std.testing.expectEqualStrings("http://c:8081", be2.address);

    try std.testing.expect(router.selectBackendForModel("unknown", &pool, backend_pool.BackendEntry.NO_AFFINITY) == null);
}

test "ModelRouter round-robin within model group" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4" });

    var router = ModelRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.addBackendToGroup("gpt-4", 0);
    try router.addBackendToGroup("gpt-4", 1);

    const first = router.selectBackendForModel("gpt-4", &pool, backend_pool.BackendEntry.NO_AFFINITY).?;
    const second = router.selectBackendForModel("gpt-4", &pool, backend_pool.BackendEntry.NO_AFFINITY).?;
    try std.testing.expect(!mem.eql(u8, first.address, second.address));
}

test "ModelRouter skips unhealthy backends" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .health = .unhealthy });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4" });

    var router = ModelRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.addBackendToGroup("gpt-4", 0);
    try router.addBackendToGroup("gpt-4", 1);

    const be = router.selectBackendForModel("gpt-4", &pool, backend_pool.BackendEntry.NO_AFFINITY).?;
    try std.testing.expectEqualStrings("http://b:8081", be.address);
    try std.testing.expect(be.health == .healthy);
}

test "buildModelsResponse returns valid JSON with model list" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4" });

    var router = ModelRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.addBackendToGroup("gpt-4", 0);

    const resp = try buildModelsResponse(std.testing.allocator, &router);
    defer std.testing.allocator.free(resp);

    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, resp, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("list", parsed.value.object.get("object").?.string);
    const data = parsed.value.object.get("data").?;
    try std.testing.expect(data == .array);
    try std.testing.expect(data.array.items.len == 1);
    try std.testing.expectEqualStrings("gpt-4", data.array.items[0].object.get("id").?.string);
}

test "buildHealthResponse returns ok for healthy" {
    const resp = try buildHealthResponse(std.testing.allocator, true);
    defer std.testing.allocator.free(resp);

    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, resp, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ok", parsed.value.object.get("status").?.string);
}

test "buildHealthResponse returns unhealthy for false" {
    const resp = try buildHealthResponse(std.testing.allocator, false);
    defer std.testing.allocator.free(resp);

    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, resp, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("unhealthy", parsed.value.object.get("status").?.string);
}

test "ModelRouter uses cache-aware routing with prefix hash" {
    var pool = backend_pool.BackendPool.init(std.testing.allocator);
    defer pool.deinit();

    const hash = cache_router.fnv1a64("You are helpful");
    try pool.addBackend(.{ .id = "a", .address = "http://a:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4, .prefix_affinity = hash });
    try pool.addBackend(.{ .id = "b", .address = "http://b:8081", .model = "gpt-4", .slots_idle = 2, .slots_total = 4, .prefix_affinity = cache_router.fnv1a64("Other prompt") });

    var router = ModelRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.addBackendToGroup("gpt-4", 0);
    try router.addBackendToGroup("gpt-4", 1);

    const selected = router.selectBackendForModel("gpt-4", &pool, hash).?;
    try std.testing.expectEqualStrings("http://a:8081", selected.address);
}
