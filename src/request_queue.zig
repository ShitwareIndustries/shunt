const std = @import("std");
const mem = std.mem;
const log = std.log;

pub const RequestQueue = struct {
    allocator: mem.Allocator,
    io: std.Io,
    max_size: usize,
    timeout_ms: u64,
    queue: std.ArrayList(QueuedRequest),
    mutex: std.Io.Mutex,

    pub const QueuedRequest = struct {
        id: u64,
        model: []const u8,
        enqueued_at_ms: i64,
        completed: bool,
        model_owned: bool,

        pub fn deinit(self: *QueuedRequest, allocator: mem.Allocator) void {
            if (self.model_owned and self.model.len > 0) {
                allocator.free(self.model);
                self.model = "";
                self.model_owned = false;
            }
        }
    };

    pub const EnqueueResult = enum {
        enqueued,
        overflow,
    };

    pub const DequeueResult = enum {
        found,
        timeout,
        empty,
    };

    pub fn init(allocator: mem.Allocator, io: std.Io, max_size: usize, timeout_ms: u64) RequestQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .max_size = max_size,
            .timeout_ms = timeout_ms,
            .queue = .empty,
            .mutex = .init,
        };
    }

    pub fn deinit(self: *RequestQueue) void {
        for (self.queue.items) |*item| {
            item.deinit(self.allocator);
        }
        self.queue.deinit(self.allocator);
    }

    pub fn enqueue(self: *RequestQueue, model: []const u8, now_ms: i64) !EnqueueResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        _ = self.expireTimedOutUnlocked(now_ms);

        if (self.queue.items.len >= self.max_size) {
            return .overflow;
        }

        const model_owned = try self.allocator.dupe(u8, model);
        const id = @as(u64, @intCast(now_ms)) + @as(u64, self.queue.items.len);

        try self.queue.append(self.allocator, .{
            .id = id,
            .model = model_owned,
            .enqueued_at_ms = now_ms,
            .completed = false,
            .model_owned = true,
        });

        return .enqueued;
    }

    pub fn dequeue(self: *RequestQueue, now_ms: i64) DequeueResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var i: usize = 0;
        while (i < self.queue.items.len) {
            const item = &self.queue.items[i];
            if (now_ms - item.enqueued_at_ms > @as(i64, @intCast(self.timeout_ms))) {
                item.completed = true;
                var expired = self.queue.orderedRemove(i);
                expired.deinit(self.allocator);
                return .timeout;
            }
            if (!item.completed) {
                item.completed = true;
                var result = self.queue.orderedRemove(i);
                result.deinit(self.allocator);
                return .found;
            }
            i += 1;
        }

        return .empty;
    }

    pub fn dequeueOldest(self: *RequestQueue, now_ms: i64) ?QueuedRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var i: usize = 0;
        while (i < self.queue.items.len) {
            const item = &self.queue.items[i];
            if (now_ms - item.enqueued_at_ms > @as(i64, @intCast(self.timeout_ms))) {
                var expired = self.queue.orderedRemove(i);
                expired.completed = true;
                expired.deinit(self.allocator);
                continue;
            }
            if (!item.completed) {
                item.completed = true;
                return self.queue.orderedRemove(i);
            }
            i += 1;
        }

        return null;
    }

    pub fn len(self: *RequestQueue) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.pendingCountUnlocked();
    }

    pub fn isFull(self: *RequestQueue) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queue.items.len >= self.max_size;
    }

    pub fn expireTimedOut(self: *RequestQueue, now_ms: i64) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.expireTimedOutUnlocked(now_ms);
    }

    fn expireTimedOutUnlocked(self: *RequestQueue, now_ms: i64) usize {
        var expired_count: usize = 0;
        var i: usize = 0;
        while (i < self.queue.items.len) {
            const item = &self.queue.items[i];
            if (now_ms - item.enqueued_at_ms > @as(i64, @intCast(self.timeout_ms))) {
                var expired = self.queue.orderedRemove(i);
                expired.deinit(self.allocator);
                expired_count += 1;
            } else {
                i += 1;
            }
        }
        return expired_count;
    }

    fn pendingCountUnlocked(self: *RequestQueue) usize {
        var count: usize = 0;
        for (self.queue.items) |item| {
            if (!item.completed) count += 1;
        }
        return count;
    }

    pub const OverflowError = struct {
        message: []const u8 = "All backends busy, request queue full",
        type: []const u8 = "server_error",
    };

    pub const TimeoutError = struct {
        message: []const u8 = "Request timed out waiting for available backend",
        type: []const u8 = "server_error",
    };

    pub const OverflowBody = struct {
        @"error": OverflowError = .{},
    };

    pub const TimeoutBody = struct {
        @"error": TimeoutError = .{},
    };

    pub fn buildOverflowBody(allocator: mem.Allocator) ![]u8 {
        const obj: OverflowBody = .{};
        return std.json.Stringify.valueAlloc(allocator, obj, .{});
    }

    pub fn buildTimeoutBody(allocator: mem.Allocator) ![]u8 {
        const obj: TimeoutBody = .{};
        return std.json.Stringify.valueAlloc(allocator, obj, .{});
    }
};

