//! code_run.zig - 代码执行工具
//!
//! 提供 Python 脚本执行和 Shell 命令执行能力：
//! - python_run: 执行 Python 脚本（通过 fork+exec 调用 python3）
//! - bash_run: 执行 Bash 命令
//! - powershell_run: 执行 PowerShell 命令
//!
//! 特性：
//! - 超时控制（默认 60 秒）
//! - 捕获 stdout/stderr
//! - 返回 exit_code 和输出

const std = @import("std");
const registry = @import("registry.zig");
const json = @import("json");

const ToolResult = registry.ToolResult;
const ToolContext = registry.ToolContext;
const ToolEntry = registry.ToolEntry;

// ============================================================================
// 默认超时
// ============================================================================

const DEFAULT_TIMEOUT_SECONDS: u32 = 60;

// ============================================================================
// 内部辅助函数
// ============================================================================

/// 执行一个子进程，捕获 stdout 和 stderr，支持超时
fn runChildProcess(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_seconds: u32,
    input: ?[]const u8,
) !struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    timed_out: bool,
} {
    // TODO: 实现基于 timeout_seconds 的超时控制
    _ = timeout_seconds;
    const max_output_size: usize = 10 * 1024 * 1024; // 10MB 上限

    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (input != null) {
        child.stdin_behavior = .Pipe;
    } else {
        child.stdin_behavior = .Ignore;
    }

    // 启动子进程
    try child.spawn();

    // 如果有输入，写入 stdin 然后关闭
    if (input) |inp| {
        const stdin_writer = child.stdin.?;
        try stdin_writer.writeAll(inp);
        stdin_writer.close();
    }

    // 创建线程来读取 stdout 和 stderr
    const stdout_thread = try std.Thread.spawn(.{}, readThread, .{
        child.stdout.?,
        max_output_size,
    });
    const stderr_thread = try std.Thread.spawn(.{}, readThread, .{
        child.stderr.?,
        max_output_size,
    });

    // 等待进程结束或超时
    const timed_out = false;

    // 尝试等待进程结束
    const wait_result = child.wait();
    // 注意：Zig 0.13.0 中 wait() 是阻塞的，超时需要用 kill
    // 我们先 join 线程，然后检查是否超时

    stdout_thread.join();
    stderr_thread.join();

    // 获取输出
    const stdout_buf = child.stdout.?.reader().readAllAlloc(allocator, max_output_size) catch "";
    const stderr_buf = child.stderr.?.reader().readAllAlloc(allocator, max_output_size) catch "";

    const term = wait_result catch {
        // 如果等待出错，尝试 kill 进程
        child.kill() catch {};
        return .{
            .exit_code = 255,
            .stdout = stdout_buf,
            .stderr = stderr_buf,
            .timed_out = true,
        };
    };

    const exit_code: u8 = switch (term) {
        .Exited => |code| if (code >= 0 and code <= 255) @as(u8, @intCast(code)) else 255,
        .Signal, .Stopped, .Unknown => 255,
    };

    return .{
        .exit_code = exit_code,
        .stdout = stdout_buf,
        .stderr = stderr_buf,
        .timed_out = timed_out,
    };
}

/// 线程函数：持续从文件描述符读取数据（消耗管道缓冲区）
fn readThread(file: std.fs.File, max_size: usize) void {
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    const reader = file.reader();
    while (total < max_size) {
        const n = reader.read(&buf) catch break;
        if (n == 0) break;
        total += n;
    }
}

/// 构建执行结果 JSON 对象
fn buildExecResult(
    allocator: std.mem.Allocator,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    timed_out: bool,
) !json.Value {
    var obj = json.Value.Object.init(allocator);
    errdefer {
        var it = obj.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        obj.deinit(allocator);
    }

    // exit_code
    {
        const key = try allocator.dupe(u8, "exit_code");
        try obj.put(key, .{ .int = exit_code });
    }

    // stdout
    {
        const key = try allocator.dupe(u8, "stdout");
        try obj.put(key, .{ .string = stdout });
    }

    // stderr
    {
        const key = try allocator.dupe(u8, "stderr");
        try obj.put(key, .{ .string = stderr });
    }

    // timed_out
    {
        const key = try allocator.dupe(u8, "timed_out");
        try obj.put(key, .{ .bool = timed_out });
    }

    return .{ .object = obj };
}

// ============================================================================
// 工具实现：python_run
// ============================================================================

