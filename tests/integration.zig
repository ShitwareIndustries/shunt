const std = @import("std");
const http = std.http;
const mem = std.mem;
const net = std.Io.net;

pub const TestServer = struct {
    allocator: mem.Allocator,
    address: net.IpAddress,
    server: ?net.Server,
    port: u16,
    handler_fn: HandlerFn,
    running: bool,

    pub const HandlerFn = *const fn (allocator: mem.Allocator, request: *http.Server.Request) void;

    pub fn init(allocator: mem.Allocator, handler_fn: HandlerFn) TestServer {
        return .{
            .allocator = allocator,
            .address = net.IpAddress.parseLiteral("127.0.0.1:0") catch unreachable,
            .server = null,
            .port = 0,
            .handler_fn = handler_fn,
            .running = false,
        };
    }

    pub fn start(self: *TestServer, io: std.Io) !void {
        self.server = try net.IpAddress.listen(&self.address, io, .{ .reuse_address = true });
        self.port = self.server.?.socket.address.getPort();
        self.running = true;
    }

    pub fn stop(self: *TestServer, io: std.Io) void {
        if (self.server) |*s| {
            s.deinit(io);
            self.server = null;
        }
        self.running = false;
    }

    pub fn baseUrl(self: *TestServer) []const u8 {
        var buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
        return self.allocator.dupe(u8, url) catch unreachable;
    }

    pub fn serveOne(self: *TestServer, io: std.Io) void {
        const listener = self.server orelse return;
        var stream = listener.accept(io) catch return;
        defer stream.close(io);

        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in_reader = net.Stream.reader(stream, io, &in_buf);
        var out_writer = net.Stream.writer(stream, io, &out_buf);

        var http_server = http.Server.init(&in_reader.interface, &out_writer.interface);

        var request = http_server.receiveHead() catch return;
        self.handler_fn(self.allocator, &request);
    }
};

fn healthHandler(allocator: mem.Allocator, request: *http.Server.Request) void {
    _ = allocator;
    request.respond(
        \\{"status":"ok","slots_idle":2,"slots_processing":1,"slots_total":4}
    , .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch {};
}

fn errorHandler(allocator: mem.Allocator, request: *http.Server.Request) void {
    _ = allocator;
    request.respond("internal error", .{
        .status = .internal_server_error,
    }) catch {};
}

test "TestServer starts and reports correct port" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = TestServer.init(allocator, healthHandler);
    try server.start(io);
    defer server.stop(io);

    try std.testing.expect(server.port > 0);
    try std.testing.expect(server.running);
}

test "TestServer baseUrl contains port" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = TestServer.init(allocator, healthHandler);
    try server.start(io);
    defer server.stop(io);

    const url = server.baseUrl();
    defer allocator.free(url);

    try std.testing.expect(url.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, url, "127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, ":") != null);
}

test "TestServer stop cleans up" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = TestServer.init(allocator, healthHandler);
    try server.start(io);
    server.stop(io);

    try std.testing.expect(!server.running);
    try std.testing.expect(server.server == null);
}

test "TestServer can restart after stop" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = TestServer.init(allocator, healthHandler);
    try server.start(io);
    const first_port = server.port;
    server.stop(io);

    try server.start(io);
    defer server.stop(io);
    try std.testing.expect(server.port > 0);
    try std.testing.expect(server.running);
    _ = first_port;
}
