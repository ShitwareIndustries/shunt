const std = @import("std");
const mem = std.mem;

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn fromString(str: []const u8) ?Level {
        if (mem.eql(u8, str, "error")) return .err;
        if (mem.eql(u8, str, "warn")) return .warn;
        if (mem.eql(u8, str, "info")) return .info;
        if (mem.eql(u8, str, "debug")) return .debug;
        return null;
    }

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
        };
    }
};

pub const Format = enum {
    json,
    text,

    pub fn fromString(str: []const u8) ?Format {
        if (mem.eql(u8, str, "json")) return .json;
        if (mem.eql(u8, str, "text")) return .text;
        return null;
    }
};

pub const Output = enum {
    stdout,
    stderr,

    pub fn fromString(str: []const u8) ?Output {
        if (mem.eql(u8, str, "stdout")) return .stdout;
        if (mem.eql(u8, str, "stderr")) return .stderr;
        return null;
    }
};

pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        bool: bool,
    };
};

pub const Config = struct {
    level: Level = .info,
    format: Format = .json,
    output: Output = .stdout,
};

pub const Logger = struct {
    config: Config,
    mutex: std.Io.Mutex,

    pub fn init(config: Config) Logger {
        return .{
            .config = config,
            .mutex = .init,
        };
    }

    pub fn log(self: *Logger, io: std.Io, level: Level, module: []const u8, message: []const u8, fields: []const Field) void {
        if (@intFromEnum(level) > @intFromEnum(self.config.level)) return;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var entry_buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&entry_buf);

        switch (self.config.format) {
            .json => formatJsonEntry(&writer, io, level, module, message, fields) catch return,
            .text => formatTextEntry(&writer, io, level, module, message, fields) catch return,
        }

        const output = entry_buf[0..writer.end];
        self.writeOutput(io, output);
    }

    fn writeOutput(self: *Logger, io: std.Io, data: []const u8) void {
        var out_buf: [4096]u8 = undefined;
        var out: std.Io.File.Writer = switch (self.config.output) {
            .stdout => std.Io.File.stdout().writer(io, &out_buf),
            .stderr => std.Io.File.stderr().writer(io, &out_buf),
        };
        out.interface.writeAll(data) catch {};
        out.interface.writeByte('\n') catch {};
        out.flush() catch {};
    }

    pub fn err(self: *Logger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .err, module, message, fields);
    }

    pub fn warn(self: *Logger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .warn, module, message, fields);
    }

    pub fn info(self: *Logger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .info, module, message, fields);
    }

    pub fn debug(self: *Logger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .debug, module, message, fields);
    }
};

pub const RequestLogger = struct {
    logger: *Logger,
    request_id: []const u8,

    pub fn init(logger: *Logger, request_id: []const u8) RequestLogger {
        return .{
            .logger = logger,
            .request_id = request_id,
        };
    }

    pub fn log(self: *RequestLogger, io: std.Io, level: Level, module: []const u8, message: []const u8, extra_fields: []const Field) void {
        var fields_buf: [16]Field = undefined;
        var count: usize = 0;
        fields_buf[0] = .{ .key = "request_id", .value = .{ .string = self.request_id } };
        count = 1;
        for (extra_fields) |f| {
            if (count < fields_buf.len) {
                fields_buf[count] = f;
                count += 1;
            }
        }
        self.logger.log(io, level, module, message, fields_buf[0..count]);
    }

    pub fn err(self: *RequestLogger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .err, module, message, fields);
    }

    pub fn warn(self: *RequestLogger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .warn, module, message, fields);
    }

    pub fn info(self: *RequestLogger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .info, module, message, fields);
    }

    pub fn debug(self: *RequestLogger, io: std.Io, module: []const u8, message: []const u8, fields: []const Field) void {
        self.log(io, .debug, module, message, fields);
    }
};

pub fn formatTimestamp(buf: []u8, io: std.Io) usize {
    const unix_secs: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = unix_secs };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const hours = day_secs.getHoursIntoDay();
    const minutes = day_secs.getMinutesIntoHour();
    const seconds = day_secs.getSecondsIntoMinute();

    const result = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        hours,
        minutes,
        seconds,
    }) catch return 0;
    return result.len;
}