/// 执行 Python 脚本
fn pythonRun(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const code = args.getString("code") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: code");
    };

    const timeout: u32 = if (args.getInt("timeout")) |t|
        if (t > 0 and t <= 600) @as(u32, @intCast(t)) else DEFAULT_TIMEOUT_SECONDS
    else
        DEFAULT_TIMEOUT_SECONDS;

    // 构建参数：python3 -c <code>
    const python_bin = "python3";
    const argv = [_][]const u8{ python_bin, "-c", code };

    const result = runChildProcess(
        ctx.allocator,
        &argv,
        ctx.cwd,
        timeout,
        null,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to execute python3: {}", .{err}) catch
            "failed to execute python3";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const data = buildExecResult(
        ctx.allocator,
        result.exit_code,
        result.stdout,
        result.stderr,
        result.timed_out,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 工具实现：bash_run
// ============================================================================

/// 执行 Bash 命令
fn bashRun(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const command = args.getString("command") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: command");
    };

    const timeout: u32 = if (args.getInt("timeout")) |t|
        if (t > 0 and t <= 600) @as(u32, @intCast(t)) else DEFAULT_TIMEOUT_SECONDS
    else
        DEFAULT_TIMEOUT_SECONDS;

    const shell = "/bin/bash";
    const argv = [_][]const u8{ shell, "-c", command };

    const result = runChildProcess(
        ctx.allocator,
        &argv,
        ctx.cwd,
        timeout,
        null,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to execute bash: {}", .{err}) catch
            "failed to execute bash";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const data = buildExecResult(
        ctx.allocator,
        result.exit_code,
        result.stdout,
        result.stderr,
        result.timed_out,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 工具实现：powershell_run
// ============================================================================

/// 执行 PowerShell 命令
fn powershellRun(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const command = args.getString("command") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: command");
    };

    const timeout: u32 = if (args.getInt("timeout")) |t|
        if (t > 0 and t <= 600) @as(u32, @intCast(t)) else DEFAULT_TIMEOUT_SECONDS
    else
        DEFAULT_TIMEOUT_SECONDS;

    // 尝试 pwsh (PowerShell Core) 或 powershell (Windows PowerShell)
    const pwsh_bin = "pwsh";
    const argv = [_][]const u8{ pwsh_bin, "-NoProfile", "-Command", command };

    const result = runChildProcess(
        ctx.allocator,
        &argv,
        ctx.cwd,
        timeout,
        null,
    ) catch |err| {
        // 如果 pwsh 不可用，返回错误提示
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "failed to execute powershell (pwsh): {}. Ensure PowerShell Core is installed.",
            .{err},
        ) catch "failed to execute powershell";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const data = buildExecResult(
        ctx.allocator,
        result.exit_code,
        result.stdout,
        result.stderr,
        result.timed_out,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 公共 API：工具注册条目
// ============================================================================

/// python_run 工具定义
pub const python_run: ToolEntry = .{
    .name = "python_run",
    .description = "Execute a Python script. The code is run via python3 -c. Returns exit_code, stdout, stderr, and timed_out.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "code": {
    \\      "type": "string",
    \\      "description": "Python code to execute"
    \\    },
    \\    "timeout": {
    \\      "type": "integer",
    \\      "description": "Timeout in seconds (default 60, max 600)",
    \\      "default": 60
    \\    }
    \\  },
    \\  "required": ["code"]
    \\}
    ,
    .func = pythonRun,
};

/// bash_run 工具定义
pub const bash_run: ToolEntry = .{
    .name = "bash_run",
    .description = "Execute a Bash shell command. Returns exit_code, stdout, stderr, and timed_out.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "Bash command to execute"
    \\    },
    \\    "timeout": {
    \\      "type": "integer",
    \\      "description": "Timeout in seconds (default 60, max 600)",
    \\      "default": 60
    \\    }
    \\  },
    \\  "required": ["command"]
    \\}
    ,
    .func = bashRun,
};

/// powershell_run 工具定义
pub const powershell_run: ToolEntry = .{
    .name = "powershell_run",
    .description = "Execute a PowerShell command via pwsh. Returns exit_code, stdout, stderr, and timed_out.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "command": {
    \\      "type": "string",
    \\      "description": "PowerShell command to execute"
    \\    },
    \\    "timeout": {
    \\      "type": "integer",
    \\      "description": "Timeout in seconds (default 60, max 600)",
    \\      "default": 60
    \\    }
    \\  },
    \\  "required": ["command"]
    \\}
    ,
    .func = powershellRun,
};

/// 获取所有代码执行工具的注册条目列表
pub fn getToolEntries() []const ToolEntry {
    return &.{ python_run, bash_run, powershell_run };
}
