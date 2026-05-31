//! file_ops.zig - 文件操作工具
//!
//! 提供文件读写和局部修改能力：
//! - file_read: 读取文件（支持 start, count, keyword 参数）
//! - file_write: 写入文件（支持 overwrite/append/prepend 模式）
//! - file_patch: 局部修改文件（查找唯一 old_content 替换为 new_content）

const std = @import("std");
const registry = @import("registry.zig");
const json = std.json;

const ToolResult = registry.ToolResult;
const ToolContext = registry.ToolContext;
const ToolEntry = registry.ToolEntry;

// ============================================================================
// 内部辅助函数
// ============================================================================

/// 将路径与 cwd 拼接为绝对路径（如果 path 不是绝对路径）
fn resolvePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    return std.fs.path.join(allocator, &.{ cwd, path });
}

/// 构建一个简单的 JSON 对象结果
fn buildResultSimple(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ToolResult {
    const escaped = escapeJsonString(allocator, value) catch return ToolResult.errorResult(allocator, "failed to escape string");
    defer allocator.free(escaped);
    const data = ToolResult{
        .data = .{ .text = std.fmt.allocPrint(allocator, "{{\"{s}\": \"{s}\"}}", .{ key, escaped }) catch "{\"error\": \"failed to build result\"}" },
    };
    return data;
}

/// 转义 JSON 字符串中的特殊字符，并过滤无效 UTF-8
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        // 处理特殊字符
        switch (c) {
            '"' => try result.appendSlice("\\\""),
            '\\' => try result.appendSlice("\\\\"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            '\x08' => try result.appendSlice("\\b"),
            '\x0C' => try result.appendSlice("\\f"),
            else => {
                // 验证 UTF-8 有效性
                if (c < 0x80) {
                    // ASCII 字符
                    try result.append(c);
                } else {
                    // 多字节 UTF-8 字符
                    const len: usize = if (c < 0xE0) 2 else if (c < 0xF0) 3 else if (c < 0xF8) 4 else {
                        // 无效的 UTF-8 起始字节，跳过
                        continue;
                    };

                    if (i + len > input.len) {
                        // 不完整的 UTF-8 序列，跳过
                        continue;
                    }

                    // 验证后续字节
                    var valid = true;
                    var j: usize = 1;
                    while (j < len) : (j += 1) {
                        if ((input[i + j] & 0xC0) != 0x80) {
                            valid = false;
                            break;
                        }
                    }

                    if (valid) {
                        try result.appendSlice(input[i .. i + len]);
                        i += len - 1; // 主循环会 +1，所以这里只需要 +len-1
                    }
                }
            },
        }
    }

    return result.toOwnedSlice();
}

/// 构建简单的 JSON 字符串结果
fn buildResultStr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args);
}

/// 将文件内容按行分割，返回 ArrayList
fn readLines(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList([]const u8) {
    var lines = std.ArrayList([]const u8).init(allocator);
    var start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n') {
            const end = if (i > 0 and content[i - 1] == '\r') i - 1 else i;
            try lines.append(content[start..end]);
            start = i + 1;
        }
    }
    // 最后一段
    if (start < content.len) {
        try lines.append(content[start..]);
    }
    return lines;
}

/// 在文本中搜索关键字，返回关键字所在行号（1-based）及上下文行
fn findKeywordLines(
    content: []const u8,
    keyword: []const u8,
    context_before: u32,
    context_after: u32,
) !struct {
    line_number: u32,
    matched_line: []const u8,
    context: []const u8,
} {
    var line_num: u32 = 0;
    var start: usize = 0;
    var found_line: u32 = 0;
    var found_start: usize = 0;
    var found_end: usize = 0;

    for (content, 0..) |ch, i| {
        if (ch == '\n') {
            line_num += 1;
            const line_end = if (i > 0 and content[i - 1] == '\r') i - 1 else i;
            const line = content[start..line_end];

            if (std.mem.indexOf(u8, line, keyword) != null) {
                found_line = line_num;
                found_start = start;
                found_end = i + 1;
                break;
            }
            start = i + 1;
        }
    }

    // 检查最后一行（没有换行符结尾的情况）
    if (found_line == 0 and start < content.len) {
        line_num += 1;
        const line = content[start..];
        if (std.mem.indexOf(u8, line, keyword) != null) {
            found_line = line_num;
            found_start = start;
            found_end = content.len;
        }
    }

    if (found_line == 0) {
        return error.KeywordNotFound;
    }

    // 计算上下文范围
    var ctx_start = found_start;
    var lines_before: u32 = 0;
    while (ctx_start > 0 and lines_before < context_before) {
        ctx_start -= 1;
        if (content[ctx_start] == '\n') {
            ctx_start += 1;
            lines_before += 1;
            break;
        }
    }
    if (lines_before == 0 and ctx_start > 0) {
        // 回退到行首
        while (ctx_start > 0) : (ctx_start -= 1) {
            if (content[ctx_start - 1] == '\n') break;
        }
    }

    var ctx_end = found_end;
    var lines_after: u32 = 0;
    while (ctx_end < content.len and lines_after < context_after) {
        if (content[ctx_end] == '\n') {
            lines_after += 1;
            ctx_end += 1;
        } else {
            ctx_end += 1;
        }
    }

    return .{
        .line_number = found_line,
        .matched_line = content[found_start..found_end],
        .context = content[ctx_start..ctx_end],
    };
}

