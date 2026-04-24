const std = @import("std");
const mem = std.mem;
const backend_pool = @import("backend_pool");

pub const Config = struct {
    listen_addr: []const u8 = "0.0.0.0:8080",
    health_check_interval_ms: u64 = 2000,
    max_buffered_requests: usize = 64,
    buffered_request_timeout_ms: u64 = 30000,
    log_level: []const u8 = "info",
    logging_format: []const u8 = "json",
    logging_output: []const u8 = "stdout",
    cache_enabled: bool = true,
    cache_ttl_ms: u64 = 300000,
    cache_max_entries_per_backend: usize = 256,
    routing_strategy: backend_pool.RoutingStrategy = .round_robin,
    models: std.ArrayList(ModelConfig),
    auth_enabled: bool = false,
    auth_default_rate_limit: u64 = 10,
    auth_default_burst: u64 = 20,
    auth_keys: std.ArrayList(AuthKeyConfig),

    pub const ModelConfig = struct {
        id: []const u8,
        address: []const u8,
        model: []const u8,
        backend_type: backend_pool.BackendType = .llama_cpp,
        weight: u32 = 1,
    };

    pub const AuthKeyConfig = struct {
        key: []const u8,
        rate_limit: u64 = 10,
        burst: u64 = 20,
    };

    pub fn init() Config {
        return .{
            .models = .empty,
            .auth_keys = .empty,
        };
    }

    pub fn deinit(self: *Config, allocator: mem.Allocator) void {
        self.models.deinit(allocator);
        self.auth_keys.deinit(allocator);
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

    var current_section: enum { none, balancer, cache, model, auth, auth_key, logging } = .none;
    var pending_model: ?Config.ModelConfig = null;
    var pending_auth_key: ?Config.AuthKeyConfig = null;
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
        if (mem.eql(u8, trimmed, "[auth]")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
                pending_model = null;
            }
            if (pending_auth_key) |ak| {
                try config.auth_keys.append(allocator, ak);
                pending_auth_key = null;
            }
            current_section = .auth;
            continue;
        }
        if (mem.eql(u8, trimmed, "[logging]")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
                pending_model = null;
            }
            if (pending_auth_key) |ak| {
                try config.auth_keys.append(allocator, ak);
                pending_auth_key = null;
            }
            current_section = .logging;
            continue;
        }
        if (mem.eql(u8, trimmed, "[[auth.keys]]")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
                pending_model = null;
            }
            if (pending_auth_key) |ak| {
                try config.auth_keys.append(allocator, ak);
            }
            pending_auth_key = .{ .key = "", .rate_limit = config.auth_default_rate_limit, .burst = config.auth_default_burst };
            current_section = .auth_key;
            continue;
        }
        if (mem.startsWith(u8, trimmed, "[")) {
            if (pending_model) |pm| {
                try config.models.append(allocator, pm);
                pending_model = null;
            }
            if (pending_auth_key) |ak| {
                try config.auth_keys.append(allocator, ak);
                pending_auth_key = null;
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
                } else if (mem.eql(u8, key, "logging_format")) {
                    config.logging_format = unquote(val);
                } else if (mem.eql(u8, key, "logging_output")) {
                    config.logging_output = unquote(val);
                } else if (mem.eql(u8, key, "routing_strategy")) {
                    const v = unquote(val);
                    config.routing_strategy = backend_pool.RoutingStrategy.fromString(v) orelse {
                        return ParseError.InvalidValue;
                    };
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
                } else if (mem.eql(u8, key, "backend_type")) {
                    const v = unquote(val);
                    if (mem.eql(u8, v, "llama_cpp") or mem.eql(u8, v, "llama-cpp")) {
                        pending_model.?.backend_type = .llama_cpp;
                    } else if (mem.eql(u8, v, "vllm")) {
                        pending_model.?.backend_type = .vllm;
                    } else if (mem.eql(u8, v, "openai")) {
                        pending_model.?.backend_type = .openai;
                    } else {
                        return ParseError.InvalidValue;
                    }
                } else if (mem.eql(u8, key, "weight")) {
                    pending_model.?.weight = std.fmt.parseInt(u32, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                }
            },
            .auth => {
                if (mem.eql(u8, key, "enabled")) {
                    const v = unquote(val);
                    if (mem.eql(u8, v, "true")) {
                        config.auth_enabled = true;
                    } else if (mem.eql(u8, v, "false")) {
                        config.auth_enabled = false;
                    } else {
                        return ParseError.InvalidValue;
                    }
                } else if (mem.eql(u8, key, "default_rate_limit")) {
                    config.auth_default_rate_limit = std.fmt.parseInt(u64, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                } else if (mem.eql(u8, key, "default_burst")) {
                    config.auth_default_burst = std.fmt.parseInt(u64, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                }
            },
            .auth_key => {
                if (pending_auth_key == null) {
                    pending_auth_key = .{ .key = "", .rate_limit = config.auth_default_rate_limit, .burst = config.auth_default_burst };
                }
                if (mem.eql(u8, key, "key")) {
                    pending_auth_key.?.key = unquote(val);
                } else if (mem.eql(u8, key, "rate_limit")) {
                    pending_auth_key.?.rate_limit = std.fmt.parseInt(u64, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                } else if (mem.eql(u8, key, "burst")) {
                    pending_auth_key.?.burst = std.fmt.parseInt(u64, unquote(val), 10) catch {
                        return ParseError.InvalidValue;
                    };
                }
            },
            .logging => {
                if (mem.eql(u8, key, "level")) {
                    config.log_level = unquote(val);
                } else if (mem.eql(u8, key, "format")) {
                    config.logging_format = unquote(val);
                } else if (mem.eql(u8, key, "output")) {
                    config.logging_output = unquote(val);
                }
            },
            .none => {},
        }
    }

    if (pending_model) |pm| {
        try config.models.append(allocator, pm);
    }
    if (pending_auth_key) |ak| {
        try config.auth_keys.append(allocator, ak);
    }

    for (config.models.items) |m| {
        if (m.id.len == 0 or m.address.len == 0 or m.model.len == 0) {
            return ParseError.MissingField;
        }
    }

    for (config.auth_keys.items) |ak| {
        if (ak.key.len == 0) {
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

test "parse TOML config [auth] section" {
    const allocator = std.testing.allocator;
    const toml =
        \\[auth]
        \\enabled = true
        \\default_rate_limit = 20
        \\default_burst = 40
        \\
        \\[[auth.keys]]
        \\key = "shunt_sk_test123"
        \\rate_limit = 50
        \\burst = 100
        \\
        \\[[auth.keys]]
        \\key = "shunt_sk_other456"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.auth_enabled == true);
    try std.testing.expect(cfg.auth_default_rate_limit == 20);
    try std.testing.expect(cfg.auth_default_burst == 40);
    try std.testing.expect(cfg.auth_keys.items.len == 2);
    try std.testing.expectEqualStrings("shunt_sk_test123", cfg.auth_keys.items[0].key);
    try std.testing.expect(cfg.auth_keys.items[0].rate_limit == 50);
    try std.testing.expect(cfg.auth_keys.items[0].burst == 100);
    try std.testing.expectEqualStrings("shunt_sk_other456", cfg.auth_keys.items[1].key);
    try std.testing.expect(cfg.auth_keys.items[1].rate_limit == 20);
    try std.testing.expect(cfg.auth_keys.items[1].burst == 40);
}

test "parse TOML config uses default auth values when [auth] absent" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.auth_enabled == false);
    try std.testing.expect(cfg.auth_default_rate_limit == 10);
    try std.testing.expect(cfg.auth_default_burst == 20);
    try std.testing.expect(cfg.auth_keys.items.len == 0);
}

test "parse TOML config [auth] partial override keeps defaults" {
    const allocator = std.testing.allocator;
    const toml =
        \\[auth]
        \\enabled = true
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.auth_enabled == true);
    try std.testing.expect(cfg.auth_default_rate_limit == 10);
    try std.testing.expect(cfg.auth_default_burst == 20);
    try std.testing.expect(cfg.auth_keys.items.len == 0);
}