test "RequestQueue enqueue and dequeue preserves FIFO order" {
    var rq = RequestQueue.init(std.testing.allocator, std.testing.io, 64, 30000);
    defer rq.deinit();

    const now: i64 = 1000;
    _ = try rq.enqueue("gpt-4", now);
    _ = try rq.enqueue("gpt-4", now + 1);
    _ = try rq.enqueue("llama3", now + 2);

    var first = rq.dequeueOldest(now + 10).?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gpt-4", first.model);

    var second = rq.dequeueOldest(now + 10).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gpt-4", second.model);

    var third = rq.dequeueOldest(now + 10).?;
    defer third.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("llama3", third.model);

    try std.testing.expect(rq.dequeueOldest(now + 10) == null);
}

test "RequestQueue returns overflow when full" {
    var rq = RequestQueue.init(std.testing.allocator, std.testing.io, 2, 30000);
    defer rq.deinit();

    const now: i64 = 1000;
    const r1 = try rq.enqueue("gpt-4", now);
    try std.testing.expect(r1 == .enqueued);

    const r2 = try rq.enqueue("gpt-4", now + 1);
    try std.testing.expect(r2 == .enqueued);

    const r3 = try rq.enqueue("gpt-4", now + 2);
    try std.testing.expect(r3 == .overflow);
}

test "RequestQueue returns timeout when request expires" {
    var rq = RequestQueue.init(std.testing.allocator, std.testing.io, 64, 5000);
    defer rq.deinit();

    const now: i64 = 1000;
    _ = try rq.enqueue("gpt-4", now);

    const result = rq.dequeue(now + 6000);
    try std.testing.expect(result == .timeout);
}

test "RequestQueue dequeue returns empty when no requests" {
    var rq = RequestQueue.init(std.testing.allocator, std.testing.io, 64, 30000);
    defer rq.deinit();

    const result = rq.dequeue(1000);
    try std.testing.expect(result == .empty);
}

test "RequestQueue expireTimedOut removes expired entries" {
    var rq = RequestQueue.init(std.testing.allocator, std.testing.io, 64, 10000);
    defer rq.deinit();

    _ = try rq.enqueue("gpt-4", 1000);
    _ = try rq.enqueue("gpt-4", 1001);
    _ = try rq.enqueue("gpt-4", 11000);

    const expired = rq.expireTimedOut(15000);
    try std.testing.expect(expired == 2);
    try std.testing.expect(rq.len() == 1);
}

test "buildOverflowBody returns valid OpenAI error JSON" {
    const body = try RequestQueue.buildOverflowBody(std.testing.allocator);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?;
    try std.testing.expectEqualStrings("All backends busy, request queue full", error_obj.object.get("message").?.string);
    try std.testing.expectEqualStrings("server_error", error_obj.object.get("type").?.string);
}

test "buildTimeoutBody returns valid OpenAI error JSON" {
    const body = try RequestQueue.buildTimeoutBody(std.testing.allocator);
    defer std.testing.allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();

    const error_obj = parsed.value.object.get("error").?;
    try std.testing.expectEqualStrings("Request timed out waiting for available backend", error_obj.object.get("message").?.string);
    try std.testing.expectEqualStrings("server_error", error_obj.object.get("type").?.string);
}

test "RequestQueue isFull returns true when at capacity" {
    var rq = RequestQueue.init(std.testing.allocator, std.testing.io, 3, 30000);
    defer rq.deinit();

    try std.testing.expect(!rq.isFull());

    const now: i64 = 1000;
    _ = try rq.enqueue("gpt-4", now);
    _ = try rq.enqueue("gpt-4", now);
    try std.testing.expect(!rq.isFull());

    _ = try rq.enqueue("gpt-4", now);
    try std.testing.expect(rq.isFull());
}
