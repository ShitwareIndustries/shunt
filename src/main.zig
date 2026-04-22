const std = @import("std");
const shunt = @import("shunt");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var cli_config = shunt.cli.parseArgsFromInit(init);
    shunt.cli.applyEnvOverrides(&cli_config, init.environ_map);

    var app_config: shunt.config.Config = if (cli_config.config_path) |path|
        loadConfigFile(allocator, io, path) catch |err| blk: {
            std.log.err("failed to load config from {s}: {}", .{ path, err });
            break :blk shunt.config.Config.init();
        }
    else
        shunt.config.Config.init();
    defer app_config.deinit(allocator);

    const listen_addr = shunt.cli.resolveListenAddr(cli_config, app_config.listen_addr);
    const health_check_interval = shunt.cli.resolveHealthCheckInterval(cli_config, app_config.health_check_interval_ms);
    const log_level = shunt.cli.resolveLogLevel(cli_config, app_config.log_level);
    const max_buffered = shunt.cli.resolveMaxBufferedRequests(cli_config, app_config.max_buffered_requests);
    const buffered_timeout = shunt.cli.resolveBufferedRequestTimeout(cli_config, app_config.buffered_request_timeout_ms);

    var pool = shunt.backend_pool.BackendPool.init(allocator);
    defer pool.deinit();

    var router = shunt.openai.ModelRouter.init(allocator);
    defer router.deinit();

    if (app_config.models.items.len > 0) {
        for (app_config.models.items, 0..) |m, i| {
            try pool.addBackend(.{
                .id = m.id,
                .address = m.address,
                .model = m.model,
            });
            try router.addBackendToGroup(m.model, i);
        }
    } else {
        try pool.addBackend(.{
            .id = "default",
            .address = "http://127.0.0.1:8081",
            .model = "default",
        });
        try router.addBackendToGroup("default", 0);
    }

    var req_queue = shunt.request_queue.RequestQueue.init(allocator, io, max_buffered, buffered_timeout);
    defer req_queue.deinit();

    var health_checker = shunt.HealthChecker{
        .allocator = allocator,
        .pool = &pool,
        .interval_ms = health_check_interval,
        .req_queue = &req_queue,
    };

    const hc_thread = std.Thread.spawn(.{}, shunt.HealthChecker.run, .{ &health_checker, io }) catch |err| blk: {
        std.log.err("failed to spawn health checker thread: {}", .{err});
        break :blk null;
    };
    if (hc_thread) |t| {
        t.detach();
    }

    var server_proxy = shunt.proxy.ReverseProxy.init(allocator, &pool, &router);
    server_proxy.listen_addr = listen_addr;
    server_proxy.req_queue = &req_queue;

    std.log.info("llm-lb starting on {s} with {} backend(s), health check interval {}ms, log level {s}, queue capacity {} timeout {}ms", .{
        listen_addr,
        pool.backends.items.len,
        health_check_interval,
        log_level,
        max_buffered,
        buffered_timeout,
    });

    try server_proxy.serve(io);
}

fn loadConfigFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !shunt.config.Config {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        std.log.err("failed to read config file {s}: {}", .{ path, err });
        return err;
    };
    defer allocator.free(contents);
    return shunt.config.parse(allocator, contents);
}