test "parse TOML config [auth] missing key field returns error" {
    const allocator = std.testing.allocator;
    const toml =
        \\[auth]
        \\enabled = true
        \\
        \\[[auth.keys]]
        \\rate_limit = 50
        \\burst = 100
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    const result = parse(allocator, toml);
    try std.testing.expect(result == ParseError.MissingField);
}

test "parse TOML config [[auth.keys]] with multiple entries" {
    const allocator = std.testing.allocator;
    const toml =
        \\[auth]
        \\enabled = true
        \\
        \\[[auth.keys]]
        \\key = "shunt_sk_alpha"
        \\rate_limit = 10
        \\burst = 20
        \\
        \\[[auth.keys]]
        \\key = "shunt_sk_beta"
        \\rate_limit = 100
        \\burst = 200
        \\
        \\[[auth.keys]]
        \\key = "shunt_sk_gamma"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.auth_keys.items.len == 3);
    try std.testing.expectEqualStrings("shunt_sk_alpha", cfg.auth_keys.items[0].key);
    try std.testing.expect(cfg.auth_keys.items[0].rate_limit == 10);
    try std.testing.expect(cfg.auth_keys.items[0].burst == 20);
    try std.testing.expectEqualStrings("shunt_sk_beta", cfg.auth_keys.items[1].key);
    try std.testing.expect(cfg.auth_keys.items[1].rate_limit == 100);
    try std.testing.expect(cfg.auth_keys.items[1].burst == 200);
    try std.testing.expectEqualStrings("shunt_sk_gamma", cfg.auth_keys.items[2].key);
    try std.testing.expect(cfg.auth_keys.items[2].rate_limit == 10);
    try std.testing.expect(cfg.auth_keys.items[2].burst == 20);
}

