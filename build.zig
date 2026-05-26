const std = @import("std");

// 虽然在 build.zig 中不能直接 import 用户代码来检查模块，
// 但我们声明模块路径供 .addModule 使用。
// 实际模块解析在 exe step 中通过 .addModule 完成。

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------
    // 模块定义
    // ---------------------------------------------------------------

    // json 模块 —— 自定义 JSON 解析/序列化
    const json_module = b.addModule("json", .{
        .root_source_file = b.path("src/zig_json.zig"),
        .target = target,
        .optimize = optimize,
    });

    // llm 模块 —— 大语言模型接口（HTTP 调用、提示词构建等）
    const llm_module = b.addModule("llm", .{
        .root_source_file = b.path("src/llm/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // tools 模块 —— 工具注册、调度与执行
    const tools_module = b.addModule("tools", .{
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "json", .module = json_module },
        },
    });

    // memory 模块 —— 对话历史、上下文窗口管理
    const memory_module = b.addModule("memory", .{
        .root_source_file = b.path("src/memory/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // agent 模块 —— Agent 核心循环，依赖 llm / tools / memory / json
    const agent_module = b.addModule("agent", .{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "llm", .module = llm_module },
            .{ .name = "tools", .module = tools_module },
            .{ .name = "memory", .module = memory_module },
            .{ .name = "json", .module = json_module },
        },
    });

    // config 模块 —— 配置加载和国际化
    const config_module = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---------------------------------------------------------------
    // 可执行文件
    // ---------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "genericagent",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 为可执行文件注入所有模块
    exe.root_module.addImport("json", json_module);
    exe.root_module.addImport("llm", llm_module);
    exe.root_module.addImport("tools", tools_module);
    exe.root_module.addImport("memory", memory_module);
    exe.root_module.addImport("agent", agent_module);
    exe.root_module.addImport("config", config_module);

    b.installArtifact(exe);

    // ---------------------------------------------------------------
    // run step（zig build run）
    // ---------------------------------------------------------------

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run genericagent");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------
    // 测试 step
    // ---------------------------------------------------------------

    // 主程序测试
    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_tests.root_module.addImport("json", json_module);
    exe_tests.root_module.addImport("llm", llm_module);
    exe_tests.root_module.addImport("tools", tools_module);
    exe_tests.root_module.addImport("memory", memory_module);
    exe_tests.root_module.addImport("agent", agent_module);

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
