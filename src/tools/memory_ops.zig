const std = @import("std");
const registry = @import("registry.zig");
const json = std.json;

const ToolResult = registry.ToolResult;
const ToolContext = registry.ToolContext;
const ToolEntry = registry.ToolEntry;

fn getStringValue(args: json.Value, key: []const u8) []const u8 {
    if (args == .object) {
        if (args.object.get(key)) |val| {
            if (val == .string) return val.string;
        }
    }
    return "";
}

/// 从 Handler 获取工作记忆的辅助函数
fn getWorkingMemory(ctx: *ToolContext, _: []const u8) []const u8 {
    _ = ctx;
    return "";
}

fn updateWorkingCheckpoint(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;
    const ki = getStringValue(args, "key_info");
    const rs = getStringValue(args, "related_sop");

    // 如果没有提供参数，尝试从工作记忆获取
    var key_info: []const u8 = ki;
    if (key_info.len == 0) {
        key_info = getWorkingMemory(ctx, "key_info");
    }
    var related_sop: []const u8 = rs;
    if (related_sop.len == 0) {
        related_sop = getWorkingMemory(ctx, "related_sop");
    }

    if (key_info.len == 0 and related_sop.len == 0) {
        return ToolResult.errorResult(ctx.allocator, "need key_info or related_sop");
    }
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/.checkpoint", .{ctx.cwd}) catch "";
    std.fs.cwd().makeDir(dir) catch |err| if (err != error.PathAlreadyExists) return ToolResult.errorResult(ctx.allocator, "dir err");
    const path = std.fmt.bufPrint(&buf, "{s}/working.json", .{dir}) catch "";
    var cb: [1024]u8 = undefined;
    const content = std.fmt.bufPrint(&cb, "{{\"key_info\": \"{s}\", \"related_sop\": \"{s}\"}}", .{ key_info, related_sop }) catch "";
    const file = std.fs.cwd().createFile(path, std.fs.File.CreateFlags{ .mode = 0o666 }) catch return ToolResult.errorResult(ctx.allocator, "file err");
    defer file.close();
    file.writeAll(content) catch return ToolResult.errorResult(ctx.allocator, "write err");
    const res = std.fmt.allocPrint(ctx.allocator, "{{\"checkpoint_path\": \"{s}\", \"success\": true}}", .{path}) catch "";
    return .{ .data = .{ .text = res } };
}

fn startLongTermUpdate(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;
    const sm = getStringValue(args, "summary");
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/.checkpoint", .{ctx.cwd}) catch "";
    const wpath = std.fmt.bufPrint(&buf, "{s}/working.json", .{dir}) catch "";
    const f = std.fs.cwd().openFile(wpath, .{}) catch return ToolResult.errorResult(ctx.allocator, "open err");
    defer f.close();
    const st = f.stat() catch return ToolResult.errorResult(ctx.allocator, "stat err");
    const sz = @as(usize, @intCast(st.size));
    const content = ctx.allocator.alloc(u8, sz) catch return ToolResult.errorResult(ctx.allocator, "alloc err");
    defer ctx.allocator.free(content);
    _ = f.readAll(content) catch return ToolResult.errorResult(ctx.allocator, "read err");
    const lt_dir = std.fmt.bufPrint(&buf, "{s}/long_term", .{dir}) catch "";
    std.fs.cwd().makeDir(lt_dir) catch |err| if (err != error.PathAlreadyExists) return ToolResult.errorResult(ctx.allocator, "dir err");
    const fname = std.fmt.bufPrint(&buf, "mem_{}.json", .{ctx.current_turn}) catch "";
    const mpath = std.fmt.bufPrint(&buf, "{s}/{s}", .{ lt_dir, fname }) catch "";
    const mf = std.fs.cwd().createFile(mpath, std.fs.File.CreateFlags{ .mode = 0o666 }) catch return ToolResult.errorResult(ctx.allocator, "create err");
    defer mf.close();
    var cb: [1024]u8 = undefined;
    const mc = std.fmt.bufPrint(&cb, "{{\"turn\": {d}, \"summary\": \"{s}\"}}", .{ ctx.current_turn, sm }) catch "";
    mf.writeAll(mc) catch return ToolResult.errorResult(ctx.allocator, "write err");
    const res = std.fmt.allocPrint(ctx.allocator, "{{\"path\": \"{s}\"}}", .{mpath}) catch "";
    return .{ .data = .{ .text = res } };
}

fn askUser(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;
    const q = getStringValue(args, "question");
    const p = if (q.len > 0) q else "Input:";
    const stdout = std.io.getStdOut().writer();
    stdout.print("[ASK] {s}> ", .{p}) catch {};
    const stdin = std.io.getStdIn().reader();
    var buf: [4096]u8 = undefined;
    const input = stdin.readUntilDelimiterOrEof(&buf, '\n') catch return ToolResult.errorResult(ctx.allocator, "read err");
    const trimmed = std.mem.trim(u8, input orelse "", " \t\r\n");
    const res = std.fmt.allocPrint(ctx.allocator, "{{\"q\": \"{s}\", \"ans\": \"{s}\"}}", .{ p, trimmed }) catch "";
    return .{ .data = .{ .text = res } };
}

pub const update_working_checkpoint: ToolEntry = .{ .name = "update_working_checkpoint", .description = "Update checkpoint", .parameters_schema = "{}", .func = updateWorkingCheckpoint };
pub const start_long_term_update: ToolEntry = .{ .name = "start_long_term_update", .description = "Long term update", .parameters_schema = "{}", .func = startLongTermUpdate };
pub const ask_user: ToolEntry = .{ .name = "ask_user", .description = "Ask user", .parameters_schema = "{}", .func = askUser };

pub fn getToolEntries() []const ToolEntry {
    return &.{ update_working_checkpoint, start_long_term_update, ask_user };
}