test "parse TOML config [logging] section" {
    const allocator = std.testing.allocator;
    const toml =
        \\[logging]
        \\level = "debug"
        \\format = "text"
        \\output = "stderr"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("debug", cfg.log_level);
    try std.testing.expectEqualStrings("text", cfg.logging_format);
    try std.testing.expectEqualStrings("stderr", cfg.logging_output);
}

test "parse TOML config [logging] partial override keeps defaults" {
    const allocator = std.testing.allocator;
    const toml =
        \\[logging]
        \\level = "warn"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("warn", cfg.log_level);
    try std.testing.expectEqualStrings("json", cfg.logging_format);
    try std.testing.expectEqualStrings("stdout", cfg.logging_output);
}

test "parse TOML config [logging] overrides [balancer] log_level" {
    const allocator = std.testing.allocator;
    const toml =
        \\[balancer]
        \\log_level = "info"
        \\
        \\[logging]
        \\level = "debug"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expectEqualStrings("debug", cfg.log_level);
}

test "parse TOML config [[models]] backend_type defaults to llama_cpp" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.models.items[0].backend_type == .llama_cpp);
}

test "parse TOML config [[models]] backend_type = vllm" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "vllm-1"
        \\address = "http://localhost:8000"
        \\model = "llama3"
        \\backend_type = "vllm"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.models.items[0].backend_type == .vllm);
}

test "parse TOML config [[models]] backend_type = openai" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "openai-1"
        \\address = "https://api.openai.com"
        \\model = "gpt-4"
        \\backend_type = "openai"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.models.items[0].backend_type == .openai);
}

test "parse TOML config [[models]] backend_type = llama_cpp explicit" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "llama-1"
        \\address = "http://localhost:8081"
        \\model = "llama3"
        \\backend_type = "llama_cpp"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.models.items[0].backend_type == .llama_cpp);
}

test "parse TOML config [[models]] backend_type invalid returns error" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
        \\backend_type = "invalid"
    ;

    const result = parse(allocator, toml);
    try std.testing.expect(result == ParseError.InvalidValue);
}

test "parse TOML config [[models]] mixed backend types" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "llama-1"
        \\address = "http://localhost:8081"
        \\model = "llama3"
        \\
        \\[[models]]
        \\id = "vllm-1"
        \\address = "http://localhost:8000"
        \\model = "llama3"
        \\backend_type = "vllm"
        \\
        \\[[models]]
        \\id = "openai-1"
        \\address = "https://api.openai.com"
        \\model = "gpt-4"
        \\backend_type = "openai"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.models.items.len == 3);
    try std.testing.expect(cfg.models.items[0].backend_type == .llama_cpp);
    try std.testing.expect(cfg.models.items[1].backend_type == .vllm);
    try std.testing.expect(cfg.models.items[2].backend_type == .openai);
}

test "parse TOML config routing_strategy defaults to round_robin" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.routing_strategy == .round_robin);
}

test "parse TOML config routing_strategy = least_connections" {
    const allocator = std.testing.allocator;
    const toml =
        \\[balancer]
        \\routing_strategy = "least_connections"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.routing_strategy == .least_connections);
}

test "parse TOML config routing_strategy accepts hyphenated form" {
    const allocator = std.testing.allocator;
    const toml =
        \\[balancer]
        \\routing_strategy = "latency-based"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.routing_strategy == .latency_based);
}

test "parse TOML config routing_strategy invalid returns error" {
    const allocator = std.testing.allocator;
    const toml =
        \\[balancer]
        \\routing_strategy = "invalid"
        \\
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    const result = parse(allocator, toml);
    try std.testing.expect(result == ParseError.InvalidValue);
}

test "parse TOML config [[models]] weight defaults to 1" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "b1"
        \\address = "http://localhost:8081"
        \\model = "test"
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.models.items[0].weight == 1);
}

test "parse TOML config [[models]] weight overrides default" {
    const allocator = std.testing.allocator;
    const toml =
        \\[[models]]
        \\id = "heavy"
        \\address = "http://localhost:8081"
        \\model = "test"
        \\weight = 5
        \\
        \\[[models]]
        \\id = "light"
        \\address = "http://localhost:8082"
        \\model = "test"
        \\weight = 1
    ;

    var cfg = try parse(allocator, toml);
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.models.items[0].weight == 5);
    try std.testing.expect(cfg.models.items[1].weight == 1);
}
