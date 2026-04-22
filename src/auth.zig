const std = @import("std");
const mem = std.mem;

const KEY_PREFIX = "shunt_sk_";

pub const Auth = struct {
    enabled: bool,
    keys: std.HashMapUnmanaged(u64, KeyConfig, struct {
        pub fn hash(self: @This(), key_hash: u64) u64 {
            _ = self;
            return key_hash;
        }
        pub fn eql(self: @This(), a: u64, b: u64) bool {
            _ = self;
            return a == b;
        }
    }, std.hash_map.default_max_load_percentage),
    rate_limiter: RateLimiter,
    allocator: mem.Allocator,

    pub const KeyConfig = struct {
        rate_limit: u64,
        burst: u64,
    };

    pub fn init(allocator: mem.Allocator) Auth {
        return .{
            .enabled = false,
            .keys = .{},
            .rate_limiter = RateLimiter.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Auth) void {
        self.keys.deinit(self.allocator);
        self.rate_limiter.deinit();
    }

    pub fn addKey(self: *Auth, key: []const u8, rate_limit: u64, burst: u64) !void {
        if (!mem.startsWith(u8, key, KEY_PREFIX)) return error.InvalidKeyPrefix;
        const hash = fnv1a64(key);
        const config = KeyConfig{ .rate_limit = rate_limit, .burst = burst };
        const gop = try self.keys.getOrPut(self.allocator, hash);
        gop.value_ptr.* = config;
    }

    pub fn authenticate(self: *Auth, api_key: []const u8) ?*KeyConfig {
        if (!self.enabled) {
            return &default_key_config;
        }
        if (!mem.startsWith(u8, api_key, KEY_PREFIX)) return null;
        const hash = fnv1a64(api_key);
        return self.keys.getPtr(hash);
    }

    pub fn authenticateWithTiming(self: *Auth, api_key: []const u8) ?*KeyConfig {
        if (!self.enabled) {
            return &default_key_config;
        }
        if (!mem.startsWith(u8, api_key, KEY_PREFIX)) return null;
        const hash = fnv1a64(api_key);
        const entry = self.keys.getEntry(hash) orelse return null;
        const stored_hash = entry.key_ptr.*;
        _ = timingSafeCompareHashes(hash, stored_hash);
        return entry.value_ptr;
    }

    pub fn checkRate(self: *RateLimiter, io: std.Io, key_hash: u64, config: KeyConfig, now_ns: i64) RateLimiter.Result {
        return self.rate_limiter.checkAndConsume(io, key_hash, config, now_ns);
    }
};

var default_key_config: Auth.KeyConfig = .{ .rate_limit = 10, .burst = 20 };

pub const RateLimiter = struct {
    buckets: std.HashMapUnmanaged(u64, TokenBucket, struct {
        pub fn hash(self: @This(), key_hash: u64) u64 {
            _ = self;
            return key_hash;
        }
        pub fn eql(self: @This(), a: u64, b: u64) bool {
            _ = self;
            return a == b;
        }
    }, std.hash_map.default_max_load_percentage),
    mutex: std.Io.Mutex,
    allocator: mem.Allocator,

    pub const TokenBucket = struct {
        tokens: f64,
        max_tokens: f64,
        last_refill_ns: i64,
        rate: f64,
    };

    pub const Result = enum { allowed, rate_limited };

    pub fn init(allocator: mem.Allocator) RateLimiter {
        return .{
            .buckets = .{},
            .mutex = .init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.buckets.deinit(self.allocator);
    }

    pub fn checkAndConsume(self: *RateLimiter, io: std.Io, key_hash: u64, config: Auth.KeyConfig, now_ns: i64) Result {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);


        const gop = self.buckets.getOrPut(self.allocator, key_hash) catch {
            return .allowed;
        };

        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .tokens = @floatFromInt(config.burst),
                .max_tokens = @floatFromInt(config.burst),
                .last_refill_ns = now_ns,
                .rate = @floatFromInt(config.rate_limit),
            };
        }

        var bucket = gop.value_ptr;

        const elapsed_ns = now_ns - bucket.last_refill_ns;
        if (elapsed_ns > 0) {
            const refill: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1.0e9 * bucket.rate;
            bucket.tokens = @min(bucket.tokens + refill, bucket.max_tokens);
            bucket.last_refill_ns = now_ns;
        }

        if (bucket.tokens >= 1.0) {
            bucket.tokens -= 1.0;
            return .allowed;
        }

        return .rate_limited;
    }

    pub fn getBucket(self: *RateLimiter, key_hash: u64) ?*TokenBucket {
        return self.buckets.getPtr(key_hash);
    }
};

pub fn fnv1a64(data: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (data) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

fn timingSafeCompareHashes(a: u64, b: u64) bool {
    const a_bytes: [8]u8 = @bitCast(a);
    const b_bytes: [8]u8 = @bitCast(b);
    var diff: u8 = 0;
    for (a_bytes, b_bytes) |ab, bb| {
        diff |= ab ^ bb;
    }
    return diff == 0;
}

test "Auth.authenticate returns default config when disabled" {
    const allocator = std.testing.allocator;
    var auth = Auth.init(allocator);
    defer auth.deinit();
    auth.enabled = false;
    const result = auth.authenticate("shunt_sk_anykey");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.rate_limit == 10);
    try std.testing.expect(result.?.burst == 20);
}

test "Auth.authenticate returns null for invalid prefix" {
    const allocator = std.testing.allocator;
    var auth = Auth.init(allocator);
    defer auth.deinit();
    auth.enabled = true;
    const result = auth.authenticate("invalid_prefix_key");
    try std.testing.expect(result == null);
}

