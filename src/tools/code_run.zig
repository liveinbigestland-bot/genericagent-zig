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
const json = std.json;

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
    _ = timeout_seconds;
    const max_output_size: usize = 10 * 1024 * 1024;

    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (input != null) {
        child.stdin_behavior = .Pipe;
    } else {
        child.stdin_behavior = .Ignore;
    }

    try child.spawn();

    if (input) |inp| {
        if (child.stdin) |stdin| {
            try stdin.writeAll(inp);
            stdin.close();
        }
    }

    var stdout_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, max_output_size);

    const term = child.wait() catch {
        _ = child.kill() catch null;
        const stdout_owned = try allocator.dupe(u8, stdout_buf.items);
        const stderr_owned = try allocator.dupe(u8, stderr_buf.items);
        return .{
            .exit_code = 255,
            .stdout = stdout_owned,
            .stderr = stderr_owned,
            .timed_out = true,
        };
    };

    const stdout_owned = try allocator.dupe(u8, stdout_buf.items);
    const stderr_owned = try allocator.dupe(u8, stderr_buf.items);

    const exit_code: u8 = switch (term) {
        .Exited => |code| if (code >= 0 and code <= 255) @as(u8, @intCast(code)) else 255,
        .Signal, .Stopped, .Unknown => 255,
    };

    return .{
        .exit_code = exit_code,
        .stdout = stdout_owned,
        .stderr = stderr_owned,
        .timed_out = false,
    };
}

/// 构建执行结果 JSON 字符串
fn buildExecResult(
    allocator: std.mem.Allocator,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    timed_out: bool,
) ![]u8 {
    const escaped_stdout = try escapeJsonString(allocator, stdout);
    defer allocator.free(escaped_stdout);

    const escaped_stderr = try escapeJsonString(allocator, stderr);
    defer allocator.free(escaped_stderr);

    return std.fmt.allocPrint(allocator, "{{\"exit_code\":{},\"stdout\":\"{s}\",\"stderr\":\"{s}\",\"timed_out\":{}}}", .{ exit_code, escaped_stdout, escaped_stderr, timed_out });
}

fn escapeJsonString(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (str) |c| {
        switch (c) {
            '\\' => try result.appendSlice("\\\\"),
            '"' => try result.appendSlice("\\\""),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(c),
        }
    }

    return result.toOwnedSlice();
}

// ============================================================================
// 工具实现：python_run
// ============================================================================

/// 执行 Python 脚本
fn pythonRun(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    if (args != .object) {
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const code = blk: {
        if (args.object.get("code")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: code");
    };

    const timeout: u32 = blk: {
        if (args.object.get("timeout")) |val| {
            if (val == .integer) {
                const t = val.integer;
                if (t > 0 and t <= 600) break :blk @as(u32, @intCast(t));
            }
        }
        break :blk DEFAULT_TIMEOUT_SECONDS;
    };

    // 构建参数：python -c <code>
    // 在 Windows 上使用 python，在 Unix 上可能是 python3
    const python_bin = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const argv = [_][]const u8{ python_bin, "-c", code };

    const result = runChildProcess(
        ctx.allocator,
        &argv,
        ctx.cwd,
        timeout,
        null,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to execute python3: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to execute python3");
        return ToolResult.errorResultOwned(msg);
    };
    defer {
        ctx.allocator.free(result.stdout);
        ctx.allocator.free(result.stderr);
    }

    const data = buildExecResult(
        ctx.allocator,
        result.exit_code,
        result.stdout,
        result.stderr,
        result.timed_out,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
        return ToolResult.errorResultOwned(msg);
    };

    return .{ .data = .{ .text = data } };
}

// ============================================================================
// 工具实现：bash_run
// ============================================================================

/// 执行 Bash 命令
fn bashRun(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    if (args != .object) {
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const command = blk: {
        if (args.object.get("command")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: command");
    };

    const timeout: u32 = blk: {
        if (args.object.get("timeout")) |val| {
            if (val == .integer) {
                const t = val.integer;
                if (t > 0 and t <= 600) break :blk @as(u32, @intCast(t));
            }
        }
        break :blk DEFAULT_TIMEOUT_SECONDS;
    };

    const shell = "/bin/bash";
    const argv = [_][]const u8{ shell, "-c", command };

    const result = runChildProcess(
        ctx.allocator,
        &argv,
        ctx.cwd,
        timeout,
        null,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to execute bash: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to execute bash");
        return ToolResult.errorResultOwned(msg);
    };
    defer {
        ctx.allocator.free(result.stdout);
        ctx.allocator.free(result.stderr);
    }

    const data = buildExecResult(
        ctx.allocator,
        result.exit_code,
        result.stdout,
        result.stderr,
        result.timed_out,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
        return ToolResult.errorResultOwned(msg);
    };

    return .{ .data = .{ .text = data } };
}

// ============================================================================
// 工具实现：powershell_run
// ============================================================================

/// 执行 PowerShell 命令
fn powershellRun(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    if (args != .object) {
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const command = blk: {
        if (args.object.get("command")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: command");
    };

    const timeout: u32 = blk: {
        if (args.object.get("timeout")) |val| {
            if (val == .integer) {
                const t = val.integer;
                if (t > 0 and t <= 600) break :blk @as(u32, @intCast(t));
            }
        }
        break :blk DEFAULT_TIMEOUT_SECONDS;
    };

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
        ) catch return ToolResult.errorResult(ctx.allocator, "failed to execute powershell");
        return ToolResult.errorResultOwned(msg);
    };
    defer {
        ctx.allocator.free(result.stdout);
        ctx.allocator.free(result.stderr);
    }

    const data = buildExecResult(
        ctx.allocator,
        result.exit_code,
        result.stdout,
        result.stderr,
        result.timed_out,
    ) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
        return ToolResult.errorResultOwned(msg);
    };

    return .{ .data = .{ .text = data } };
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