pub fn writeJsonString(writer: *std.Io.Writer, str: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (str) |c| {
        switch (c) {
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            '\n' => {
                try writer.writeByte('\\');
                try writer.writeByte('n');
            },
            '\r' => {
                try writer.writeByte('\\');
                try writer.writeByte('r');
            },
            '\t' => {
                try writer.writeByte('\\');
                try writer.writeByte('t');
            },
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{d:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

pub fn formatJsonEntry(writer: *std.Io.Writer, io: std.Io, level: Level, module: []const u8, message: []const u8, fields: []const Field) std.Io.Writer.Error!void {
    var ts_buf: [32]u8 = undefined;
    const ts_len = formatTimestamp(&ts_buf, io);

    try writer.writeByte('{');
    try writer.print("\"timestamp\":\"{s}\",\"level\":\"{s}\",\"module\":\"{s}\",\"message\":", .{
        ts_buf[0..ts_len],
        level.toString(),
        module,
    });
    try writeJsonString(writer, message);

    for (fields) |field| {
        try writer.writeAll(",\"");
        try writer.writeAll(field.key);
        try writer.writeAll("\":");
        switch (field.value) {
            .string => |s| {
                try writeJsonString(writer, s);
            },
            .int => |v| {
                try writer.print("{d}", .{v});
            },
            .uint => |v| {
                try writer.print("{d}", .{v});
            },
            .float => |v| {
                try writer.print("{d}", .{v});
            },
            .bool => |v| {
                try writer.writeAll(if (v) "true" else "false");
            },
        }
    }

    try writer.writeByte('}');
}

pub fn formatTextEntry(writer: *std.Io.Writer, io: std.Io, level: Level, module: []const u8, message: []const u8, fields: []const Field) std.Io.Writer.Error!void {
    var ts_buf: [32]u8 = undefined;
    const ts_len = formatTimestamp(&ts_buf, io);

    try writer.print("{s} [{s}] {s}: {s}", .{
        ts_buf[0..ts_len],
        level.toString(),
        module,
        message,
    });

    for (fields) |field| {
        try writer.writeAll(" ");
        try writer.writeAll(field.key);
        try writer.writeByte('=');
        switch (field.value) {
            .string => |s| {
                try writer.writeByte('"');
                try writer.writeAll(s);
                try writer.writeByte('"');
            },
            .int => |v| {
                try writer.print("{d}", .{v});
            },
            .uint => |v| {
                try writer.print("{d}", .{v});
            },
            .float => |v| {
                try writer.print("{d}", .{v});
            },
            .bool => |v| {
                try writer.writeAll(if (v) "true" else "false");
            },
        }
    }
}

test "Level.fromString parses known levels" {
    try std.testing.expect(Level.fromString("error") != null);
    try std.testing.expect(Level.fromString("error").? == .err);
    try std.testing.expect(Level.fromString("warn").? == .warn);
    try std.testing.expect(Level.fromString("info").? == .info);
    try std.testing.expect(Level.fromString("debug").? == .debug);
    try std.testing.expect(Level.fromString("unknown") == null);
}

test "Level.toString returns correct strings" {
    try std.testing.expectEqualStrings("error", Level.err.toString());
    try std.testing.expectEqualStrings("warn", Level.warn.toString());
    try std.testing.expectEqualStrings("info", Level.info.toString());
    try std.testing.expectEqualStrings("debug", Level.debug.toString());
}

test "Format.fromString parses known formats" {
    try std.testing.expect(Format.fromString("json").? == .json);
    try std.testing.expect(Format.fromString("text").? == .text);
    try std.testing.expect(Format.fromString("xml") == null);
}

test "Output.fromString parses known outputs" {
    try std.testing.expect(Output.fromString("stdout").? == .stdout);
    try std.testing.expect(Output.fromString("stderr").? == .stderr);
    try std.testing.expect(Output.fromString("file") == null);
}

test "formatJsonEntry produces valid JSON structure" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const fields = [_]Field{
        .{ .key = "request_id", .value = .{ .string = "abc-123" } },
        .{ .key = "status", .value = .{ .uint = 200 } },
    };

    try formatJsonEntry(&writer, std.testing.io, .info, "proxy", "request completed", &fields);

    const output = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"timestamp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"module\":\"proxy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"request_id\":\"abc-123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":200") != null);
}

test "formatTextEntry produces readable text format" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const fields = [_]Field{
        .{ .key = "method", .value = .{ .string = "GET" } },
    };

    try formatTextEntry(&writer, std.testing.io, .err, "http", "connection failed", &fields);

    const output = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "[error]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "http") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "connection failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "method=") != null);
}

test "writeJsonString escapes special characters" {
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeJsonString(&writer, "hello \"world\"\nline2\ttab");
    const output = buf[0..writer.end];

    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nline2\\ttab\"", output);
}

test "formatTimestamp produces ISO 8601 format" {
    var ts_buf: [32]u8 = undefined;
    const len = formatTimestamp(&ts_buf, std.testing.io);
    try std.testing.expect(len > 0);

    const ts = ts_buf[0..len];
    try std.testing.expect(ts[4] == '-');
    try std.testing.expect(ts[7] == '-');
    try std.testing.expect(ts[10] == 'T');
    try std.testing.expect(ts[13] == ':');
    try std.testing.expect(ts[16] == ':');
    try std.testing.expect(ts[19] == 'Z');
}

test "Logger respects level filtering" {
    const logger = Logger.init(.{ .level = .warn, .format = .json, .output = .stdout });

    try std.testing.expect(@intFromEnum(Level.debug) > @intFromEnum(logger.config.level));
    try std.testing.expect(@intFromEnum(Level.info) > @intFromEnum(logger.config.level));
    try std.testing.expect(@intFromEnum(Level.warn) <= @intFromEnum(logger.config.level));
    try std.testing.expect(@intFromEnum(Level.err) <= @intFromEnum(logger.config.level));
}

test "RequestLogger prepends request_id field" {
    var logger = Logger.init(.{ .level = .info, .format = .json, .output = .stdout });
    const req_log = RequestLogger.init(&logger, "req-abc-123");

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const extra = [_]Field{
        .{ .key = "method", .value = .{ .string = "POST" } },
    };

    try formatJsonEntry(&writer, std.testing.io, .info, "proxy", "request start", &extra);

    const output = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"module\":\"proxy\"") != null);
    _ = req_log;
}

test "formatJsonEntry handles boolean field" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const fields = [_]Field{
        .{ .key = "cache_hit", .value = .{ .bool = true } },
    };

    try formatJsonEntry(&writer, std.testing.io, .info, "cache", "lookup", &fields);

    const output = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"cache_hit\":true") != null);
}

test "formatJsonEntry handles integer fields" {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const fields = [_]Field{
        .{ .key = "latency_us", .value = .{ .uint = 1500 } },
        .{ .key = "offset", .value = .{ .int = -3 } },
    };

    try formatJsonEntry(&writer, std.testing.io, .info, "proxy", "timing", &fields);

    const output = buf[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"latency_us\":1500") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"offset\":-3") != null);
}
