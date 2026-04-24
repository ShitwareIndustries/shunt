const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const log = std.log;

pub const LoadProfile = enum {
    steady,
    burst,
    ramp,
};

pub const BenchConfig = struct {
    target: []const u8 = "http://127.0.0.1:8080",
    direct_target: ?[]const u8 = null,
    model: []const u8 = "gpt-4",
    requests: u32 = 1000,
    concurrency: u32 = 10,
    profile: LoadProfile = .steady,
    duration_secs: u32 = 10,
    ramp_steps: u32 = 5,
    burst_size: u32 = 50,
    burst_intervals: u32 = 5,
    mock: bool = false,
    output_format: enum { table, json, both } = .both,
    system_prompt: []const u8 = "You are a helpful assistant.",

    pub fn parseArgs(iter: *std.process.Args.Iterator) !BenchConfig {
        var config = BenchConfig{};
        while (iter.next()) |arg| {
            if (mem.eql(u8, arg, "--target")) {
                config.target = iter.next() orelse return error.MissingArgument;
            } else if (mem.eql(u8, arg, "--direct-target")) {
                config.direct_target = iter.next() orelse return error.MissingArgument;
            } else if (mem.eql(u8, arg, "--model")) {
                config.model = iter.next() orelse return error.MissingArgument;
            } else if (mem.eql(u8, arg, "--requests")) {
                const val = iter.next() orelse return error.MissingArgument;
                config.requests = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (mem.eql(u8, arg, "--concurrency")) {
                const val = iter.next() orelse return error.MissingArgument;
                config.concurrency = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (mem.eql(u8, arg, "--profile")) {
                const val = iter.next() orelse return error.MissingArgument;
                if (mem.eql(u8, val, "steady")) {
                    config.profile = .steady;
                } else if (mem.eql(u8, val, "burst")) {
                    config.profile = .burst;
                } else if (mem.eql(u8, val, "ramp")) {
                    config.profile = .ramp;
                } else {
                    return error.InvalidArgument;
                }
            } else if (mem.eql(u8, arg, "--duration")) {
                const val = iter.next() orelse return error.MissingArgument;
                config.duration_secs = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (mem.eql(u8, arg, "--ramp-steps")) {
                const val = iter.next() orelse return error.MissingArgument;
                config.ramp_steps = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (mem.eql(u8, arg, "--burst-size")) {
                const val = iter.next() orelse return error.MissingArgument;
                config.burst_size = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (mem.eql(u8, arg, "--burst-intervals")) {
                const val = iter.next() orelse return error.MissingArgument;
                config.burst_intervals = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgument;
            } else if (mem.eql(u8, arg, "--mock")) {
                config.mock = true;
            } else if (mem.eql(u8, arg, "--output")) {
                const val = iter.next() orelse return error.MissingArgument;
                if (mem.eql(u8, val, "table")) {
                    config.output_format = .table;
                } else if (mem.eql(u8, val, "json")) {
                    config.output_format = .json;
                } else if (mem.eql(u8, val, "both")) {
                    config.output_format = .both;
                } else {
                    return error.InvalidArgument;
                }
            } else if (mem.eql(u8, arg, "--system-prompt")) {
                config.system_prompt = iter.next() orelse return error.MissingArgument;
            } else if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
                std.debug.print(
                    \\shunt-bench — LLM load balancer benchmark suite
                    \\
                    \\Usage: shunt-bench [options]
                    \\
                    \\Options:
                    \\  --target <url>          Shunt endpoint (default: http://127.0.0.1:8080)
                    \\  --direct-target <url>   Direct backend URL for overhead comparison
                    \\  --model <name>          Model name for requests (default: gpt-4)
                    \\  --requests <n>          Total requests (default: 1000)
                    \\  --concurrency <n>       Concurrent connections (default: 10)
                    \\  --profile <type>        Load profile: steady|burst|ramp (default: steady)
                    \\  --duration <secs>       Benchmark duration in seconds (default: 10)
                    \\  --ramp-steps <n>        Steps for ramp profile (default: 5)
                    \\  --burst-size <n>        Requests per burst (default: 50)
                    \\  --burst-intervals <n>   Number of burst intervals (default: 5)
                    \\  --mock                  Run mock benchmark without real backends
                    \\  --output <fmt>          Output format: table|json|both (default: both)
                    \\  --system-prompt <text>  System prompt for cache testing
                    \\  --help                  Show this help
                    \\
                , .{});
                std.process.exit(0);
            }
        }
        return config;
    }
};

pub const LatencySample = struct {
    latency_us: u64,
    ttft_us: u64,
    status: u16,
    is_cache_hit: bool,
    queue_wait_us: u64 = 0,
};

pub const BenchResult = struct {
    total_requests: u32,
    successful_requests: u32,
    failed_requests: u32,
    elapsed_ms: u64,
    requests_per_sec: f64,
    latencies: []u64,
    ttft_samples: []u64,
    queue_wait_samples: []u64,
    cache_hits: u32,
    cache_misses: u32,
    p50_latency_us: u64,
    p90_latency_us: u64,
    p99_latency_us: u64,
    min_latency_us: u64,
    max_latency_us: u64,
    avg_latency_us: u64,
    p50_ttft_us: u64,
    p90_ttft_us: u64,
    p99_ttft_us: u64,
    avg_ttft_us: u64,
    p50_queue_wait_us: u64,
    p90_queue_wait_us: u64,
    p99_queue_wait_us: u64,
    avg_queue_wait_us: u64,
    cache_hit_rate: f64,
    overhead_pct: ?f64,

    pub fn compute(allocator: mem.Allocator, samples: []const LatencySample, elapsed_ms: u64, direct_avg_us: ?u64) !BenchResult {
        const successful = countSuccessful(samples);
        const failed = samples.len - successful;

        var latency_buf = try allocator.alloc(u64, samples.len);
        var ttft_buf = try allocator.alloc(u64, samples.len);
        var queue_buf = try allocator.alloc(u64, samples.len);
        var cache_hits: u32 = 0;
        var cache_misses: u32 = 0;
        var latency_sum: u64 = 0;
        var ttft_sum: u64 = 0;
        var queue_sum: u64 = 0;
        var valid_latency: usize = 0;
        var valid_ttft: usize = 0;
        var valid_queue: usize = 0;

        for (samples) |s| {
            if (s.status >= 200 and s.status < 500) {
                latency_buf[valid_latency] = s.latency_us;
                latency_sum += s.latency_us;
                valid_latency += 1;
            }
            if (s.ttft_us > 0) {
                ttft_buf[valid_ttft] = s.ttft_us;
                ttft_sum += s.ttft_us;
                valid_ttft += 1;
            }
            if (s.queue_wait_us > 0) {
                queue_buf[valid_queue] = s.queue_wait_us;
                queue_sum += s.queue_wait_us;
                valid_queue += 1;
            }
            if (s.is_cache_hit) {
                cache_hits += 1;
            } else if (s.status >= 200 and s.status < 500) {
                cache_misses += 1;
            }
        }

        sortSlice(u64, latency_buf[0..valid_latency]);
        sortSlice(u64, ttft_buf[0..valid_ttft]);
        sortSlice(u64, queue_buf[0..valid_queue]);

        const rps: f64 = if (elapsed_ms > 0)
            @as(f64, @floatFromInt(successful)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0)
        else
            0.0;

        const total_cache: u32 = cache_hits + cache_misses;
        const hit_rate: f64 = if (total_cache > 0)
            @as(f64, @floatFromInt(cache_hits)) / @as(f64, @floatFromInt(total_cache))
        else
            0.0;

        const avg_lat: u64 = if (valid_latency > 0) @divTrunc(latency_sum, valid_latency) else 0;
        const avg_ttft: u64 = if (valid_ttft > 0) @divTrunc(ttft_sum, valid_ttft) else 0;
        const avg_queue: u64 = if (valid_queue > 0) @divTrunc(queue_sum, valid_queue) else 0;

        var overhead: ?f64 = null;
        if (direct_avg_us) |direct| {
            if (direct > 0) {
                overhead = (@as(f64, @floatFromInt(avg_lat)) - @as(f64, @floatFromInt(direct))) / @as(f64, @floatFromInt(direct)) * 100.0;
            }
        }

        return .{
            .total_requests = @intCast(samples.len),
            .successful_requests = successful,
            .failed_requests = @intCast(failed),
            .elapsed_ms = elapsed_ms,
            .requests_per_sec = rps,
            .latencies = latency_buf,
            .ttft_samples = ttft_buf,
            .queue_wait_samples = queue_buf,
            .cache_hits = cache_hits,
            .cache_misses = cache_misses,
            .p50_latency_us = percentile(latency_buf[0..valid_latency], 50),
            .p90_latency_us = percentile(latency_buf[0..valid_latency], 90),
            .p99_latency_us = percentile(latency_buf[0..valid_latency], 99),
            .min_latency_us = if (valid_latency > 0) latency_buf[0] else 0,
            .max_latency_us = if (valid_latency > 0) latency_buf[valid_latency - 1] else 0,
            .avg_latency_us = avg_lat,
            .p50_ttft_us = percentile(ttft_buf[0..valid_ttft], 50),
            .p90_ttft_us = percentile(ttft_buf[0..valid_ttft], 90),
            .p99_ttft_us = percentile(ttft_buf[0..valid_ttft], 99),
            .avg_ttft_us = avg_ttft,
            .p50_queue_wait_us = percentile(queue_buf[0..valid_queue], 50),
            .p90_queue_wait_us = percentile(queue_buf[0..valid_queue], 90),
            .p99_queue_wait_us = percentile(queue_buf[0..valid_queue], 99),
            .avg_queue_wait_us = avg_queue,
            .cache_hit_rate = hit_rate,
            .overhead_pct = overhead,
        };
    }

    pub fn deinit(self: *BenchResult, allocator: mem.Allocator) void {
        allocator.free(self.latencies);
        allocator.free(self.ttft_samples);
        allocator.free(self.queue_wait_samples);
    }

    pub fn formatTable(self: BenchResult, writer: anytype) !void {
        try writer.print(
            \\╔══════════════════════════════════════════════════════╗
            \\║           shunt benchmark results                  ║
            \\╠════════════════════════════════════════════════════╣
            \\║ summary                                             ║
            \\╠════════════════════════════════════════════════════╣
        , .{});
        try writer.print("║ total requests     {:>10}                       ║\n", .{self.total_requests});
        try writer.print("║ successful         {:>10}                       ║\n", .{self.successful_requests});
        try writer.print("║ failed             {:>10}                       ║\n", .{self.failed_requests});
        try writer.print("║ elapsed            {:>10} ms                     ║\n", .{self.elapsed_ms});
        try writer.print("║ throughput         {:>10.1} req/s                  ║\n", .{self.requests_per_sec});
        try writer.print(
            \\╠════════════════════════════════════════════════════╣
            \\║ latency (µs)                                        ║
            \\╠════════════════════════════════════════════════════╣
        , .{});
        try writer.print("║ min                {:>10}                       ║\n", .{self.min_latency_us});
        try writer.print("║ avg                {:>10}                       ║\n", .{self.avg_latency_us});
        try writer.print("║ p50                {:>10}                       ║\n", .{self.p50_latency_us});
        try writer.print("║ p90                {:>10}                       ║\n", .{self.p90_latency_us});
        try writer.print("║ p99                {:>10}                       ║\n", .{self.p99_latency_us});
        try writer.print("║ max                {:>10}                       ║\n", .{self.max_latency_us});
        try writer.print(
            \\╠════════════════════════════════════════════════════╣
            \\║ time to first token (µs)                            ║
            \\╠════════════════════════════════════════════════════╣
        , .{});
        try writer.print("║ avg                {:>10}                       ║\n", .{self.avg_ttft_us});
        try writer.print("║ p50                {:>10}                       ║\n", .{self.p50_ttft_us});
        try writer.print("║ p90                {:>10}                       ║\n", .{self.p90_ttft_us});
        try writer.print("║ p99                {:>10}                       ║\n", .{self.p99_ttft_us});
        try writer.print(
            \\╠════════════════════════════════════════════════════╣
            \\║ queue wait (µs)                                     ║
            \\╠════════════════════════════════════════════════════╣
        , .{});
        try writer.print("║ avg                {:>10}                       ║\n", .{self.avg_queue_wait_us});
        try writer.print("║ p50                {:>10}                       ║\n", .{self.p50_queue_wait_us});
        try writer.print("║ p90                {:>10}                       ║\n", .{self.p90_queue_wait_us});
        try writer.print("║ p99                {:>10}                       ║\n", .{self.p99_queue_wait_us});
        try writer.print(
            \\╠════════════════════════════════════════════════════╣
            \\║ cache                                               ║
            \\╠════════════════════════════════════════════════════╣
        , .{});
        try writer.print("║ hits               {:>10}                       ║\n", .{self.cache_hits});
        try writer.print("║ misses             {:>10}                       ║\n", .{self.cache_misses});
        try writer.print("║ hit rate           {:>10.1} %                     ║\n", .{self.cache_hit_rate * 100.0});
        if (self.overhead_pct) |oh| {
            try writer.print(
                \\╠════════════════════════════════════════════════════╣
                \\║ overhead vs direct                                  ║
                \\╠════════════════════════════════════════════════════╣
            , .{});
            try writer.print("║ overhead           {:>10.1} %                     ║\n", .{oh});
        }
        try writer.print("╚════════════════════════════════════════════════════╝\n", .{});
    }

    pub fn formatJson(self: BenchResult, allocator: mem.Allocator) ![]u8 {
        const LatencyStats = struct {
            min_us: i64,
            avg_us: i64,
            p50_us: i64,
            p90_us: i64,
            p99_us: i64,
            max_us: i64,
        };
        const PercentileStats = struct {
            avg_us: i64,
            p50_us: i64,
            p90_us: i64,
            p99_us: i64,
        };
        const CacheStats = struct {
            hits: i64,
            misses: i64,
            hit_rate: f64,
        };
        const ResultJson = struct {
            total_requests: u32,
            successful_requests: u32,
            failed_requests: u32,
            elapsed_ms: i64,
            requests_per_sec: f64,
            latency: LatencyStats,
            ttft: PercentileStats,
            queue_wait: PercentileStats,
            cache: CacheStats,
            overhead_pct: ?f64,
        };
        const data = ResultJson{
            .total_requests = self.total_requests,
            .successful_requests = self.successful_requests,
            .failed_requests = self.failed_requests,
            .elapsed_ms = @as(i64, @intCast(self.elapsed_ms)),
            .requests_per_sec = self.requests_per_sec,
            .latency = .{
                .min_us = @as(i64, @intCast(self.min_latency_us)),
                .avg_us = @as(i64, @intCast(self.avg_latency_us)),
                .p50_us = @as(i64, @intCast(self.p50_latency_us)),
                .p90_us = @as(i64, @intCast(self.p90_latency_us)),
                .p99_us = @as(i64, @intCast(self.p99_latency_us)),
                .max_us = @as(i64, @intCast(self.max_latency_us)),
            },
            .ttft = .{
                .avg_us = @as(i64, @intCast(self.avg_ttft_us)),
                .p50_us = @as(i64, @intCast(self.p50_ttft_us)),
                .p90_us = @as(i64, @intCast(self.p90_ttft_us)),
                .p99_us = @as(i64, @intCast(self.p99_ttft_us)),
            },
            .queue_wait = .{
                .avg_us = @as(i64, @intCast(self.avg_queue_wait_us)),
                .p50_us = @as(i64, @intCast(self.p50_queue_wait_us)),
                .p90_us = @as(i64, @intCast(self.p90_queue_wait_us)),
                .p99_us = @as(i64, @intCast(self.p99_queue_wait_us)),
            },
            .cache = .{
                .hits = @as(i64, @intCast(self.cache_hits)),
                .misses = @as(i64, @intCast(self.cache_misses)),
                .hit_rate = self.cache_hit_rate,
            },
            .overhead_pct = self.overhead_pct,
        };
        return json.Stringify.valueAlloc(allocator, data, .{});
    }
};

fn countSuccessful(samples: []const LatencySample) u32 {
    var count: u32 = 0;
    for (samples) |s| {
        if (s.status >= 200 and s.status < 400) count += 1;
    }
    return count;
}

fn sortSlice(comptime T: type, slice: []T) void {
    if (slice.len <= 1) return;
    std.sort.insertion(T, slice, {}, struct {
        fn lessThan(ctx: void, a: T, b: T) bool {
            _ = ctx;
            return a < b;
        }
    }.lessThan);
}

pub fn percentile(sorted: []const u64, p: u8) u64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const rank = @as(f64, @floatFromInt(p)) / 100.0 * @as(f64, @floatFromInt(sorted.len - 1));
    const lower: usize = @intFromFloat(@floor(rank));
    const upper = @min(sorted.len - 1, lower + 1);
    const frac = rank - @as(f64, @floatFromInt(lower));
    const low: f64 = @floatFromInt(sorted[lower]);
    const high: f64 = @floatFromInt(sorted[upper]);
    return @intFromFloat(low + (high - low) * frac);
}

pub const MockBackend = struct {
    allocator: mem.Allocator,
    listen_addr: []const u8 = "127.0.0.1:18081",
    latency_us: u64 = 1000,
    variance_us: u64 = 200,

    pub fn run(self: *MockBackend, io: std.Io) !void {
        const address = try std.Io.net.IpAddress.parseLiteral(self.listen_addr);
        var listener = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        defer listener.deinit(io);

        log.info("mock backend listening on {s}", .{self.listen_addr});

        while (true) {
            var stream = listener.accept(io) catch |err| {
                log.err("mock accept failed: {}", .{err});
                continue;
            };

            var in_buf: [4096]u8 = undefined;
            var out_buf: [4096]u8 = undefined;
            var in_reader = std.Io.net.Stream.reader(stream, io, &in_buf);
            var out_writer = std.Io.net.Stream.writer(stream, io, &out_buf);
            var server = http.Server.init(&in_reader.interface, &out_writer.interface);

            var request = server.receiveHead() catch |err| {
                log.err("mock receiveHead failed: {}", .{err});
                stream.close(io);
                continue;
            };

            const target = request.head.target;
            if (mem.startsWith(u8, target, "/v1/chat/completions")) {
                const body =
                    \\{"id":"chatcmpl-mock","object":"chat.completion","created":0,"model":"gpt-4","choices":[{"index":0,"message":{"role":"assistant","content":"Hello!"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}
                ;
                request.respond(body, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                }) catch {};
            } else if (mem.startsWith(u8, target, "/v1/models")) {
                const body =
                    \\{"object":"list","data":[{"id":"gpt-4","object":"model","owned_by":"mock"}]}
                ;
                request.respond(body, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                }) catch {};
            } else if (mem.startsWith(u8, target, "/health")) {
                request.respond("{\"status\":\"ok\"}", .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                }) catch {};
            } else {
                request.respond("not found", .{ .status = .not_found }) catch {};
            }

            stream.close(io);
        }
    }
};

pub const BenchRunner = struct {
    allocator: mem.Allocator,
    config: BenchConfig,
    samples: std.ArrayList(LatencySample),
    mock_latency_us: u64 = 1000,
    mock_variance_us: u64 = 200,

    pub fn init(allocator: mem.Allocator, config: BenchConfig) BenchRunner {
        return .{
            .allocator = allocator,
            .config = config,
            .samples = .empty,
        };
    }

    pub fn deinit(self: *BenchRunner) void {
        self.samples.deinit(self.allocator);
    }

    pub fn run(self: *BenchRunner, io: std.Io) !?BenchResult {
        log.info("benchmark config: profile={s} requests={} concurrency={} model={s} target={s} mock={}", .{
            @tagName(self.config.profile),
            self.config.requests,
            self.config.concurrency,
            self.config.model,
            self.config.target,
            self.config.mock,
        });

        if (self.config.mock) {
            self.config.target = "http://127.0.0.1:18081";
        }

        const start_ts = std.Io.Timestamp.now(io, .awake);

        switch (self.config.profile) {
            .steady => try self.runSteady(io),
            .burst => try self.runBurst(io),
            .ramp => try self.runRamp(io),
        }

        const end_ts = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns = end_ts.toNanoseconds() - start_ts.toNanoseconds();
        const elapsed_ms: u64 = @intCast(@divTrunc(elapsed_ns, 1_000_000));

        var direct_avg: ?u64 = null;
        if (self.config.direct_target) |dt| {
            log.info("running direct backend benchmark for overhead comparison...", .{});
            const direct_samples = self.runDirectBenchmark(io, dt) catch |err| blk: {
                log.warn("direct benchmark failed: {}", .{err});
                break :blk null;
            };
            if (direct_samples) |ds| {
                var sum: u64 = 0;
                for (ds) |s| sum += s.latency_us;
                direct_avg = if (ds.len > 0) @divTrunc(sum, ds.len) else null;
                self.allocator.free(ds);
            }
        }

        const result = try BenchResult.compute(self.allocator, self.samples.items, elapsed_ms, direct_avg);
        return result;
    }

    fn runSteady(self: *BenchRunner, io: std.Io) !void {
        log.info("steady profile: {} requests at concurrency {}", .{ self.config.requests, self.config.concurrency });
        var idx: u32 = 0;
        while (idx < self.config.requests) : (idx += 1) {
            try self.sendRequest(io);
        }
    }

    fn runBurst(self: *BenchRunner, io: std.Io) !void {
        log.info("burst profile: {} bursts of {} requests", .{ self.config.burst_intervals, self.config.burst_size });
        var burst: u32 = 0;
        while (burst < self.config.burst_intervals) : (burst += 1) {
            var i: u32 = 0;
            while (i < self.config.burst_size and self.samples.items.len < self.config.requests) : (i += 1) {
                try self.sendRequest(io);
            }
            if (burst < self.config.burst_intervals - 1) {
                const pause = std.Io.Duration.fromSeconds(1);
                std.Io.sleep(io, pause, .awake) catch {};
            }
        }
    }

    fn runRamp(self: *BenchRunner, io: std.Io) !void {
        const requests_per_step = @divTrunc(self.config.requests, self.config.ramp_steps);
        log.info("ramp profile: {} steps of {} requests", .{ self.config.ramp_steps, requests_per_step });
        var step: u32 = 0;
        while (step < self.config.ramp_steps) : (step += 1) {
            var i: u32 = 0;
            while (i < requests_per_step and self.samples.items.len < self.config.requests) : (i += 1) {
                try self.sendRequest(io);
            }
            if (step < self.config.ramp_steps - 1) {
                const pause = std.Io.Duration.fromSeconds(1);
                std.Io.sleep(io, pause, .awake) catch {};
            }
        }
    }

    fn sendRequest(self: *BenchRunner, io: std.Io) !void {
        if (self.config.mock) return self.sendMockRequest(io);

        const request_body = try self.buildRequestBody();
        defer self.allocator.free(request_body);

        const uri = std.Uri.parse(self.config.target) catch {
            try self.samples.append(self.allocator, .{
                .latency_us = 0,
                .ttft_us = 0,
                .status = 0,
                .is_cache_hit = false,
            });
            return;
        };

        const start_ts = std.Io.Timestamp.now(io, .awake);

        var client: http.Client = .{ .allocator = self.allocator, .io = io };
        defer client.deinit();

        var req = client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
            .redirect_behavior = .unhandled,
        }) catch |err| {
            log.debug("request connection failed: {}", .{err});
            try self.samples.append(self.allocator, .{
                .latency_us = 0,
                .ttft_us = 0,
                .status = 0,
                .is_cache_hit = false,
            });
            return;
        };
        defer req.deinit();

        req.sendBodyComplete(@as([]u8, @constCast(request_body))) catch |err| {
            log.debug("send failed: {}", .{err});
            try self.samples.append(self.allocator, .{
                .latency_us = 0,
                .ttft_us = 0,
                .status = 0,
                .is_cache_hit = false,
            });
            return;
        };

        var redirect_buf: [8192]u8 = undefined;
        var resp = req.receiveHead(&redirect_buf) catch |err| {
            log.debug("receive head failed: {}", .{err});
            try self.samples.append(self.allocator, .{
                .latency_us = 0,
                .ttft_us = 0,
                .status = 0,
                .is_cache_hit = false,
            });
            return;
        };

        const ttft_ts = std.Io.Timestamp.now(io, .awake);
        const ttft_us: u64 = @intCast(@divTrunc(ttft_ts.toNanoseconds() - start_ts.toNanoseconds(), 1000));

        const status: u16 = @intFromEnum(resp.head.status);

        var transfer_buf: [4096]u8 = undefined;
        const reader = resp.reader(&transfer_buf);
        var body_buf = std.ArrayList(u8).empty;
        defer body_buf.deinit(self.allocator);
        reader.appendRemainingUnlimited(self.allocator, &body_buf) catch {};

        const end_ts = std.Io.Timestamp.now(io, .awake);
        const latency_us: u64 = @intCast(@divTrunc(end_ts.toNanoseconds() - start_ts.toNanoseconds(), 1000));

        var is_cache_hit = false;
        if (body_buf.items.len > 0) {
            const parsed = json.parseFromSlice(json.Value, self.allocator, body_buf.items, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("cache_hit")) |v| {
                        switch (v) {
                            .bool => |b| is_cache_hit = b,
                            else => {},
                        }
                    }
                }
            }
        }

        try self.samples.append(self.allocator, .{
            .latency_us = latency_us,
            .ttft_us = ttft_us,
            .status = status,
            .is_cache_hit = is_cache_hit,
        });
    }

    fn sendMockRequest(self: *BenchRunner, io: std.Io) !void {
        const start_ts = std.Io.Timestamp.now(io, .awake);
        const rng_source = std.Random.IoSource{ .io = io };
        const rng = rng_source.interface();
        const base_ns: i96 = @intCast(self.mock_latency_us * 1000);
        const variance_ns: i96 = @intCast(self.mock_variance_us * 1000);
        const raw_jitter = @mod(rng.int(i96), variance_ns * 2);
        const jitter: i96 = raw_jitter - variance_ns;
        const sleep_ns: i96 = @max(base_ns + jitter, 0);
        const sleep_dur = std.Io.Duration{ .nanoseconds = sleep_ns };
        std.Io.sleep(io, sleep_dur, .awake) catch {};
        const end_ts = std.Io.Timestamp.now(io, .awake);
        const latency_us: u64 = @intCast(@divTrunc(end_ts.toNanoseconds() - start_ts.toNanoseconds(), 1000));
        const ttft_us: u64 = @intCast(@divTrunc(latency_us, 2));
        const cache_roll = rng.int(u32) % 100;
        const is_cache_hit = cache_roll < 15;
        const queue_wait: u64 = if (rng.int(u32) % 5 == 0) rng.intRangeAtMost(u64, 50, 500) else 0;
        try self.samples.append(self.allocator, .{
            .latency_us = latency_us,
            .ttft_us = ttft_us,
            .status = 200,
            .is_cache_hit = is_cache_hit,
            .queue_wait_us = queue_wait,
        });
    }

    fn runDirectBenchmark(self: *BenchRunner, io: std.Io, direct_target: []const u8) ![]LatencySample {
        const n: u32 = @min(self.config.requests, 100);
        var samples = try self.allocator.alloc(LatencySample, n);
        errdefer self.allocator.free(samples);

        const request_body = try self.buildRequestBody();
        defer self.allocator.free(request_body);

        const uri = std.Uri.parse(direct_target) catch return error.InvalidUri;

        for (0..n) |i| {
            const start_ts = std.Io.Timestamp.now(io, .awake);

            var client: http.Client = .{ .allocator = self.allocator, .io = io };
            defer client.deinit();

            var req = client.request(.POST, uri, .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
                .redirect_behavior = .unhandled,
            }) catch {
                samples[i] = .{ .latency_us = 0, .ttft_us = 0, .status = 0, .is_cache_hit = false };
                continue;
            };
            defer req.deinit();

            req.sendBodyComplete(@as([]u8, @constCast(request_body))) catch {
                samples[i] = .{ .latency_us = 0, .ttft_us = 0, .status = 0, .is_cache_hit = false };
                continue;
            };

            var redirect_buf: [8192]u8 = undefined;
            var resp = req.receiveHead(&redirect_buf) catch {
                samples[i] = .{ .latency_us = 0, .ttft_us = 0, .status = 0, .is_cache_hit = false };
                continue;
            };

            const ttft_ts = std.Io.Timestamp.now(io, .awake);
            const ttft_us: u64 = @intCast(@divTrunc(ttft_ts.toNanoseconds() - start_ts.toNanoseconds(), 1000));
            const status: u16 = @intFromEnum(resp.head.status);

            var transfer_buf: [4096]u8 = undefined;
            const reader = resp.reader(&transfer_buf);
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(self.allocator);
            reader.appendRemainingUnlimited(self.allocator, &body_buf) catch {};

            const end_ts = std.Io.Timestamp.now(io, .awake);
            const latency_us: u64 = @intCast(@divTrunc(end_ts.toNanoseconds() - start_ts.toNanoseconds(), 1000));

            samples[i] = .{
                .latency_us = latency_us,
                .ttft_us = ttft_us,
                .status = status,
                .is_cache_hit = false,
            };
        }

        return samples;
    }

    fn buildRequestBody(self: *BenchRunner) ![]u8 {
        const body_fmt =
            \\{{"model":"{s}","messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"Write a short greeting."}}],"stream":false}}
        ;
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try buf.print(self.allocator, body_fmt, .{ self.config.model, self.config.system_prompt });
        return try buf.toOwnedSlice(self.allocator);
    }
};

test "percentile returns correct values" {
    const data = [_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try std.testing.expect(percentile(&data, 0) == 10);
    try std.testing.expect(percentile(&data, 50) == 55);
    try std.testing.expect(percentile(&data, 100) == 100);
}

test "percentile handles empty slice" {
    const data = [_]u64{};
    try std.testing.expect(percentile(&data, 50) == 0);
}

test "percentile handles single element" {
    const data = [_]u64{42};
    try std.testing.expect(percentile(&data, 50) == 42);
}

test "sortSlice sorts u64 array" {
    var data = [_]u64{ 5, 3, 8, 1, 9, 2 };
    sortSlice(u64, &data);
    try std.testing.expect(data[0] == 1);
    try std.testing.expect(data[5] == 9);
}

test "BenchConfig defaults" {
    const config = BenchConfig{};
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", config.target);
    try std.testing.expect(config.requests == 1000);
    try std.testing.expect(config.concurrency == 10);
    try std.testing.expect(config.profile == .steady);
    try std.testing.expect(config.mock == false);
}

test "countSuccessful counts 2xx and 3xx" {
    const samples = [_]LatencySample{
        .{ .latency_us = 100, .ttft_us = 50, .status = 200, .is_cache_hit = false },
        .{ .latency_us = 200, .ttft_us = 100, .status = 500, .is_cache_hit = false },
        .{ .latency_us = 150, .ttft_us = 75, .status = 301, .is_cache_hit = false },
        .{ .latency_us = 0, .ttft_us = 0, .status = 0, .is_cache_hit = false },
    };
    try std.testing.expect(countSuccessful(&samples) == 2);
}

test "BenchResult.compute calculates percentiles" {
    const allocator = std.testing.allocator;
    const samples = [_]LatencySample{
        .{ .latency_us = 100, .ttft_us = 50, .status = 200, .is_cache_hit = true },
        .{ .latency_us = 200, .ttft_us = 100, .status = 200, .is_cache_hit = false },
        .{ .latency_us = 300, .ttft_us = 150, .status = 200, .is_cache_hit = true },
        .{ .latency_us = 400, .ttft_us = 200, .status = 200, .is_cache_hit = false },
        .{ .latency_us = 500, .ttft_us = 250, .status = 200, .is_cache_hit = true },
    };
    var result = try BenchResult.compute(allocator, &samples, 1000, null);
    defer result.deinit(allocator);
    try std.testing.expect(result.total_requests == 5);
    try std.testing.expect(result.successful_requests == 5);
    try std.testing.expect(result.failed_requests == 0);
    try std.testing.expect(result.cache_hits == 3);
    try std.testing.expect(result.cache_misses == 2);
    try std.testing.expect(result.min_latency_us == 100);
    try std.testing.expect(result.max_latency_us == 500);
    try std.testing.expect(result.avg_latency_us == 300);
    try std.testing.expect(result.p50_latency_us == 300);
    try std.testing.expect(result.requests_per_sec > 0);
}

test "BenchResult.compute with direct overhead" {
    const allocator = std.testing.allocator;
    const samples = [_]LatencySample{
        .{ .latency_us = 2000, .ttft_us = 500, .status = 200, .is_cache_hit = false },
    };
    var result = try BenchResult.compute(allocator, &samples, 100, 1000);
    defer result.deinit(allocator);
    try std.testing.expect(result.overhead_pct != null);
    const oh = result.overhead_pct.?;
    try std.testing.expect(oh > 99.0 and oh < 101.0);
}

test "BenchResult.formatJson produces valid JSON" {
    const allocator = std.testing.allocator;
    const samples = [_]LatencySample{
        .{ .latency_us = 100, .ttft_us = 50, .status = 200, .is_cache_hit = true },
        .{ .latency_us = 200, .ttft_us = 80, .status = 200, .is_cache_hit = false },
    };
    var result = try BenchResult.compute(allocator, &samples, 500, null);
    defer result.deinit(allocator);
    const json_str = try result.formatJson(allocator);
    defer allocator.free(json_str);
    const parsed = try json.parseFromSlice(json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("latency") != null);
    try std.testing.expect(parsed.value.object.get("ttft") != null);
    try std.testing.expect(parsed.value.object.get("cache") != null);
}