// ============================================================================
// 工具实现：file_read
// ============================================================================

fn fileRead(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    if (args != .object) {
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const path_arg = blk: {
        if (args.object.get("path")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: path");
    };

    const resolved = resolvePath(ctx.allocator, ctx.cwd, path_arg) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to resolve path: {}", .{err}) catch
            "failed to resolve path";
        if (std.mem.eql(u8, msg, "failed to resolve path")) {
            return ToolResult.errorResult(ctx.allocator, msg);
        } else {
            return ToolResult.errorResultOwned(msg);
        }
    };
    defer ctx.allocator.free(resolved);

    // 打开并读取文件
    const file = std.fs.cwd().openFile(resolved, .{}) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to open file '{s}': {}", .{
            resolved,
            err,
        }) catch "failed to open file";
        if (std.mem.eql(u8, msg, "failed to open file")) {
            return ToolResult.errorResult(ctx.allocator, msg);
        } else {
            return ToolResult.errorResultOwned(msg);
        }
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to stat file: {}", .{err}) catch
            "failed to stat file";
        if (std.mem.eql(u8, msg, "failed to stat file")) {
            return ToolResult.errorResult(ctx.allocator, msg);
        } else {
            return ToolResult.errorResultOwned(msg);
        }
    };

    const file_size = @as(usize, @intCast(stat.size));
    const max_read_size: usize = 5 * 1024 * 1024; // 5MB 上限

    if (file_size > max_read_size) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "file too large ({} bytes, max {} bytes)",
            .{ file_size, max_read_size },
        ) catch "file too large";
        if (std.mem.eql(u8, msg, "file too large")) {
            return ToolResult.errorResult(ctx.allocator, msg);
        } else {
            return ToolResult.errorResultOwned(msg);
        }
    }

    const content = ctx.allocator.alloc(u8, file_size) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "out of memory: {}", .{err}) catch
            "out of memory";
        if (std.mem.eql(u8, msg, "out of memory")) {
            return ToolResult.errorResult(ctx.allocator, msg);
        } else {
            return ToolResult.errorResultOwned(msg);
        }
    };
    defer ctx.allocator.free(content);

    const bytes_read = file.readAll(content) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to read file: {}", .{err}) catch
            "failed to read file";
        if (std.mem.eql(u8, msg, "failed to read file")) {
            return ToolResult.errorResult(ctx.allocator, msg);
        } else {
            return ToolResult.errorResultOwned(msg);
        }
    };
    const actual_content = content[0..bytes_read];

    // 处理 keyword 参数
    const keyword_opt = blk: {
        if (args.object.get("keyword")) |kw_val| {
            if (kw_val == .string) break :blk kw_val.string;
        }
        break :blk null;
    };
    if (keyword_opt) |keyword| {
        const context_before: u32 = blk: {
            if (args.object.get("context_before")) |val| {
                if (val == .integer) {
                    const v = val.integer;
                    break :blk @as(u32, @intCast(@max(v, 0)));
                }
            }
            break :blk 2;
        };
        const context_after: u32 = blk: {
            if (args.object.get("context_after")) |val| {
                if (val == .integer) {
                    const v = val.integer;
                    break :blk @as(u32, @intCast(@max(v, 0)));
                }
            }
            break :blk 2;
        };

        const result = findKeywordLines(actual_content, keyword, context_before, context_after) catch {
            return ToolResult.errorResult(
                ctx.allocator,
                "keyword not found in file",
            );
        };

        const escaped_matched = escapeJsonString(ctx.allocator, result.matched_line) catch {
            return ToolResult.errorResult(ctx.allocator, "failed to escape matched line");
        };
        defer ctx.allocator.free(escaped_matched);

        const escaped_context = escapeJsonString(ctx.allocator, result.context) catch {
            return ToolResult.errorResult(ctx.allocator, "failed to escape context");
        };
        defer ctx.allocator.free(escaped_context);

        const result_str = std.fmt.allocPrint(ctx.allocator, "{{\"path\": \"{s}\", \"line_number\": {d}, \"matched_line\": \"{s}\", \"context\": \"{s}\"}}", .{ resolved, result.line_number, escaped_matched, escaped_context }) catch {
            return ToolResult.errorResult(ctx.allocator, "failed to build result");
        };

        return .{ .data = .{ .text = result_str } };
    }

    // 处理 start / count 参数（行号范围）
    const start_line: u32 = blk: {
        if (args.object.get("start")) |val| {
            if (val == .integer) {
                const v = val.integer;
                if (v > 0) break :blk @as(u32, @intCast(v));
            }
        }
        break :blk 1;
    };
    const count: ?u32 = blk: {
        if (args.object.get("count")) |val| {
            if (val == .integer) {
                const v = val.integer;
                if (v > 0) break :blk @as(u32, @intCast(v));
            }
        }
        break :blk null;
    };

    if (start_line > 1 or count != null) {
        const lines = readLines(ctx.allocator, actual_content) catch {
            return ToolResult.errorResult(ctx.allocator, "failed to parse file lines");
        };
        defer {
            for (lines.items) |l| {
                _ = l;
                // 行是 content 的切片，不需要单独释放
            }
            lines.deinit();
        }

        const start_idx = if (start_line > 1)
            @as(usize, @intCast(start_line - 1))
        else
            0;

        if (start_idx >= lines.items.len) {
            return ToolResult.errorResult(
                ctx.allocator,
                "start line exceeds file length",
            );
        }

        const end_idx = if (count) |c|
            @min(start_idx + @as(usize, c), lines.items.len)
        else
            lines.items.len;

        // 重新组装选中的行
        var buf = std.ArrayList(u8).init(ctx.allocator);
        defer buf.deinit();

        for (lines.items[start_idx..end_idx]) |line| {
            if (buf.items.len > 0) {
                buf.append('\n') catch break;
            }
            buf.appendSlice(line) catch break;
        }

        const selected_content = buf.toOwnedSlice() catch {
            return ToolResult.errorResult(ctx.allocator, "out of memory");
        };

        const end_line = start_line + @as(u32, @intCast(end_idx - start_idx)) - 1;

        const escaped_content = escapeJsonString(ctx.allocator, selected_content) catch {
            ctx.allocator.free(selected_content);
            return ToolResult.errorResult(ctx.allocator, "failed to escape content");
        };
        defer ctx.allocator.free(escaped_content);

        const result_str = std.fmt.allocPrint(ctx.allocator, "{{\"path\": \"{s}\", \"start_line\": {d}, \"end_line\": {d}, \"total_lines\": {d}, \"content\": \"{s}\"}}", .{ resolved, start_line, end_line, lines.items.len, escaped_content }) catch {
            ctx.allocator.free(selected_content);
            return ToolResult.errorResult(ctx.allocator, "failed to build result");
        };

        ctx.allocator.free(selected_content);
        return .{ .data = .{ .text = result_str } };
    }

    // 默认：返回全部内容
    const owned_content = ctx.allocator.dupe(u8, actual_content) catch {
        return ToolResult.errorResult(ctx.allocator, "out of memory");
    };
    defer ctx.allocator.free(owned_content);

    const escaped_content = escapeJsonString(ctx.allocator, owned_content) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to escape content");
    };
    defer ctx.allocator.free(escaped_content);

    const result_str = std.fmt.allocPrint(ctx.allocator, "{{\"path\": \"{s}\", \"size\": {d}, \"content\": \"{s}\"}}", .{ resolved, bytes_read, escaped_content }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build result");
    };

    return .{ .data = .{ .text = result_str } };
}

