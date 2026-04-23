const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend_pool_mod = b.createModule(.{
        .root_source_file = b.path("src/backend_pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    const openai_mod = b.createModule(.{
        .root_source_file = b.path("src/openai.zig"),
        .target = target,
        .optimize = optimize,
    });
    openai_mod.addImport("backend_pool", backend_pool_mod);

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const request_queue_mod = b.createModule(.{
        .root_source_file = b.path("src/request_queue.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cache_router_mod = b.createModule(.{
        .root_source_file = b.path("src/cache_router.zig"),
        .target = target,
        .optimize = optimize,
    });
    cache_router_mod.addImport("backend_pool", backend_pool_mod);
    openai_mod.addImport("cache_router", cache_router_mod);

    const metrics_mod = b.createModule(.{
        .root_source_file = b.path("src/metrics.zig"),
        .target = target,
        .optimize = optimize,
    });

    const health_mod = b.createModule(.{
        .root_source_file = b.path("src/health.zig"),
        .target = target,
        .optimize = optimize,
    });
    health_mod.addImport("backend_pool", backend_pool_mod);

    const logger_mod = b.createModule(.{
        .root_source_file = b.path("src/logger.zig"),
        .target = target,
        .optimize = optimize,
    });

const request_id_mod = b.createModule(.{
    .root_source_file = b.path("src/request_id.zig"),
    .target = target,
    .optimize = optimize,
});

const auth_mod = b.createModule(.{
    .root_source_file = b.path("src/auth.zig"),
    .target = target,
    .optimize = optimize,
});

    const proxy_mod = b.createModule(.{
        .root_source_file = b.path("src/proxy.zig"),
        .target = target,
        .optimize = optimize,
    });
proxy_mod.addImport("backend_pool", backend_pool_mod);
proxy_mod.addImport("openai", openai_mod);
proxy_mod.addImport("request_queue", request_queue_mod);
proxy_mod.addImport("cache_router", cache_router_mod);
proxy_mod.addImport("metrics", metrics_mod);
proxy_mod.addImport("health", health_mod);
proxy_mod.addImport("logger", logger_mod);
proxy_mod.addImport("request_id", request_id_mod);
proxy_mod.addImport("auth", auth_mod);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("backend_pool", backend_pool_mod);
    root_mod.addImport("openai", openai_mod);
    root_mod.addImport("config", config_mod);
    root_mod.addImport("cli", cli_mod);
    root_mod.addImport("proxy", proxy_mod);
    root_mod.addImport("request_queue", request_queue_mod);
    root_mod.addImport("cache_router", cache_router_mod);
    root_mod.addImport("metrics", metrics_mod);
    root_mod.addImport("health", health_mod);
root_mod.addImport("logger", logger_mod);
root_mod.addImport("request_id", request_id_mod);
root_mod.addImport("auth", auth_mod);

    const shunt_mod = b.addModule("shunt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shunt_mod.addImport("backend_pool", backend_pool_mod);
    shunt_mod.addImport("openai", openai_mod);
    shunt_mod.addImport("config", config_mod);
    shunt_mod.addImport("cli", cli_mod);
    shunt_mod.addImport("proxy", proxy_mod);
    shunt_mod.addImport("request_queue", request_queue_mod);
    shunt_mod.addImport("cache_router", cache_router_mod);
    shunt_mod.addImport("metrics", metrics_mod);
    shunt_mod.addImport("health", health_mod);
shunt_mod.addImport("logger", logger_mod);
shunt_mod.addImport("request_id", request_id_mod);
shunt_mod.addImport("auth", auth_mod);

    const exe = b.addExecutable(.{
        .name = "shunt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shunt", .module = shunt_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const root_tests = b.addTest(.{
        .root_module = root_mod,
    });

    const backend_pool_tests = b.addTest(.{
        .root_module = backend_pool_mod,
    });

    const openai_tests = b.addTest(.{
        .root_module = openai_mod,
    });

    const config_tests = b.addTest(.{
        .root_module = config_mod,
    });

    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
    });

    const proxy_tests = b.addTest(.{
        .root_module = proxy_mod,
    });

    const request_queue_tests = b.addTest(.{
        .root_module = request_queue_mod,
    });

    const cache_router_tests = b.addTest(.{
        .root_module = cache_router_mod,
    });

    const metrics_tests = b.addTest(.{
        .root_module = metrics_mod,
    });

    const health_tests = b.addTest(.{
        .root_module = health_mod,
    });

const logger_tests = b.addTest(.{
    .root_module = logger_mod,
});

const request_id_tests = b.addTest(.{
    .root_module = request_id_mod,
});

const auth_tests = b.addTest(.{
    .root_module = auth_mod,
});

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const test_unit_step = b.step("test-unit", "Run unit tests only");
    test_unit_step.dependOn(&b.addRunArtifact(root_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(backend_pool_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(openai_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(cli_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(proxy_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(request_queue_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(cache_router_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(metrics_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(health_tests).step);
test_unit_step.dependOn(&b.addRunArtifact(logger_tests).step);
test_unit_step.dependOn(&b.addRunArtifact(request_id_tests).step);
test_unit_step.dependOn(&b.addRunArtifact(auth_tests).step);
    test_unit_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    const test_integration_step = b.step("test-integration", "Run integration tests");
    test_integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("shunt", shunt_mod);
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });
    const test_fuzz_step = b.step("test-fuzz", "Run fuzz tests");
    test_fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(root_tests).step);
    test_step.dependOn(&b.addRunArtifact(backend_pool_tests).step);
    test_step.dependOn(&b.addRunArtifact(openai_tests).step);
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    test_step.dependOn(&b.addRunArtifact(proxy_tests).step);
    test_step.dependOn(&b.addRunArtifact(request_queue_tests).step);
    test_step.dependOn(&b.addRunArtifact(cache_router_tests).step);
    test_step.dependOn(&b.addRunArtifact(metrics_tests).step);
    test_step.dependOn(&b.addRunArtifact(health_tests).step);
    test_step.dependOn(&b.addRunArtifact(logger_tests).step);
    test_step.dependOn(&b.addRunArtifact(auth_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "tests" },
        .check = true,
    });

    const ci_step = b.step("ci", "Run CI checks (fmt + all tests)");
    ci_step.dependOn(&fmt_check.step);
    ci_step.dependOn(&b.addRunArtifact(root_tests).step);
    ci_step.dependOn(&b.addRunArtifact(backend_pool_tests).step);
    ci_step.dependOn(&b.addRunArtifact(openai_tests).step);
    ci_step.dependOn(&b.addRunArtifact(config_tests).step);
    ci_step.dependOn(&b.addRunArtifact(cli_tests).step);
    ci_step.dependOn(&b.addRunArtifact(proxy_tests).step);
    ci_step.dependOn(&b.addRunArtifact(request_queue_tests).step);
    ci_step.dependOn(&b.addRunArtifact(cache_router_tests).step);
    ci_step.dependOn(&b.addRunArtifact(metrics_tests).step);
    ci_step.dependOn(&b.addRunArtifact(health_tests).step);
    ci_step.dependOn(&b.addRunArtifact(logger_tests).step);
    ci_step.dependOn(&b.addRunArtifact(auth_tests).step);
    ci_step.dependOn(&b.addRunArtifact(exe_tests).step);
    ci_step.dependOn(&b.addRunArtifact(integration_tests).step);
    ci_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
}
