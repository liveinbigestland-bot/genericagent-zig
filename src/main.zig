const std = @import("std");
const agent = @import("agent");
const llm = @import("llm");
const cfg = @import("config");

pub fn main() !void {
    try setupConsole();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = cfg.Config.load(allocator, "config.json") catch |err| {
        std.debug.print("Failed to load config.json: {}\n", .{err});
        return err;
    };
    defer config.deinit(allocator);

    const lang = cfg.getLanguage(config.language);
    const str = cfg.Strings.get(lang);

    const stdout_file = std.io.getStdOut();
    var stdout = stdout_file.writer();
    const stdin = std.io.getStdIn().reader();

    try stdout.print(
        \\======================================
        \\  {s}
        \\  {s}
        \\======================================
        \\
        \\{s}
        \\
    , .{
        str.welcome_banner,
        str.welcome_subtitle,
        str.welcome_hint,
    });

    var ag = try agent.Agent.init(allocator, .{
        .session_config = llm.SessionConfig{
            .api_key = config.api_key,
            .api_base = config.api_base,
            .model = config.model,
            .session_type = config.session_type,
        },
    });
    defer ag.deinit();

    var buf: [4096]u8 = undefined;

    while (true) {
        try stdout.writeAll(str.prompt_you);

        const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
            if (err == error.EndOfStream) {
                try stdout.print("\n{s}\n", .{str.goodbye});
                break;
            }
            return err;
        } orelse {
            try stdout.print("\n{s}\n", .{str.goodbye});
            break;
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "exit") or
            std.mem.eql(u8, trimmed, "quit") or
            std.mem.eql(u8, trimmed, "退出"))
        {
            try stdout.print("{s}\n", .{str.goodbye});
            break;
        }

        if (std.mem.eql(u8, trimmed, "clear") or
            std.mem.eql(u8, trimmed, "cls"))
        {
            try stdout.writeAll("\x1b[2J\x1b[H");
            continue;
        }

        var result = ag.runSingleWithCallbacks(trimmed, void, @as(*void, @ptrCast(&stdout)), onEvent) catch |err| {
            try stdout.print("{s}{}\n", .{ str.agent_error, err });
            continue;
        };
        defer result.deinit(allocator);

        try stdout.print("[{s}] ", .{result.reason.toString()});

        if (result.response) |resp| {
            try stdout.writeAll(resp);
        }
        try stdout.writeAll("\n\n");
    }
}

fn setupConsole() !void {
    if (@import("builtin").os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn SetConsoleOutputCP(wCodePage: u32) callconv(.C) bool;
            extern "kernel32" fn SetConsoleCP(wCodePage: u32) callconv(.C) bool;
        };
        _ = kernel32.SetConsoleOutputCP(65001);
        _ = kernel32.SetConsoleCP(65001);
    }
}

fn onEvent(ctx: *void, event: agent.LoopEvent) void {
    _ = ctx;
    const stdout = std.io.getStdOut().writer();
    switch (event) {
        .thinking => |thinking| {
            stdout.print("[思考] {s}\n", .{thinking.text}) catch {};
        },
        .text => |text| {
            stdout.print("[文本] {s}\n", .{text.text}) catch {};
        },
        else => {},
    }
}