// ============================================================================
// 工具实现：file_write
// ============================================================================

fn fileWrite(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    if (args != .object) {
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const path_arg = blk: {
        if (args.object.get("path")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: path");
    };

    const content = blk: {
        if (args.object.get("content")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: content");
    };

    const mode = blk: {
        if (args.object.get("mode")) |val| {
            if (val == .string) break :blk val.string;
        }
        break :blk "overwrite";
    };

    const resolved = resolvePath(ctx.allocator, ctx.cwd, path_arg) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to resolve path: {}", .{err}) catch
            "failed to resolve path";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer ctx.allocator.free(resolved);

    const flags: std.fs.File.CreateFlags = if (std.mem.eql(u8, mode, "append"))
        .{ .truncate = false, .read = false }
    else if (std.mem.eql(u8, mode, "prepend"))
        .{ .truncate = false, .read = true }
    else
        .{ .truncate = true, .read = false };

    const file = std.fs.cwd().createFile(resolved, flags) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to create/open file '{s}': {}", .{
            resolved,
            err,
        }) catch "failed to create/open file";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer file.close();

    if (std.mem.eql(u8, mode, "prepend")) {
        // 读取现有内容
        const stat = file.stat() catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to stat file: {}", .{err}) catch
                "failed to stat file";
            return ToolResult.errorResult(ctx.allocator, msg);
        };

        const existing_size = @as(usize, @intCast(stat.size));
        const existing = ctx.allocator.alloc(u8, existing_size) catch {
            return ToolResult.errorResult(ctx.allocator, "out of memory");
        };
        defer ctx.allocator.free(existing);

        const bytes_read = file.readAll(existing) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to read existing content: {}", .{err}) catch
                "failed to read existing content";
            return ToolResult.errorResult(ctx.allocator, msg);
        };
        _ = bytes_read;

        // 回到文件开头，写入新内容 + 现有内容
        file.seekTo(0) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to seek: {}", .{err}) catch
                "failed to seek";
            return ToolResult.errorResult(ctx.allocator, msg);
        };

        file.writeAll(content) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to write content: {}", .{err}) catch
                "failed to write content";
            return ToolResult.errorResult(ctx.allocator, msg);
        };

        file.writeAll(existing) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to write existing content: {}", .{err}) catch
                "failed to write existing content";
            return ToolResult.errorResult(ctx.allocator, msg);
        };
    } else if (std.mem.eql(u8, mode, "append")) {
        // 追加模式：先 seek 到文件末尾
        file.seekFromEnd(0) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to seek to end: {}", .{err}) catch
                "failed to seek to end";
            return ToolResult.errorResult(ctx.allocator, msg);
        };

        file.writeAll(content) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to write content: {}", .{err}) catch
                "failed to write content";
            return ToolResult.errorResult(ctx.allocator, msg);
        };
    } else {
        // overwrite 模式
        file.writeAll(content) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to write content: {}", .{err}) catch
                "failed to write content";
            return ToolResult.errorResult(ctx.allocator, msg);
        };
    }

    const bytes_written = content.len;

    const result_str = std.fmt.allocPrint(ctx.allocator, "{{\"path\": \"{s}\", \"mode\": \"{s}\", \"bytes_written\": {d}, \"success\": true}}", .{ resolved, mode, bytes_written }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build result");
    };

    return .{ .data = .{ .text = result_str } };
}

