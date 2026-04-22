const std = @import("std");
const mem = std.mem;
const process = std.process;

pub const CliConfig = struct {
    listen_addr: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    health_check_interval_ms: ?u64 = null,
    max_buffered_requests: ?usize = null,
    buffered_request_timeout_ms: ?u64 = null,
    log_level: ?[]const u8 = null,
};

const prefix_listen_addr = "--listen-addr=";
const prefix_config = "--config=";
const prefix_health_check = "--health-check-interval=";
const prefix_max_buffered = "--max-buffered-requests=";
const prefix_buffered_timeout = "--buffered-request-timeout=";
const prefix_log_level = "--log-level=";

pub fn parseArgs(args: []const []const u8) CliConfig {
    var cli = CliConfig{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, prefix_listen_addr)) {
            cli.listen_addr = arg[prefix_listen_addr.len..];
        } else if (mem.eql(u8, arg, "--listen-addr") and i + 1 < args.len) {
            i += 1;
            cli.listen_addr = args[i];
        } else if (mem.startsWith(u8, arg, prefix_config)) {
            cli.config_path = arg[prefix_config.len..];
        } else if (mem.eql(u8, arg, "--config") and i + 1 < args.len) {
            i += 1;
            cli.config_path = args[i];
        } else if (mem.startsWith(u8, arg, prefix_health_check)) {
            const val = arg[prefix_health_check.len..];
            cli.health_check_interval_ms = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (mem.eql(u8, arg, "--health-check-interval") and i + 1 < args.len) {
            i += 1;
            cli.health_check_interval_ms = std.fmt.parseInt(u64, args[i], 10) catch null;
        } else if (mem.startsWith(u8, arg, prefix_max_buffered)) {
            const val = arg[prefix_max_buffered.len..];
            cli.max_buffered_requests = std.fmt.parseInt(usize, val, 10) catch null;
        } else if (mem.eql(u8, arg, "--max-buffered-requests") and i + 1 < args.len) {
            i += 1;
            cli.max_buffered_requests = std.fmt.parseInt(usize, args[i], 10) catch null;
        } else if (mem.startsWith(u8, arg, prefix_buffered_timeout)) {
            const val = arg[prefix_buffered_timeout.len..];
            cli.buffered_request_timeout_ms = std.fmt.parseInt(u64, val, 10) catch null;
        } else if (mem.eql(u8, arg, "--buffered-request-timeout") and i + 1 < args.len) {
            i += 1;
            cli.buffered_request_timeout_ms = std.fmt.parseInt(u64, args[i], 10) catch null;
        } else if (mem.startsWith(u8, arg, prefix_log_level)) {
            cli.log_level = arg[prefix_log_level.len..];
        } else if (mem.eql(u8, arg, "--log-level") and i + 1 < args.len) {
            i += 1;
            cli.log_level = args[i];
        }
    }
    return cli;
}

pub fn applyEnvOverrides(cli: *CliConfig, environ_map: *process.Environ.Map) void {
    if (environ_map.get("LB_LISTEN_ADDR")) |val| {
        cli.listen_addr = val;
    }
    if (environ_map.get("LB_CONFIG")) |val| {
        cli.config_path = val;
    }
    if (environ_map.get("LB_HEALTH_CHECK_INTERVAL")) |val| {
        cli.health_check_interval_ms = std.fmt.parseInt(u64, val, 10) catch null;
    }
    if (environ_map.get("LB_MAX_BUFFERED_REQUESTS")) |val| {
        cli.max_buffered_requests = std.fmt.parseInt(usize, val, 10) catch null;
    }
    if (environ_map.get("LB_BUFFERED_REQUEST_TIMEOUT")) |val| {
        cli.buffered_request_timeout_ms = std.fmt.parseInt(u64, val, 10) catch null;
    }
    if (environ_map.get("LB_LOG_LEVEL")) |val| {
        cli.log_level = val;
    }
}

pub fn resolveListenAddr(cli: CliConfig, config_listen_addr: []const u8) []const u8 {
    return cli.listen_addr orelse config_listen_addr;
}

