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
    const log_format = shunt.cli.resolveLogFormat(cli_config, app_config.logging_format);
    const log_output = shunt.cli.resolveLogOutput(cli_config, app_config.logging_output);
    const max_buffered = shunt.cli.resolveMaxBufferedRequests(cli_config, app_config.max_buffered_requests);
    const buffered_timeout = shunt.cli.resolveBufferedRequestTimeout(cli_config, app_config.buffered_request_timeout_ms);

    var pool = shunt.backend_pool.BackendPool.init(allocator);
    defer pool.deinit();

    var router = if (app_config.cache_enabled)
        shunt.openai.ModelRouter.initWithTTL(allocator, app_config.cache_ttl_ms)
    else
        shunt.openai.ModelRouter.initDisabled(allocator);
    defer router.deinit();

    if (app_config.models.items.len > 0) {
        for (app_config.models.items, 0..) |m, i| {
            var entry: shunt.backend_pool.BackendEntry = .{
                .id = m.id,
                .address = m.address,
                .model = m.model,
                .backend_type = m.backend_type,
            };
            entry.defaultTimeouts();
            try pool.addBackend(entry);
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

    var auth_instance = shunt.auth.Auth.init(allocator);
    defer auth_instance.deinit();
    if (app_config.auth_enabled) {
        auth_instance.enabled = true;
        for (app_config.auth_keys.items) |ak| {
            auth_instance.addKey(ak.key, ak.rate_limit, ak.burst) catch |err| {
                std.log.err("failed to add auth key: {}", .{err});
            };
        }
    }

    var metrics_instance = shunt.metrics.Metrics.init();

    const logger_level = shunt.logger.Level.fromString(log_level) orelse .info;
    const logger_format = shunt.logger.Format.fromString(log_format) orelse .json;
    const logger_output = shunt.logger.Output.fromString(log_output) orelse .stdout;
    var logger_instance = shunt.logger.Logger.init(.{
        .level = logger_level,
        .format = logger_format,
        .output = logger_output,
    });

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

    const start_ts = std.Io.Timestamp.now(io, .awake);
    var kube_health_checker = shunt.health.KubeHealthChecker.init(&pool, @intCast(start_ts.toNanoseconds()));

    var server_proxy = shunt.proxy.ReverseProxy.init(allocator, &pool, &router, &metrics_instance, &logger_instance);
    server_proxy.listen_addr = listen_addr;
    server_proxy.req_queue = &req_queue;
    server_proxy.kube_health_checker = &kube_health_checker;
    server_proxy.auth = &auth_instance;

    std.log.info("llm-lb starting on {s} with {} backend(s), health check interval {}ms, log level {s} format {s} output {s}, queue capacity {} timeout {}ms", .{
        listen_addr,
        pool.backends.items.len,
        health_check_interval,
        log_level,
        log_format,
        log_output,
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
