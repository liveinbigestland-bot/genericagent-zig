const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // llm 模块
    const llm_module = b.addModule("llm", .{
        .root_source_file = b.path("src/llm/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // tools 模块
    const tools_module = b.addModule("tools", .{
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // tools 静态库目标（单独编译工具库）
    const tools_lib = b.addStaticLibrary(.{
        .name = "tools",
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools_lib.linkLibC();
    b.installArtifact(tools_lib);

    const tools_lib_step = b.step("tools", "Build tools library");
    tools_lib_step.dependOn(&tools_lib.step);

    // memory 模块
    const memory_module = b.addModule("memory", .{
        .root_source_file = b.path("src/memory/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // agent 模块 - 只声明实际使用的依赖
    const agent_module = b.addModule("agent", .{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "llm", .module = llm_module },
            .{ .name = "tools", .module = tools_module },
        },
    });

    // config 模块
    const config_module = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 可执行文件
    const exe = b.addExecutable(.{
        .name = "genericagent",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 为可执行文件注入模块
    exe.root_module.addImport("llm", llm_module);
    exe.root_module.addImport("tools", tools_module);
    exe.root_module.addImport("memory", memory_module);
    exe.root_module.addImport("agent", agent_module);
    exe.root_module.addImport("config", config_module);

    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run genericagent");
    run_step.dependOn(&run_cmd.step);

    // 测试
    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_tests.root_module.addImport("llm", llm_module);
    exe_tests.root_module.addImport("tools", tools_module);
    exe_tests.root_module.addImport("memory", memory_module);
    exe_tests.root_module.addImport("agent", agent_module);
    exe_tests.root_module.addImport("config", config_module);
    exe_tests.linkLibC();

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    // test_session.zig 测试目标（独立，不依赖 install）
    const test_session_exe = b.addExecutable(.{
        .name = "test_session",
        .root_source_file = b.path("test_session.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_session_exe.root_module.addImport("llm", llm_module);
    test_session_exe.linkLibC();

    const run_test_session = b.addRunArtifact(test_session_exe);

    const test_session_step = b.step("test-session", "Run session test");
    test_session_step.dependOn(&run_test_session.step);
}
