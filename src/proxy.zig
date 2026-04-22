const std = @import("std");
const http = std.http;
const mem = std.mem;
const log = std.log;
const json = std.json;
const backend_pool = @import("backend_pool");
const openai = @import("openai");
const request_queue = @import("request_queue");
const cache_router = @import("cache_router");
const metrics_mod = @import("metrics");

pub const ReverseProxy = struct {
    allocator: mem.Allocator,
    pool: *backend_pool.BackendPool,
    router: *openai.ModelRouter,
    listen_addr: []const u8,
    req_queue: ?*request_queue.RequestQueue,
    metrics: *metrics_mod.Metrics,

    pub fn init(allocator: mem.Allocator, pool: *backend_pool.BackendPool, router: *openai.ModelRouter, metrics: *metrics_mod.Metrics) ReverseProxy {
        return .{
            .allocator = allocator,
            .pool = pool,
            .router = router,
            .listen_addr = "0.0.0.0:8080",
            .req_queue = null,
            .metrics = metrics,
        };
    }

    pub fn serve(self: *ReverseProxy, io: std.Io) !void {
        const address = try std.Io.net.IpAddress.parseLiteral(self.listen_addr);
        var listener = try std.Io.net.IpAddress.listen(&address, io, .{
            .reuse_address = true,
        });
        defer listener.deinit(io);

        log.info("listening on {s}", .{self.listen_addr});

        while (true) {
            var stream = listener.accept(io) catch |err| {
                log.err("accept failed: {}", .{err});
                continue;
            };

            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var in_reader = std.Io.net.Stream.reader(stream, io, &in_buf);
            var out_writer = std.Io.net.Stream.writer(stream, io, &out_buf);

            var server = http.Server.init(&in_reader.interface, &out_writer.interface);

            var request = server.receiveHead() catch |err| {
                log.err("receiveHead failed: {}", .{err});
                stream.close(io);
                continue;
            };

            dispatchRequest(self, io, &request) catch |err| {
                log.err("dispatch error: {}", .{err});
            };

            stream.close(io);
        }
    }

    fn dispatchRequest(self: *ReverseProxy, io: std.Io, request: *http.Server.Request) !void {
        const target = request.head.target;
        const route = openai.routePath(target) orelse {
            request.respond("not found", .{ .status = .not_found }) catch {};
            return;
        };

        switch (route) {
            .chat_completions, .completions => {
                try self.handleProxyRequest(io, request);
            },
            .models => {
                try self.handleModelsRequest(request);
            },
            .health => {
                try self.handleHealthRequest(request);
            },
            .metrics => {
                try self.handleMetricsRequest(io, request);
            },
        }
    }

    fn handleModelsRequest(self: *ReverseProxy, request: *http.Server.Request) !void {
        const body = try openai.buildModelsResponse(self.allocator, self.router);
        defer self.allocator.free(body);
        try request.respond(body, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
    }

    fn handleHealthRequest(self: *ReverseProxy, request: *http.Server.Request) !void {
        const has_backends = self.pool.backends.items.len > 0;
        const body = try openai.buildHealthResponse(self.allocator, has_backends);
        defer self.allocator.free(body);
        const status: http.Status = if (has_backends) .ok else .service_unavailable;
        try request.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
    }

    fn handleMetricsRequest(self: *ReverseProxy, io: std.Io, request: *http.Server.Request) !void {
        const body = try self.metrics.formatPrometheus(self.allocator, io);
        defer self.allocator.free(body);
        try request.respond(body, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
            },
        });
    }

    fn handleProxyRequest(self: *ReverseProxy, io: std.Io, request: *http.Server.Request) !void {
        const head = &request.head;

        self.metrics.recordRequest(io);

        var req_body_buf = std.ArrayList(u8).empty;
        defer req_body_buf.deinit(self.allocator);

        if (head.method.requestHasBody()) {
            var body_read_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_read_buf);
            try body_reader.appendRemainingUnlimited(self.allocator, &req_body_buf);
        }

        var model_name: ?[]const u8 = null;
        var prefix_hash: u64 = backend_pool.BackendEntry.NO_AFFINITY;

        if (req_body_buf.items.len > 0) {
            var chat_req = openai.ChatCompletionRequest.parse(self.allocator, req_body_buf.items) catch null;
            if (chat_req) |*cr| {
                defer cr.deinit(self.allocator);
                model_name = cr.model;
                prefix_hash = cr.prefix_hash;
            }
        }

        const now_ts = std.Io.Timestamp.now(io, .awake);
        const now_ms = now_ts.toMilliseconds();

        const backend_entry: ?*backend_pool.BackendEntry = if (model_name) |mn|
            self.router.selectBackendForModelWithTime(mn, self.pool, prefix_hash, now_ms) orelse self.pool.selectBackend()
        else
            self.pool.selectBackend();

        if (backend_entry) |be| {
            const is_cache_hit = prefix_hash != backend_pool.BackendEntry.NO_AFFINITY and
                be.prefix_affinity == prefix_hash and
                !be.isAffinityExpired(now_ms, self.router.cache_router.cache_ttl_ms);
            if (is_cache_hit) {
                self.metrics.recordCacheHit(io);
            } else if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY) {
                self.metrics.recordCacheMiss(io);
            }

            if (prefix_hash != backend_pool.BackendEntry.NO_AFFINITY) {
                const ts = std.Io.Timestamp.now(io, .awake);
                const ms = ts.toMilliseconds();
                be.updateAffinityWithTimestamp(prefix_hash, ms);
            }
            const backend_uri = std.Uri.parse(be.address) catch {
                request.respond("invalid backend address", .{
                    .status = .bad_gateway,
                }) catch {};
                return;
            };
            const ttft_start = std.Io.Timestamp.now(io, .awake);
            proxyToBackend(self.allocator, io, request, backend_uri, req_body_buf.items, be) catch |err| {
                log.err("proxy error: {}", .{err});
            };
            const ttft_end = std.Io.Timestamp.now(io, .awake);
            const ttft_us: u64 = @intCast(@divTrunc(ttft_end.toNanoseconds() - ttft_start.toNanoseconds(), 1000));
            if (is_cache_hit) {
                self.metrics.recordTTFTCacheHit(io, ttft_us);
            } else {
                self.metrics.recordTTFTCacheMiss(io, ttft_us);
            }
            return;
        }

        if (self.req_queue) |rq| {
            const enqueue_result = rq.enqueue(model_name orelse "default", now_ms) catch .overflow;
            if (enqueue_result == .overflow) {
                const overflow_body = request_queue.RequestQueue.buildOverflowBody(self.allocator) catch unreachable;
                defer self.allocator.free(overflow_body);
                request.respond(overflow_body, .{
                    .status = .service_unavailable,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                }) catch {};
                return;
            }
        }
        request.respond("no backend available", .{
            .status = .bad_gateway,
        }) catch {};
    }
};