// ============================================================================
// 工具实现：file_patch
// ============================================================================

fn filePatch(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    if (args != .object) {
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const path_arg = blk: {
        if (args.object.get("path")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: path");
    };

    const old_content = blk: {
        if (args.object.get("old_content")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: old_content");
    };

    const new_content = blk: {
        if (args.object.get("new_content")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: new_content");
    };

    const resolved = resolvePath(ctx.allocator, ctx.cwd, path_arg) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to resolve path: {}", .{err}) catch
            "failed to resolve path";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer ctx.allocator.free(resolved);

    // 读取文件全部内容
    const file = std.fs.cwd().openFile(resolved, .{ .mode = .read_write }) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to open file '{s}': {}", .{
            resolved,
            err,
        }) catch "failed to open file";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to stat file: {}", .{err}) catch
            "failed to stat file";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const file_size = @as(usize, @intCast(stat.size));
    const buf = ctx.allocator.alloc(u8, file_size) catch {
        return ToolResult.errorResult(ctx.allocator, "out of memory");
    };
    defer ctx.allocator.free(buf);

    const bytes_read = file.readAll(buf) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to read file: {}", .{err}) catch
            "failed to read file";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    const original = buf[0..bytes_read];

    // 查找 old_content 在文件中的位置
    const idx = std.mem.indexOf(u8, original, old_content) orelse {
        return ToolResult.errorResult(
            ctx.allocator,
            "old_content not found in file. Make sure old_content matches exactly (including whitespace).",
        );
    };

    // 检查唯一性：确保 old_content 只出现一次
    const second_idx = std.mem.indexOfPos(u8, original, idx + old_content.len, old_content);
    if (second_idx != null) {
        return ToolResult.errorResult(
            ctx.allocator,
            "old_content appears multiple times in file. Please provide more context to make it unique.",
        );
    }

    // 构建新内容：before + new_content + after
    const before = original[0..idx];
    const after = original[idx + old_content.len ..];

    const new_size = before.len + new_content.len + after.len;
    const new_buf = ctx.allocator.alloc(u8, new_size) catch {
        return ToolResult.errorResult(ctx.allocator, "out of memory");
    };

    @memcpy(new_buf[0..before.len], before);
    @memcpy(new_buf[before.len .. before.len + new_content.len], new_content);
    @memcpy(new_buf[before.len + new_content.len ..], after);

    // 写回文件
    file.seekTo(0) catch |err| {
        ctx.allocator.free(new_buf);
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to seek: {}", .{err}) catch
            "failed to seek";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    file.writeAll(new_buf) catch |err| {
        ctx.allocator.free(new_buf);
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to write patched content: {}", .{err}) catch
            "failed to write patched content";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    // 如果新内容比旧内容短，截断文件
    if (new_size < file_size) {
        file.setEndPos(@as(u64, @intCast(new_size))) catch {};
    }

    ctx.allocator.free(new_buf);

    const result_str = std.fmt.allocPrint(ctx.allocator, "{{\"path\": \"{s}\", \"match_offset\": {d}, \"old_length\": {d}, \"new_length\": {d}, \"original_size\": {d}, \"new_size\": {d}, \"success\": true}}", .{ resolved, idx, old_content.len, new_content.len, bytes_read, new_size }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build result");
    };

    return .{ .data = .{ .text = result_str } };
}

// ============================================================================
// 公共 API：工具注册条目
// ============================================================================

/// file_read 工具定义
pub const file_read: ToolEntry = .{ .name = "file_read", .description = "Read file content. Supports reading by line range (start/count) or searching by keyword. Returns file path, content, and metadata.", .parameters_schema = 
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Path to the file to read"
    \\    },
    \\    "start": {
    \\      "type": "integer",
    \\      "description": "Starting line number (1-based, default 1)"
    \\    },
    \\    "count": {
    \\      "type": "integer",
    \\      "description": "Number of lines to read"
    \\    },
    \\    "keyword": {
    \\      "type": "string",
    \\      "description": "Keyword to search for in the file"
    \\    },
    \\    "context_before": {
    \\      "type": "integer",
    \\      "description": "Number of context lines before keyword match (default 2)"
    \\    },
    \\    "context_after": {
    \\      "type": "integer",
    \\      "description": "Number of context lines after keyword match (default 2)"
    \\    }
    \\  },
    \\  "required": ["path"]
    \\}
, .func = &fileRead };

/// file_write 工具定义
pub const file_write: ToolEntry = .{
    .name = "file_write",
    .description = "Write content to a file. Supports overwrite (default), append, and prepend modes.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Path to the file to write"
    \\    },
    \\    "content": {
    \\      "type": "string",
    \\      "description": "Content to write"
    \\    },
    \\    "mode": {
    \\      "type": "string",
    \\      "enum": ["overwrite", "append", "prepend"],
    \\      "description": "Write mode: overwrite (default), append, or prepend",
    \\      "default": "overwrite"
    \\    }
    \\  },
    \\  "required": ["path", "content"]
    \\}
    ,
    .func = &fileWrite,
};

/// file_patch 工具定义
pub const file_patch: ToolEntry = .{
    .name = "file_patch",
    .description = "Patch a file by finding a unique old_content substring and replacing it with new_content. The old_content must appear exactly once in the file.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": {
    \\      "type": "string",
    \\      "description": "Path to the file to patch"
    \\    },
    \\    "old_content": {
    \\      "type": "string",
    \\      "description": "The exact content to find and replace (must be unique in the file)"
    \\    },
    \\    "new_content": {
    \\      "type": "string",
    \\      "description": "The content to replace old_content with"
    \\    }
    \\  },
    \\  "required": ["path", "old_content", "new_content"]
    \\}
    ,
    .func = &filePatch,
};

/// 获取所有文件操作工具的注册条目列表
pub fn getToolEntries() []const ToolEntry {
    return &.{ file_read, file_write, file_patch };
}
