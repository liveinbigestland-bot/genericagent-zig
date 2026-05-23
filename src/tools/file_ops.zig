//! file_ops.zig - 文件操作工具
//!
//! 提供文件读写和局部修改能力：
//! - file_read: 读取文件（支持 start, count, keyword 参数）
//! - file_write: 写入文件（支持 overwrite/append/prepend 模式）
//! - file_patch: 局部修改文件（查找唯一 old_content 替换为 new_content）

const std = @import("std");
const registry = @import("registry.zig");
const json = @import("json");

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
fn buildResult(allocator: std.mem.Allocator, comptime fields: anytype) !json.Value {
    var obj = json.Value.Object.init(allocator);
    errdefer {
        var it = obj.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        obj.deinit(allocator);
    }

    inline for (fields) |field| {
        const key = try allocator.dupe(u8, field[0]);
        try obj.put(key, field[1]);
    }

    return .{ .object = obj };
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

    const path_arg = args.getString("path") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: path");
    };

    const resolved = resolvePath(ctx.allocator, ctx.cwd, path_arg) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to resolve path: {}", .{err}) catch
            "failed to resolve path";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer ctx.allocator.free(resolved);

    // 打开并读取文件
    const file = std.fs.cwd().openFile(resolved, .{}) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to open file '{}': {}", .{
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
    const max_read_size: usize = 5 * 1024 * 1024; // 5MB 上限

    if (file_size > max_read_size) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "file too large ({} bytes, max {} bytes)",
            .{ file_size, max_read_size },
        ) catch "file too large";
        return ToolResult.errorResult(ctx.allocator, msg);
    }

    const content = ctx.allocator.alloc(u8, file_size) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "out of memory: {}", .{err}) catch
            "out of memory";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer ctx.allocator.free(content);

    const bytes_read = file.readAll(content) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to read file: {}", .{err}) catch
            "failed to read file";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    const actual_content = content[0..bytes_read];

    // 处理 keyword 参数
    if (args.getString("keyword")) |keyword| {
        const context_before: u32 = if (args.getInt("context_before")) |v|
            @as(u32, @intCast(@max(v, 0)))
        else
            2;
        const context_after: u32 = if (args.getInt("context_after")) |v|
            @as(u32, @intCast(@max(v, 0)))
        else
            2;

        const result = findKeywordLines(actual_content, keyword, context_before, context_after) catch {
            return ToolResult.errorResult(
                ctx.allocator,
                "keyword not found in file",
            );
        };

        const data = buildResult(ctx.allocator, .{
            .{ "path", .{ .string = resolved } },
            .{ "line_number", .{ .int = result.line_number } },
            .{ "matched_line", .{ .string = result.matched_line } },
            .{ "context", .{ .string = result.context } },
        }) catch |err| {
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
                "failed to build result";
            return ToolResult.errorResult(ctx.allocator, msg);
        };

        return .{ .data = data };
    }

    // 处理 start / count 参数（行号范围）
    const start_line: u32 = if (args.getInt("start")) |v|
        if (v > 0) @as(u32, @intCast(v)) else 1
    else
        1;
    const count: ?u32 = if (args.getInt("count")) |v|
        if (v > 0) @as(u32, @intCast(v)) else null
    else
        null;

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

        const data = buildResult(ctx.allocator, .{
            .{ "path", .{ .string = resolved } },
            .{ "start_line", .{ .int = start_line } },
            .{ "end_line", .{ .int = start_line + @as(u32, @intCast(end_idx - start_idx)) - 1 } },
            .{ "total_lines", .{ .int = lines.items.len } },
            .{ "content", .{ .string = selected_content } },
        }) catch |err| {
            ctx.allocator.free(selected_content);
            const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
                "failed to build result";
            return ToolResult.errorResult(ctx.allocator, msg);
        };

        return .{ .data = data };
    }

    // 默认：返回全部内容
    const owned_content = ctx.allocator.dupe(u8, actual_content) catch {
        return ToolResult.errorResult(ctx.allocator, "out of memory");
    };

    const data = buildResult(ctx.allocator, .{
        .{ "path", .{ .string = resolved } },
        .{ "size", .{ .int = bytes_read } },
        .{ "content", .{ .string = owned_content } },
    }) catch |err| {
        ctx.allocator.free(owned_content);
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 工具实现：file_write
// ============================================================================

fn fileWrite(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const path_arg = args.getString("path") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: path");
    };

    const content = args.getString("content") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: content");
    };

    const mode = args.getString("mode") orelse "overwrite";

    const resolved = resolvePath(ctx.allocator, ctx.cwd, path_arg) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to resolve path: {}", .{err}) catch
            "failed to resolve path";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer ctx.allocator.free(resolved);

    const flags: std.fs.File.OpenFlags = if (std.mem.eql(u8, mode, "append"))
        .{ .mode = .write_only }
    else if (std.mem.eql(u8, mode, "prepend"))
        .{ .mode = .read_write }
    else
        .{ .mode = .write_only };

    const file = std.fs.cwd().createFile(resolved, flags) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to create/open file '{}': {}", .{
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

    const data = buildResult(ctx.allocator, .{
        .{ "path", .{ .string = resolved } },
        .{ "mode", .{ .string = mode } },
        .{ "bytes_written", .{ .int = bytes_written } },
        .{ "success", .{ .bool = true } },
    }) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 工具实现：file_patch
// ============================================================================

fn filePatch(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const path_arg = args.getString("path") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: path");
    };

    const old_content = args.getString("old_content") orelse {
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: old_content");
    };

    const new_content = args.getString("new_content") orelse {
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
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to open file '{}': {}", .{
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
        file.setEndPos(@as(i64, @intCast(new_size))) catch {};
    }

    ctx.allocator.free(new_buf);

    const data = buildResult(ctx.allocator, .{
        .{ "path", .{ .string = resolved } },
        .{ "match_offset", .{ .int = idx } },
        .{ "old_length", .{ .int = old_content.len } },
        .{ "new_length", .{ .int = new_content.len } },
        .{ "original_size", .{ .int = bytes_read } },
        .{ "new_size", .{ .int = new_size } },
        .{ "success", .{ .bool = true } },
    }) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 公共 API：工具注册条目
// ============================================================================

/// file_read 工具定义
pub const file_read: ToolEntry = .{
    .name = "file_read",
    .description = "Read file content. Supports reading by line range (start/count) or searching by keyword. Returns file path, content, and metadata.",
    .parameters_schema =
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
    ,
    .func = fileRead,
};

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
    .func = fileWrite,
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
    .func = filePatch,
};

/// 获取所有文件操作工具的注册条目列表
pub fn getToolEntries() []const ToolEntry {
    return &.{ file_read, file_write, file_patch };
}