fn proxyToBackend(
    allocator: mem.Allocator,
    io: std.Io,
    request: *http.Server.Request,
    backend_uri: std.Uri,
    req_body: []const u8,
    backend_entry: *backend_pool.BackendEntry,
) !void {
    const head = &request.head;

    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const target = head.target;
    var full_uri = backend_uri;
    const query_start = mem.indexOfScalar(u8, target, '?') orelse target.len;
    full_uri.path = .{ .percent_encoded = target[0..query_start] };
    if (query_start < target.len) {
        full_uri.query = .{ .percent_encoded = target[query_start + 1 ..] };
    }

    var redirect_buf: [8192]u8 = undefined;

    var fwd_headers = std.ArrayList(http.Header).empty;
    defer fwd_headers.deinit(allocator);

    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) continue;
        try fwd_headers.append(allocator, .{ .name = header.name, .value = header.value });
    }

    if (backend_uri.host != null) {
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host_name = full_uri.getHost(&host_buf) catch {
            backend_entry.recordPassiveFailure();
            try request.respond("invalid backend host", .{
                .status = .bad_gateway,
            });
            return;
        };
        try fwd_headers.append(allocator, .{ .name = "host", .value = host_name.bytes });
    }

    var backend_req = client.request(head.method, full_uri, .{
        .extra_headers = fwd_headers.items,
        .redirect_behavior = .unhandled,
    }) catch |err| {
        log.err("failed to connect to backend: {}", .{err});
        backend_entry.recordPassiveFailure();
        request.respond("backend unavailable", .{
            .status = .bad_gateway,
        }) catch {};
        return;
    };
    defer backend_req.deinit();

    if (req_body.len > 0) {
        backend_req.sendBodyComplete(@as([]u8, @constCast(req_body))) catch |err| {
            log.err("failed to send request to backend: {}", .{err});
            backend_entry.recordPassiveFailure();
            request.respond("backend send failed", .{
                .status = .bad_gateway,
            }) catch {};
            return;
        };
    } else {
        backend_req.sendBodiless() catch |err| {
            log.err("failed to send bodiless request to backend: {}", .{err});
            backend_entry.recordPassiveFailure();
            request.respond("backend send failed", .{
                .status = .bad_gateway,
            }) catch {};
            return;
        };
    }

    var response = backend_req.receiveHead(&redirect_buf) catch |err| {
        log.err("failed to receive backend response: {}", .{err});
        backend_entry.recordPassiveFailure();
        request.respond("backend response failed", .{
            .status = .bad_gateway,
        }) catch {};
        return;
    };

    const resp_status = response.head.status;
    if (resp_status.class() == .server_error) {
        backend_entry.recordPassiveFailure();
    } else if (resp_status.class() == .client_error) {
        // client errors (4xx) are not backend health issues
    } else {
        backend_entry.recordSuccess();
    }

    var resp_headers = std.ArrayList(http.Header).empty;
    defer resp_headers.deinit(allocator);

    const resp_head = &response.head;
    var resp_it = http.HeaderIterator.init(resp_head.bytes);
    while (resp_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "transfer-encoding")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-encoding")) continue;
        try resp_headers.append(allocator, .{ .name = header.name, .value = header.value });
    }

    const is_sse = isSSEContentType(resp_head.content_type);
    const is_chunked = resp_head.transfer_encoding == .chunked;

    if (is_sse or is_chunked) {
        try proxyStreamResponse(allocator, io, request, &backend_req, &response, resp_headers.items);
    } else {
        try proxyBufferedResponse(allocator, io, request, &backend_req, &response, resp_headers.items);
    }
}