test "Auth.authenticate returns null for unknown key" {
    const allocator = std.testing.allocator;
    var auth = Auth.init(allocator);
    defer auth.deinit();
    auth.enabled = true;
    try auth.addKey("shunt_sk_known", 10, 20);
    const result = auth.authenticate("shunt_sk_unknown");
    try std.testing.expect(result == null);
}

test "Auth.authenticate returns config for valid key" {
    const allocator = std.testing.allocator;
    var auth = Auth.init(allocator);
    defer auth.deinit();
    auth.enabled = true;
    try auth.addKey("shunt_sk_testkey123", 50, 100);
    const result = auth.authenticate("shunt_sk_testkey123");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.rate_limit == 50);
    try std.testing.expect(result.?.burst == 100);
}

test "Auth.addKey rejects invalid prefix" {
    const allocator = std.testing.allocator;
    var auth = Auth.init(allocator);
    defer auth.deinit();
    const result = auth.addKey("bad_prefix_key", 10, 20);
    try std.testing.expect(result == error.InvalidKeyPrefix);
}

test "Auth.authenticateWithTiming returns config for valid key" {
    const allocator = std.testing.allocator;
    var auth = Auth.init(allocator);
    defer auth.deinit();
    auth.enabled = true;
    try auth.addKey("shunt_sk_timingtest", 10, 20);
    const result = auth.authenticateWithTiming("shunt_sk_timingtest");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.rate_limit == 10);
}

test "Auth.authenticateWithTiming returns null for unknown key" {
    const allocator = std.testing.allocator;
    var auth = Auth.init(allocator);
    defer auth.deinit();
    auth.enabled = true;
    const result = auth.authenticateWithTiming("shunt_sk_nonexistent");
    try std.testing.expect(result == null);
}

test "RateLimiter allows requests within rate" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();
    const config = Auth.KeyConfig{ .rate_limit = 10, .burst = 20 };
    const key_hash = fnv1a64("shunt_sk_test");
    const now_ns: i64 = 1_000_000_000;
    const result = rl.checkAndConsume(std.testing.io, key_hash, config, now_ns);
    try std.testing.expect(result == .allowed);
}

test "RateLimiter blocks requests exceeding burst" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();
    const config = Auth.KeyConfig{ .rate_limit = 1, .burst = 3 };
    const key_hash = fnv1a64("shunt_sk_test");
    const now_ns: i64 = 1_000_000_000;
    for (0..3) |_| {
        _ = rl.checkAndConsume(std.testing.io, key_hash, config, now_ns);
    }
    const result = rl.checkAndConsume(std.testing.io, key_hash, config, now_ns);
    try std.testing.expect(result == .rate_limited);
}

test "RateLimiter refills tokens over time" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();
    const config = Auth.KeyConfig{ .rate_limit = 10, .burst = 5 };
    const key_hash = fnv1a64("shunt_sk_test");
    var now_ns: i64 = 1_000_000_000;
    for (0..5) |_| {
        _ = rl.checkAndConsume(std.testing.io, key_hash, config, now_ns);
    }
    try std.testing.expect(rl.checkAndConsume(std.testing.io, key_hash, config, now_ns) == .rate_limited);
    now_ns += std.time.ns_per_s;
    const result = rl.checkAndConsume(std.testing.io, key_hash, config, now_ns);
    try std.testing.expect(result == .allowed);
}

test "RateLimiter fail-open on OOM" {
    var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing_allocator_state.allocator();
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();
    const config = Auth.KeyConfig{ .rate_limit = 10, .burst = 20 };
    const key_hash = fnv1a64("shunt_sk_test");
    const now_ns: i64 = 1_000_000_000;
    const result = rl.checkAndConsume(std.testing.io, key_hash, config, now_ns);
    try std.testing.expect(result == .allowed);
}

test "RateLimiter multiple keys are independent" {
    const allocator = std.testing.allocator;
    var rl = RateLimiter.init(allocator);
    defer rl.deinit();
    const config = Auth.KeyConfig{ .rate_limit = 1, .burst = 2 };
    const key1 = fnv1a64("shunt_sk_key1");
    const key2 = fnv1a64("shunt_sk_key2");
    const now_ns: i64 = 1_000_000_000;
    _ = rl.checkAndConsume(std.testing.io, key1, config, now_ns);
    _ = rl.checkAndConsume(std.testing.io, key1, config, now_ns);
    try std.testing.expect(rl.checkAndConsume(std.testing.io, key1, config, now_ns) == .rate_limited);
    try std.testing.expect(rl.checkAndConsume(std.testing.io, key2, config, now_ns) == .allowed);
}

test "fnv1a64 produces consistent hashes" {
    const h1 = fnv1a64("shunt_sk_test");
    const h2 = fnv1a64("shunt_sk_test");
    try std.testing.expect(h1 == h2);
}

test "fnv1a64 produces different hashes for different keys" {
    const h1 = fnv1a64("shunt_sk_key1");
    const h2 = fnv1a64("shunt_sk_key2");
    try std.testing.expect(h1 != h2);
}

test "timingSafeCompareHashes returns true for equal hashes" {
    const h = fnv1a64("shunt_sk_test");
    try std.testing.expect(timingSafeCompareHashes(h, h));
}

test "timingSafeCompareHashes returns false for different hashes" {
    const h1 = fnv1a64("shunt_sk_key1");
    const h2 = fnv1a64("shunt_sk_key2");
    try std.testing.expect(!timingSafeCompareHashes(h1, h2));
}
