const std = @import("std");
const agent = @import("agent");
const llm = @import("llm");
const cfg = @import("config");
const tools = @import("tools");

pub fn main() !void {
    // 设置终端为 UTF-8 编码（Windows）
    setUtf8Encoding();

    std.debug.print("Hello, GenericAgent!\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 加载配置
    var config = cfg.Config.load(allocator, "config.json") catch |err| {
        std.debug.print("Failed to load config.json: {}\n", .{err});
        return err;
    };
    defer config.deinit(allocator);

    const lang = cfg.getLanguage(config.language);
    const str = cfg.Strings.get(lang);

    std.debug.print("{s}\n", .{str.welcome_banner});

    // 初始化 Agent
    const api_mode = llm.ApiMode.fromString(config.session_type) orelse .chat_completions;
    var ag = try agent.Agent.init(allocator, .{
        .session_config = llm.SessionConfig{
            .api_key = config.api_key,
            .base_url = config.api_base,
            .model = config.model,
            .api_mode = api_mode,
            .enable_logging = config.enable_logging,
            .log_dir = config.log_dir,
        },
        .cwd = ".",
        .verbose = true,
        .max_turns = 40,
    });
    defer ag.deinit();

    // 注册工具
    try registerTools(&ag);
    std.debug.print("Tools registered successfully\n", .{});

    // 交互式循环
    var input_buf: [4096]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    while (true) {
        // 读取用户输入
        try stdout.print("\n{s}", .{str.prompt_you});
        const input = try stdin.readUntilDelimiterOrEof(&input_buf, '\n');

        if (input == null) {
            // EOF，退出
            try stdout.print("\n{s}\n", .{str.goodbye});
            break;
        }

        const user_input = input.?;

        // 检查退出命令
        if (std.mem.eql(u8, user_input, "exit") or
            std.mem.eql(u8, user_input, "quit") or
            std.mem.eql(u8, user_input, "q"))
        {
            try stdout.print("{s}\n", .{str.goodbye});
            break;
        }

        // 运行单个任务
        try stdout.print("\nProcessing...\n", .{});

        var result = ag.runSingle(user_input) catch |err| {
            try stdout.print("{s}{}\n", .{ str.agent_error, err });
            continue;
        };
        defer result.deinit(allocator);

        // 显示结果
        if (result.response) |resp| {
            try stdout.print("\n{s}\n", .{resp});
        }
    }
}

/// 注册所有工具
fn registerTools(_: *agent.Agent) !void {
    // 注意：createDefaultRegistry 已经预注册了 file_ops 和 memory_ops
    // 这里可以注册额外的工具
    // try ag.registerToolEntries(tools.code_run.getToolEntries());
    // try ag.registerToolEntries(tools.web_ops.getToolEntries());
}

/// 验证 UTF-8 字符串是否有效
fn validateUtf8(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        const len: usize = if (c < 0x80) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else if (c < 0xF8) 4 else return false;

        if (i + len > input.len) return false;

        var j: usize = 1;
        while (j < len) {
            if (input[i + j] & 0xC0 != 0x80) return false;
            j += 1;
        }

        i += len;
    }
    return true;
}

/// 设置终端为 UTF-8 编码（Windows）
fn setUtf8Encoding() void {
    if (@import("builtin").target.os.tag == .windows) {
        const win32 = struct {
            pub extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(std.os.windows.WINAPI) c_int;
            pub extern "kernel32" fn SetConsoleCP(cp: u32) callconv(std.os.windows.WINAPI) c_int;
            pub extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(std.os.windows.WINAPI) std.os.windows.HANDLE;
            pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *u32) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
            pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: u32) callconv(std.os.windows.WINAPI) std.os.windows.BOOL;
        };

        const STD_OUTPUT_HANDLE = @as(u32, 0xFFFFFFF5);
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING = @as(u32, 0x0004);

        // 设置控制台代码页为 UTF-8
        const out_result = win32.SetConsoleOutputCP(65001);
        const in_result = win32.SetConsoleCP(65001);

        // 启用虚拟终端处理（支持更多UTF-8字符显示）
        const hConsole = win32.GetStdHandle(STD_OUTPUT_HANDLE);
        if (hConsole != std.os.windows.INVALID_HANDLE_VALUE) {
            var mode: u32 = 0;
            if (win32.GetConsoleMode(hConsole, &mode) != 0) {
                _ = win32.SetConsoleMode(hConsole, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            }
        }

        std.log.debug("UTF-8 encoding set: output={}, input={}", .{ out_result != 0, in_result != 0 });
    }
}