pub fn isSSEContentType(content_type: ?[]const u8) bool {
    const ct = content_type orelse "";
    return mem.indexOf(u8, ct, "text/event-stream") != null;
}

fn proxyStreamResponse(
    allocator: mem.Allocator,
    io: std.Io,
    request: *http.Server.Request,
    backend_req: *http.Client.Request,
    response: *http.Client.Response,
    extra_headers: []const http.Header,
) !void {
    _ = allocator;
    _ = io;

    var stream_buf: [8192]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .status = response.head.status,
            .extra_headers = extra_headers,
            .transfer_encoding = .chunked,
        },
    });

    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    _ = reader.streamRemaining(&body_writer.writer) catch {};
    try body_writer.end();

    _ = backend_req;
}

fn proxyBufferedResponse(
    allocator: mem.Allocator,
    io: std.Io,
    request: *http.Server.Request,
    backend_req: *http.Client.Request,
    response: *http.Client.Response,
    extra_headers: []const http.Header,
) !void {
    _ = io;

    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(allocator);

    try reader.appendRemainingUnlimited(allocator, &body_buf);

    try request.respond(body_buf.items, .{
        .status = response.head.status,
        .extra_headers = extra_headers,
    });

    _ = backend_req;
}

test "isSSEContentType detects text/event-stream" {
    try std.testing.expect(isSSEContentType("text/event-stream"));
    try std.testing.expect(isSSEContentType("text/event-stream; charset=utf-8"));
}

test "isSSEContentType returns false for non-SSE content type" {
    try std.testing.expect(!isSSEContentType("application/json"));
}

test "isSSEContentType returns false for null" {
    try std.testing.expect(!isSSEContentType(null));
}
