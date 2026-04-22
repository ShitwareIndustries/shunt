const std = @import("std");
const mem = std.mem;

pub const Config = struct {
    listen_addr: []const u8 = "0.0.0.0:8080",
    health_check_interval_ms: u64 = 2000,
    max_buffered_requests: usize = 64,
    buffered_request_timeout_ms: u64 = 30000,
    log_level: []const u8 = "info",
    cache_enabled: bool = true,
    cache_ttl_ms: u64 = 300000,
    cache_max_entries_per_backend: usize = 256,
    models: std.ArrayList(ModelConfig),

    pub const ModelConfig = struct {
        id: []const u8,
        address: []const u8,
        model: []const u8,
    };

    pub fn init() Config {
        return .{
            .models = .empty,
        };
    }

    pub fn deinit(self: *Config, allocator: mem.Allocator) void {
        self.models.deinit(allocator);
    }
};

pub const ParseError = error{
    InvalidToml,
    MissingField,
    OutOfMemory,
    InvalidValue,
};

pub fn parse(allocator: mem.Allocator, content: []const u8) ParseError!Config {
    var config = Config.init();
    errdefer config.deinit(allocator);

    var current_section: enum { none, balancer, cache, model } = .none;
    var pending_model: ?Config.ModelConfig = null;
    var lines = mem.splitSequence(u8, content, "\n");

    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (mem.eql(u8, trimmed, "[balancer]")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
                pending_model = null;
            }
            current_section = .balancer;
            continue;
        }
        if (mem.eql(u8, trimmed, "[cache]")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
                pending_model = null;
            }
            current_section = .cache;
            continue;
        }
        if (mem.eql(u8, trimmed, "[[models]]")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
            }
            pending_model = .{ .id = "", .address = "", .model = "" };
            current_section = .model;
            continue;
        }
        if (mem.startsWith(u8, trimmed, "[")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
                pending_model = null;
            }
            current_section = .none;
            continue;
        }

        const eq_pos = mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = mem.trim(u8, trimmed[0..eq_pos], " \t");
        const val = mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

        switch (current_section) {
            .balancer => {
                if (mem.eql(u8, key, "listen_addr")) {
                    config.listen_addr = unquote(val);
                } else if (mem.eql(u8, key, "health_check_interval_ms")) {
                    config.health_check_interval_ms = std.fmt.parseInt(u64, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                } else if (mem.eql(u8, key, "max_buffered_requests")) {
                    config.max_buffered_requests = std.fmt.parseInt(usize, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                } else if (mem.eql(u8, key, "buffered_request_timeout_ms")) {
                    config.buffered_request_timeout_ms = std.fmt.parseInt(u64, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                } else if (mem.eql(u8, key, "log_level")) {
                    config.log_level = unquote(val);
                }
            },
            .cache => {
                if (mem.eql(u8, key, "cache_enabled")) {
                    const v = unquote(val);
                    if (mem.eql(u8, v, "true")) {
                        config.cache_enabled = true;
                    } else if (mem.eql(u8, v, "false")) {
                        config.cache_enabled = false;
                    } else {
                        return ParseError.InvalidValue;
                    }
                } else if (mem.eql(u8, key, "cache_ttl_ms")) {
                    config.cache_ttl_ms = std.fmt.parseInt(u64, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                } else if (mem.eql(u8, key, "cache_max_entries_per_backend")) {
                    config.cache_max_entries_per_backend = std.fmt.parseInt(usize, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                }
            },
            .model => {
                if (pending_model == null) {
                    pending_model = .{ .id = "", .address = "", .model = "" };
                }
                if (mem.eql(u8, key, "id")) {
                    pending_model.?.id = unquote(val);
                } else if (mem.eql(u8, key, "address")) {
                    pending_model.?.address = unquote(val);
                } else if (mem.eql(u8, key, "model")) {
                    pending_model.?.model = unquote(val);
                }
            },
            .none => {},
        }
    }

    if (pending_model) |pm| {
        try config.models.append(allocator, pm);
    }

    for (config.models.items) |m| {
        if (m.id.len == 0 or m.address.len == 0 or m.model.len == 0) {
            return ParseError.MissingField;
        }
    }

    return config;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

test "parse TOML config with balancer and models" {
    const allocator = std.testing.allocator;
    const toml =
        \\[balancer]
        \\listen_addr = "0.0.0.0:9090"
        \\health_check_interval_ms = 5000
        \\log_level = "debug"
        \\
        \\[[models]]
        \\id = "backend-1"
        \\address = "http://127.0.0.1:8081"
        \\model = "llama3"
        \\
        \\[[models]]
        \\id = "backend-2"
        \\address = "http://127.0.0.1:8082"
        \\model = "llama3"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("0.0.0.0:9090", cfg.listen_addr);
    try std.testing.expect(cfg.health_check_interval_ms == 5000);
    try std.testing.expectEqualStrings("debug", cfg.log_level);
    try std.testing.expect(cfg.models.items.len == 2);
    try std.testing.expectEqualStrings("backend-1", cfg.models.items[0].id);
    try std.testing.expectEqualStrings("http://127.0.0.1:8081", cfg.models.items[0].address);
    try std.testing.expectEqualStrings("llama3", cfg.models.items[0].model);
    try std.testing.expectEqualStrings("backend-2", cfg.models.items[1].id);
    try std.testing.expectEqualStrings("http://127.0.0.1:8082", cfg.models.items[1].address);
    try std.testing.expectEqualStrings("llama3", cfg.models.items[1].model);
}

test "parse TOML config uses defaults when section absent" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("0.0.0.0:8080", cfg.listen_addr);
    try std.testing.expect(cfg.health_check_interval_ms == 2000);
    try std.testing.expectEqualStrings("info", cfg.log_level);
    try std.testing.expect(cfg.models.items.len == 1);
}

test "parse TOML config ignores comments and blank lines" {
    const allocator = std.testing.allocator;
    const toml =
        \\# This is a comment
        \\[balancer]
        \\# listen address
        \\listen_addr = "0.0.0.0:3000"
        \\
        \\[[models]]
        \\id = "x"
        \\address = "http://x:1234"
        \\model = "m"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("0.0.0.0:3000", cfg.listen_addr);
    try std.testing.expect(cfg.models.items.len == 1);
}

test "parse TOML config returns MissingField for incomplete model" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "x"
        \\address = "http://x:1234"
    ;

    const result = parse(allocator, toml);
    try std.testing.expect(result == ParseError.MissingField);
}

test "parse TOML config handles unquoted values" {
    const allocator = std.testing.allocator;
    const toml =
        \\[balancer]
        \\health_check_interval_ms = 3000
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.health_check_interval_ms == 3000);
}

test "parse TOML config reads max_buffered_requests and buffered_request_timeout_ms" {
    const allocator = std.testing.allocator;
    const toml =
        \\[balancer]
        \\max_buffered_requests = 128
        \\buffered_request_timeout_ms = 60000
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.max_buffered_requests == 128);
    try std.testing.expect(cfg.buffered_request_timeout_ms == 60000);
}

test "parse TOML config uses default max_buffered_requests and buffered_request_timeout_ms" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.max_buffered_requests == 64);
    try std.testing.expect(cfg.buffered_request_timeout_ms == 30000);
}

test "parse TOML config [cache] section" {
    const allocator = std.testing.allocator;
    const toml =
        \\[cache]
        \\cache_enabled = false
        \\cache_ttl_ms = 60000
        \\cache_max_entries_per_backend = 128
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.cache_enabled == false);
    try std.testing.expect(cfg.cache_ttl_ms == 60000);
    try std.testing.expect(cfg.cache_max_entries_per_backend == 128);
}

test "parse TOML config uses default cache values when [cache] absent" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.cache_enabled == true);
    try std.testing.expect(cfg.cache_ttl_ms == 300000);
    try std.testing.expect(cfg.cache_max_entries_per_backend == 256);
}

test "parse TOML config [cache] partial override keeps defaults" {
    const allocator = std.testing.allocator;
    const toml =
        \\[cache]
        \\cache_ttl_ms = 120000
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.cache_enabled == true);
    try std.testing.expect(cfg.cache_ttl_ms == 120000);
    try std.testing.expect(cfg.cache_max_entries_per_backend == 256);
}
