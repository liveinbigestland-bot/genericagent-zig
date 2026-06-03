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

    // test_loop.zig 测试目标（独立，不依赖 install）
    const test_loop_exe = b.addExecutable(.{
        .name = "test_loop",
        .root_source_file = b.path("test_loop.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_loop_exe.root_module.addImport("llm", llm_module);
    test_loop_exe.root_module.addImport("tools", tools_module);
    test_loop_exe.root_module.addImport("agent", agent_module);
    test_loop_exe.linkLibC();

    const run_test_loop = b.addRunArtifact(test_loop_exe);

    const test_loop_step = b.step("test-loop", "Run loop test");
    test_loop_step.dependOn(&run_test_loop.step);

    // tests/tools_test.zig 测试目标
    const test_tools_exe = b.addTest(.{
        .root_source_file = b.path("tests/tools_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_tools_exe.root_module.addImport("tools", tools_module);
    test_tools_exe.linkLibC();

    const run_test_tools = b.addRunArtifact(test_tools_exe);

    const test_tools_step = b.step("test-tools", "Run tools unit tests");
    test_tools_step.dependOn(&run_test_tools.step);

    // tests/file_ops_test.zig 测试目标
    const test_file_ops_exe = b.addTest(.{
        .root_source_file = b.path("tests/file_ops_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_file_ops_exe.root_module.addImport("tools", tools_module);
    test_file_ops_exe.linkLibC();

    const run_test_file_ops = b.addRunArtifact(test_file_ops_exe);

    const test_file_ops_step = b.step("test-file-ops", "Run file_ops unit tests");
    test_file_ops_step.dependOn(&run_test_file_ops.step);

    // tests/code_run_test.zig 测试目标
    const test_code_run_exe = b.addTest(.{
        .root_source_file = b.path("tests/code_run_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_code_run_exe.root_module.addImport("tools", tools_module);
    test_code_run_exe.linkLibC();

    const run_test_code_run = b.addRunArtifact(test_code_run_exe);

    const test_code_run_step = b.step("test-code-run", "Run code_run unit tests");
    test_code_run_step.dependOn(&run_test_code_run.step);

    // tests/memory_ops_test.zig 测试目标
    const test_memory_ops_exe = b.addTest(.{
        .root_source_file = b.path("tests/memory_ops_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_memory_ops_exe.root_module.addImport("tools", tools_module);
    test_memory_ops_exe.linkLibC();

    const run_test_memory_ops = b.addRunArtifact(test_memory_ops_exe);

    const test_memory_ops_step = b.step("test-memory-ops", "Run memory_ops unit tests");
    test_memory_ops_step.dependOn(&run_test_memory_ops.step);

    // tests/web_ops_test.zig 测试目标
    const test_web_ops_exe = b.addTest(.{
        .root_source_file = b.path("tests/web_ops_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_web_ops_exe.root_module.addImport("tools", tools_module);
    test_web_ops_exe.linkLibC();

    const run_test_web_ops = b.addRunArtifact(test_web_ops_exe);
    run_test_web_ops.setEnvironmentVariable("WEB_OPS_DISABLE_AUTO_LAUNCH", "1");
    run_test_web_ops.setEnvironmentVariable("WEB_OPS_LOG_DISABLED", "1");

    const test_web_ops_step = b.step("test-web-ops", "Run web_ops unit tests");
    test_web_ops_step.dependOn(&run_test_web_ops.step);

    // test_chrome_launch.zig - Chrome 自动启动测试
    const test_chrome_launch_exe = b.addTest(.{
        .root_source_file = b.path("tests/test_chrome_launch.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_chrome_launch_exe.root_module.addImport("tools", tools_module);
    test_chrome_launch_exe.linkLibC();

    const run_test_chrome_launch = b.addRunArtifact(test_chrome_launch_exe);

    const test_chrome_launch_step = b.step("test-chrome-launch", "Test Chrome auto-launch functionality");
    test_chrome_launch_step.dependOn(&run_test_chrome_launch.step);

    // demo_agent_loop.zig 演示程序
    const demo_agent_loop_exe = b.addExecutable(.{
        .name = "demo_agent_loop",
        .root_source_file = b.path("demo_agent_loop.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_agent_loop_exe.root_module.addImport("llm", llm_module);
    demo_agent_loop_exe.root_module.addImport("tools", tools_module);
    demo_agent_loop_exe.root_module.addImport("agent", agent_module);
    demo_agent_loop_exe.linkLibC();

    const run_demo_agent_loop = b.addRunArtifact(demo_agent_loop_exe);

    const demo_step = b.step("demo", "Run Agent Loop demo");
    demo_step.dependOn(&run_demo_agent_loop.step);

    // demo_tool_optimization.zig 演示程序 - 工具优化
    const demo_tool_opt_exe = b.addExecutable(.{
        .name = "demo_tool_opt",
        .root_source_file = b.path("demo_tool_optimization.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_tool_opt_exe.root_module.addImport("llm", llm_module);
    demo_tool_opt_exe.root_module.addImport("tools", tools_module);
    demo_tool_opt_exe.root_module.addImport("agent", agent_module);
    demo_tool_opt_exe.linkLibC();

    const run_demo_tool_opt = b.addRunArtifact(demo_tool_opt_exe);

    const demo_tool_opt_step = b.step("demo-tool-opt", "Run tool optimization demo");
    demo_tool_opt_step.dependOn(&run_demo_tool_opt.step);

    // demo_high_frequency_tools.zig —— 高频工具调用测试
    const demo_hf_exe = b.addExecutable(.{
        .name = "demo_high_frequency",
        .root_source_file = b.path("demo_high_frequency_tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_hf_exe.root_module.addImport("llm", llm_module);
    demo_hf_exe.root_module.addImport("tools", tools_module);
    demo_hf_exe.root_module.addImport("agent", agent_module);
    demo_hf_exe.linkLibC();

    const run_demo_hf = b.addRunArtifact(demo_hf_exe);

    const demo_hf_step = b.step("demo-hf", "Run high frequency tool calling test");
    demo_hf_step.dependOn(&run_demo_hf.step);

    // demo_real_tools.zig —— 真实工具调用测试
    const demo_real_exe = b.addExecutable(.{
        .name = "demo_real",
        .root_source_file = b.path("demo_real_tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_real_exe.root_module.addImport("llm", llm_module);
    demo_real_exe.root_module.addImport("tools", tools_module);
    demo_real_exe.root_module.addImport("agent", agent_module);
    demo_real_exe.linkLibC();

    const run_demo_real = b.addRunArtifact(demo_real_exe);

    const demo_real_step = b.step("demo-real", "Run real tool calling test");
    demo_real_step.dependOn(&run_demo_real.step);

    // test_web_scan.zig —— web_scan 工具测试
    const test_web_scan_exe = b.addExecutable(.{
        .name = "test_web_scan",
        .root_source_file = b.path("test_web_scan.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_web_scan_exe.root_module.addImport("tools", tools_module);
    test_web_scan_exe.linkLibC();

    const run_test_web_scan = b.addRunArtifact(test_web_scan_exe);

    const test_web_scan_step = b.step("test-web-scan", "Run web_scan tool test");
    test_web_scan_step.dependOn(&run_test_web_scan.step);

    // test_concurrent_web_scan.zig —— 并发 web_scan 测试
    const test_concurrent_web_scan_exe = b.addExecutable(.{
        .name = "test_concurrent_web_scan",
        .root_source_file = b.path("test_concurrent_web_scan.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_concurrent_web_scan_exe.root_module.addImport("tools", tools_module);
    test_concurrent_web_scan_exe.linkLibC();

    const run_test_concurrent_web_scan = b.addRunArtifact(test_concurrent_web_scan_exe);

    const test_concurrent_web_scan_step = b.step("test-concurrent-web-scan", "Test concurrent web_scan requests");
    test_concurrent_web_scan_step.dependOn(&run_test_concurrent_web_scan.step);

    // test_cdp_diagnostic.zig —— CDP 诊断测试
    const test_cdp_diagnostic_exe = b.addExecutable(.{
        .name = "test_cdp_diagnostic",
        .root_source_file = b.path("test_cdp_diagnostic.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_cdp_diagnostic_exe.linkLibC();

    const run_test_cdp_diagnostic = b.addRunArtifact(test_cdp_diagnostic_exe);

    const test_cdp_diagnostic_step = b.step("test-cdp-diagnostic", "Diagnose CDP endpoint behavior");
    test_cdp_diagnostic_step.dependOn(&run_test_cdp_diagnostic.step);

    // 综合测试步骤 - 运行所有单元测试
    const test_all_step = b.step("test-all", "Run all unit tests");
    test_all_step.dependOn(&run_test_code_run.step);
    test_all_step.dependOn(&run_test_web_ops.step);
    test_all_step.dependOn(&run_test_file_ops.step);
    test_all_step.dependOn(&run_test_memory_ops.step);
    test_all_step.dependOn(&run_test_tools.step);
    test_all_step.dependOn(&run_exe_tests.step);
}