pub fn resolveHealthCheckInterval(cli: CliConfig, config_interval: u64) u64 {
    return cli.health_check_interval_ms orelse config_interval;
}

pub fn resolveLogLevel(cli: CliConfig, config_log_level: []const u8) []const u8 {
    return cli.log_level orelse config_log_level;
}

pub fn resolveMaxBufferedRequests(cli: CliConfig, config_max: usize) usize {
    return cli.max_buffered_requests orelse config_max;
}

pub fn resolveBufferedRequestTimeout(cli: CliConfig, config_timeout: u64) u64 {
    return cli.buffered_request_timeout_ms orelse config_timeout;
}

pub fn parseArgsFromInit(init: std.process.Init) CliConfig {
    var args_iter = std.process.Args.iterateAllocator(init.minimal.args, init.gpa) catch {
        return CliConfig{};
    };
    defer args_iter.deinit();

    var arg_list = std.ArrayList([]const u8).empty;
    defer arg_list.deinit(init.gpa);

    while (args_iter.next()) |arg| {
        arg_list.append(init.gpa, arg) catch {};
    }

    return parseArgs(arg_list.items);
}

test "parseArgs parses --listen-addr with equals" {
    const c = parseArgs(&.{ "llm-lb", "--listen-addr=0.0.0.0:9090" });
    try std.testing.expect(c.listen_addr != null);
    try std.testing.expectEqualStrings("0.0.0.0:9090", c.listen_addr.?);
}

test "parseArgs parses --config with space" {
    const c = parseArgs(&.{ "llm-lb", "--config", "/etc/lb.toml" });
    try std.testing.expect(c.config_path != null);
    try std.testing.expectEqualStrings("/etc/lb.toml", c.config_path.?);
}

test "parseArgs parses --health-check-interval with equals" {
    const c = parseArgs(&.{ "llm-lb", "--health-check-interval=5000" });
    try std.testing.expect(c.health_check_interval_ms != null);
    try std.testing.expect(c.health_check_interval_ms.? == 5000);
}

test "parseArgs parses --log-level" {
    const c = parseArgs(&.{ "llm-lb", "--log-level=debug" });
    try std.testing.expect(c.log_level != null);
    try std.testing.expectEqualStrings("debug", c.log_level.?);
}

test "CLI flags override config file values" {
    const c = CliConfig{
        .listen_addr = "0.0.0.0:9999",
        .health_check_interval_ms = 10000,
        .log_level = "warn",
        .max_buffered_requests = 128,
        .buffered_request_timeout_ms = 60000,
    };

    try std.testing.expectEqualStrings("0.0.0.0:9999", resolveListenAddr(c, "0.0.0.0:8080"));
    try std.testing.expect(resolveHealthCheckInterval(c, 2000) == 10000);
    try std.testing.expectEqualStrings("warn", resolveLogLevel(c, "info"));
    try std.testing.expect(resolveMaxBufferedRequests(c, 64) == 128);
    try std.testing.expect(resolveBufferedRequestTimeout(c, 30000) == 60000);
}

test "CLI defaults fall through to config values" {
    const c = CliConfig{};

    try std.testing.expectEqualStrings("0.0.0.0:8080", resolveListenAddr(c, "0.0.0.0:8080"));
    try std.testing.expect(resolveHealthCheckInterval(c, 2000) == 2000);
    try std.testing.expectEqualStrings("info", resolveLogLevel(c, "info"));
    try std.testing.expect(resolveMaxBufferedRequests(c, 64) == 64);
    try std.testing.expect(resolveBufferedRequestTimeout(c, 30000) == 30000);
}

test "parseArgs parses --max-buffered-requests" {
    const c = parseArgs(&.{ "llm-lb", "--max-buffered-requests=128" });
    try std.testing.expect(c.max_buffered_requests != null);
    try std.testing.expect(c.max_buffered_requests.? == 128);
}

test "parseArgs parses --buffered-request-timeout" {
    const c = parseArgs(&.{ "llm-lb", "--buffered-request-timeout=60000" });
    try std.testing.expect(c.buffered_request_timeout_ms != null);
    try std.testing.expect(c.buffered_request_timeout_ms.? == 60000);
}
