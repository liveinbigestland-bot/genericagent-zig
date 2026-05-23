const std = @import("std");
const agent = @import("agent");
const llm = @import("llm");

/// 程序主入口 -- 简单的 REPL 交互式 CLI
///
/// 工作流程：
///   1. 初始化 Agent
///   2. 循环读取用户输入
///   3. 将输入交给 Agent.runSingle() 处理
///   4. 输出 Agent 的回复
///   5. 用户输入 "exit" / "quit" 退出
pub fn main() !void {
    // 使用通用分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 获取标准输入/输出的 writer 和 reader
    const stdout_file = std.io.getStdOut();
    const stdout = stdout_file.writer();
    const stdin = std.io.getStdIn().reader();

    // ---------------------------------------------------------------
    // 欢迎信息
    // ---------------------------------------------------------------
    try stdout.writeAll(
        \\======================================
        \\  GenericAgent  v0.2.0
        \\  通用 AI Agent 交互式命令行工具
        \\======================================
        \\
        \\输入消息后按回车发送，输入 exit 或 quit 退出。
        \\
    );

    // ---------------------------------------------------------------
    // 初始化 Agent
    // ---------------------------------------------------------------
    var ag = try agent.Agent.init(allocator, .{
        .session_config = llm.SessionConfig{
            .api_key = "",
            .api_base = "",
            .model = "",
            .session_type = "claude",
        },
    });
    defer ag.deinit();

    // ---------------------------------------------------------------
    // 主循环 -- REPL
    // ---------------------------------------------------------------
    var buf: [4096]u8 = undefined;

    while (true) {
        // 打印提示符
        try stdout.writeAll("you> ");

        // 读取一行用户输入
        const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            // 处理 Ctrl+D (EOF)
            if (err == error.EndOfStream) {
                try stdout.writeAll("\n再见！\n");
                break;
            }
            return err;
        } orelse {
            // EOF (Ctrl+D)
            try stdout.writeAll("\n再见！\n");
            break;
        };

        // 去除行尾的 \r（Windows 兼容）
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        // 空行跳过
        if (trimmed.len == 0) continue;

        // 退出命令
        if (std.mem.eql(u8, trimmed, "exit") or
            std.mem.eql(u8, trimmed, "quit") or
            std.mem.eql(u8, trimmed, "退出"))
        {
            try stdout.writeAll("再见！\n");
            break;
        }

        // 清屏命令
        if (std.mem.eql(u8, trimmed, "clear") or
            std.mem.eql(u8, trimmed, "cls"))
        {
            try stdout.writeAll("\x1b[2J\x1b[H");
            continue;
        }

        // -----------------------------------------------------------
        // 将用户输入交给 Agent 处理
        // -----------------------------------------------------------
        var result = ag.runSingle(trimmed) catch |err| {
            try stdout.print("Agent 错误: {}\n", .{err});
            continue;
        };
        defer result.deinit(allocator);

        // 输出退出原因
        try stdout.print("[{s}] ", .{result.reason.toString()});

        // 输出 Agent 回复
        if (result.response) |resp| {
            try stdout.writeAll(resp);
        }
        try stdout.writeAll("\n\n");
    }
}
