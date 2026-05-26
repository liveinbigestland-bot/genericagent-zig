const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------
    // 外部依赖模块（手动设置 zigmod 依赖）
    // ---------------------------------------------------------------

    // extras 模块
    const extras_module = b.addModule("extras", .{
        .root_source_file = b.path(".zigmod/deps/git/github.com/nektro/zig-extras/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // nio 模块
    const nio_module = b.addModule("nio", .{
        .root_source_file = b.path(".zigmod/deps/git/github.com/nektro/zig-nio/nio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "extras", .module = extras_module },
        },
    });

    // intrusive-parser 模块
    const intrusive_parser_module = b.addModule("intrusive-parser", .{
        .root_source_file = b.path(".zigmod/deps/git/github.com/nektro/zig-intrusive-parser/intrusive_parser.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "extras", .module = extras_module },
            .{ .name = "nio", .module = nio_module },
        },
    });

    // ---------------------------------------------------------------
    // 内部模块定义
    // ---------------------------------------------------------------

    // json 模块 —— 使用本地 zig_json.zig
    const json_module = b.addModule("json", .{
        .root_source_file = b.path("src/zig_json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "extras", .module = extras_module },
            .{ .name = "nio", .module = nio_module },
            .{ .name = "intrusive-parser", .module = intrusive_parser_module },
        },
    });

    // llm 模块 —— 大语言模型接口
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

    // agent 模块 —— Agent 核心循环
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

    // 链接 libc（某些依赖需要）
    exe.linkLibC();

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
    exe_tests.linkLibC();

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
