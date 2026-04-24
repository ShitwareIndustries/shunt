const std = @import("std");
const bench = @import("benchmark");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var arg_iter = init.minimal.args.iterate();
    const config = bench.BenchConfig.parseArgs(&arg_iter) catch |err| {
        std.log.err("failed to parse bench config: {}", .{err});
        std.process.exit(1);
    };

    var runner = bench.BenchRunner.init(allocator, config);
    defer runner.deinit();

    var result = try runner.run(io) orelse {
        std.log.err("benchmark produced no results", .{});
        std.process.exit(1);
    };
    defer result.deinit(allocator);

    var out_buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &file_writer.interface;

    switch (config.output_format) {
        .table, .both => {
            try result.formatTable(stdout);
        },
        .json => {},
    }

    switch (config.output_format) {
        .json, .both => {
            const json_str = try result.formatJson(allocator);
            defer allocator.free(json_str);
            try stdout.writeAll(json_str);
            try stdout.writeByte('\n');
        },
        .table => {},
    }

    try stdout.flush();
}
