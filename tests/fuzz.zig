const std = @import("std");
const shunt = @import("shunt");

fn fuzzParseSlotInfo(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    var entry = shunt.backend_pool.BackendEntry{
        .id = "fuzz",
        .address = "http://fuzz:8081",
        .model = "fuzz-model",
    };
    shunt.HealthChecker.parseSlotInfo(std.testing.allocator, &entry, input) catch {};
}

fn fuzzChatCompletionParse(_: void, smith: *std.testing.Smith) !void {
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    var req = shunt.openai.ChatCompletionRequest.parse(std.testing.allocator, input) catch return;
    req.deinit(std.testing.allocator);
}

fn fuzzRoutePath(_: void, smith: *std.testing.Smith) !void {
    var buf: [256]u8 = undefined;
    const len = smith.slice(&buf);
    const input = buf[0..len];

    _ = shunt.openai.routePath(input);
}

test "fuzz parseSlotInfo with random input" {
    try std.testing.fuzz({}, fuzzParseSlotInfo, .{});
}

test "fuzz ChatCompletionRequest.parse with random input" {
    try std.testing.fuzz({}, fuzzChatCompletionParse, .{});
}

test "fuzz routePath with random input" {
    try std.testing.fuzz({}, fuzzRoutePath, .{});
}
