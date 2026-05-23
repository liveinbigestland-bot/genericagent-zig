//! memory_ops.zig - 记忆操作工具
//!
//! 提供 Agent 的记忆管理能力：
//! - update_working_checkpoint: 更新短期工作记忆（key_info + related_sop）
//! - start_long_term_update: 触发长期记忆蒸馏
//! - ask_user: 人机交互（从 stdin 读取用户输入）

const std = @import("std");
const registry = @import("registry.zig");
const json = @import("json");

const ToolResult = registry.ToolResult;
const ToolContext = registry.ToolContext;
const ToolEntry = registry.ToolEntry;

// ============================================================================
// 内部辅助函数
// ============================================================================

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

// ============================================================================
// 工具实现：update_working_checkpoint
// ============================================================================

/// 更新短期工作记忆
/// 将 key_info 和 related_sop 存储到工作检查点中
fn updateWorkingCheckpoint(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const key_info = args.getString("key_info") orelse "";
    const related_sop = args.getString("related_sop") orelse "";

    if (key_info.len == 0 and related_sop.len == 0) {
        return ToolResult.errorResult(
            ctx.allocator,
            "at least one of key_info or related_sop must be provided",
        );
    }

    // 将工作检查点写入文件：.checkpoint/working.json
    const checkpoint_dir = std.fs.path.join(ctx.allocator, &.{ ctx.cwd, ".checkpoint" }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build checkpoint path");
    };
    defer ctx.allocator.free(checkpoint_dir);

    // 创建 .checkpoint 目录（如果不存在）
    std.fs.cwd().makeDir(checkpoint_dir) catch |err| {
        // 忽略已存在的错误
        if (err != error.PathAlreadyExists) {
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "failed to create checkpoint directory: {}",
                .{err},
            ) catch "failed to create checkpoint directory";
            return ToolResult.errorResult(ctx.allocator, msg);
        }
    };

    const checkpoint_path = std.fs.path.join(ctx.allocator, &.{ checkpoint_dir, "working.json" }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build checkpoint file path");
    };
    defer ctx.allocator.free(checkpoint_path);

    // 构建检查点数据
    var checkpoint_obj = json.Value.Object.init(ctx.allocator);
    errdefer {
        var it = checkpoint_obj.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(ctx.allocator);
            ctx.allocator.free(e.key_ptr.*);
        }
        checkpoint_obj.deinit(ctx.allocator);
    }

    {
        const k1 = try ctx.allocator.dupe(u8, "key_info");
        try checkpoint_obj.put(k1, .{ .string = key_info });

        const k2 = try ctx.allocator.dupe(u8, "related_sop");
        try checkpoint_obj.put(k2, .{ .string = related_sop });

        const k3 = try ctx.allocator.dupe(u8, "updated_at");
        // 使用当前时间戳（简化：使用 turn 编号）
        const timestamp = std.fmt.allocPrint(ctx.allocator, "turn_{}", .{ctx.current_turn}) catch "unknown";
        try checkpoint_obj.put(k3, .{ .string = timestamp });
    }

    const checkpoint_val = json.Value{ .object = checkpoint_obj };
    const checkpoint_str = json.toStringPretty(ctx.allocator, &checkpoint_val) catch |err| {
        checkpoint_val.deinit(ctx.allocator);
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to serialize checkpoint: {}", .{err}) catch
            "failed to serialize checkpoint";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer ctx.allocator.free(checkpoint_str);
    checkpoint_val.deinit(ctx.allocator);

    // 写入文件
    const file = std.fs.cwd().createFile(checkpoint_path, .{ .mode = .write_only }) catch |err| {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "failed to write checkpoint file: {}",
            .{err},
        ) catch "failed to write checkpoint file";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer file.close();

    file.writeAll(checkpoint_str) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to write checkpoint data: {}", .{err}) catch
            "failed to write checkpoint data";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const data = buildResult(ctx.allocator, .{
        .{ "checkpoint_path", .{ .string = checkpoint_path } },
        .{ "key_info", .{ .string = key_info } },
        .{ "related_sop", .{ .string = related_sop } },
        .{ "success", .{ .bool = true } },
    }) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 工具实现：start_long_term_update
// ============================================================================

/// 触发长期记忆蒸馏
/// 将当前工作检查点的内容蒸馏为长期记忆
fn startLongTermUpdate(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const summary = args.getString("summary") orelse "";

    // 读取当前工作检查点
    const checkpoint_dir = std.fs.path.join(ctx.allocator, &.{ ctx.cwd, ".checkpoint" }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build checkpoint path");
    };
    defer ctx.allocator.free(checkpoint_dir);

    const checkpoint_path = std.fs.path.join(ctx.allocator, &.{ checkpoint_dir, "working.json" }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build checkpoint file path");
    };
    defer ctx.allocator.free(checkpoint_path);

    const file = std.fs.cwd().openFile(checkpoint_path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "failed to open working checkpoint: {}. Run update_working_checkpoint first.",
            .{err},
        ) catch "failed to open working checkpoint";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to stat checkpoint: {}", .{err}) catch
            "failed to stat checkpoint";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const file_size = @as(usize, @intCast(stat.size));
    const content = ctx.allocator.alloc(u8, file_size) catch {
        return ToolResult.errorResult(ctx.allocator, "out of memory");
    };
    defer ctx.allocator.free(content);

    const bytes_read = file.readAll(content) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to read checkpoint: {}", .{err}) catch
            "failed to read checkpoint";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    // 解析工作检查点
    const working = json.parseFromString(ctx.allocator, content[0..bytes_read]) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to parse checkpoint JSON: {}", .{err}) catch
            "failed to parse checkpoint JSON";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer working.deinit(ctx.allocator);

    // 提取 key_info
    const key_info = if (working.getString("key_info")) |ki| ki else "";

    // 构建长期记忆条目
    const long_term_dir = std.fs.path.join(ctx.allocator, &.{ ctx.cwd, ".checkpoint", "long_term" }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build long_term path");
    };
    defer ctx.allocator.free(long_term_dir);

    std.fs.cwd().makeDir(long_term_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "failed to create long_term directory: {}",
                .{err},
            ) catch "failed to create long_term directory";
            return ToolResult.errorResult(ctx.allocator, msg);
        }
    };

    // 生成唯一文件名（使用 turn 编号）
    const filename = std.fmt.allocPrint(
        ctx.allocator,
        "memory_turn_{}.json",
        .{ctx.current_turn},
    ) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to generate filename");
    };
    defer ctx.allocator.free(filename);

    const memory_path = std.fs.path.join(ctx.allocator, &.{ long_term_dir, filename }) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to build memory path");
    };
    defer ctx.allocator.free(memory_path);

    // 构建长期记忆数据
    var memory_obj = json.Value.Object.init(ctx.allocator);
    errdefer {
        var it = memory_obj.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(ctx.allocator);
            ctx.allocator.free(e.key_ptr.*);
        }
        memory_obj.deinit(ctx.allocator);
    }

    {
        const k1 = try ctx.allocator.dupe(u8, "source_turn");
        try memory_obj.put(k1, .{ .int = ctx.current_turn });

        const k2 = try ctx.allocator.dupe(u8, "key_info");
        try memory_obj.put(k2, .{ .string = key_info });

        const k3 = try ctx.allocator.dupe(u8, "summary");
        try memory_obj.put(k3, .{ .string = summary });

        const k4 = try ctx.allocator.dupe(u8, "distilled_from");
        try memory_obj.put(k4, .{ .string = "working_checkpoint" });
    }

    const memory_val = json.Value{ .object = memory_obj };
    const memory_str = json.toStringPretty(ctx.allocator, &memory_val) catch |err| {
        memory_val.deinit(ctx.allocator);
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to serialize memory: {}", .{err}) catch
            "failed to serialize memory";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer ctx.allocator.free(memory_str);
    memory_val.deinit(ctx.allocator);

    // 写入长期记忆文件
    const mem_file = std.fs.cwd().createFile(memory_path, .{ .mode = .write_only }) catch |err| {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "failed to create memory file: {}",
            .{err},
        ) catch "failed to create memory file";
        return ToolResult.errorResult(ctx.allocator, msg);
    };
    defer mem_file.close();

    mem_file.writeAll(memory_str) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to write memory: {}", .{err}) catch
            "failed to write memory";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const data = buildResult(ctx.allocator, .{
        .{ "memory_path", .{ .string = memory_path } },
        .{ "source_turn", .{ .int = ctx.current_turn } },
        .{ "key_info", .{ .string = key_info } },
        .{ "summary", .{ .string = summary } },
        .{ "success", .{ .bool = true } },
    }) catch |err| {
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch
            "failed to build result";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = data };
}

// ============================================================================
// 工具实现：ask_user
// ============================================================================

/// 人机交互：从 stdin 读取用户输入
fn askUser(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const question = args.getString("question") orelse "Please provide input:";

    // 向用户打印问题
    const stdout = std.io.getStdOut().writer();
    stdout.print("\n[ASK_USER] {s}\n> ", .{question}) catch {
        return ToolResult.errorResult(ctx.allocator, "failed to write to stdout");
    };
    stdout.flush() catch {};

    // 从 stdin 读取用户输入
    const stdin = std.io.getStdIn().reader();
    var buf: [4096]u8 = undefined;

    const line = stdin.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
        if (err == error.EndOfStream) {
            return ToolResult.errorResult(ctx.allocator, "user input ended (EOF)");
        }
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to read user input: {}", .{err}) catch
            "failed to read user input";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    const user_input = line orelse {
        return ToolResult.errorResult(ctx.allocator, "user input ended (EOF)");
    };

    // 去除行尾空白
    const trimmed = std.mem.trim(u8, user_input, " \t\r\n");

    // 复制到 allocator 管理的内存
    const owned_input = ctx.allocator.dupe(u8, trimmed) catch {
        return ToolResult.errorResult(ctx.allocator, "out of memory");
    };

    const data = buildResult(ctx.allocator, .{
        .{ "question", .{ .string = question } },
        .{ "user_input", .{ .string = owned_input } },
    }) catch {
        ctx.allocator.free(owned_input);
        return ToolResult.errorResult(ctx.allocator, "failed to build result");
    };

    return .{ .data = data };
}

// ============================================================================
// 公共 API：工具注册条目
// ============================================================================

/// update_working_checkpoint 工具定义
pub const update_working_checkpoint: ToolEntry = .{
    .name = "update_working_checkpoint",
    .description = "Update the short-term working checkpoint with key information and related SOP (Standard Operating Procedure). Data is saved to .checkpoint/working.json.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "key_info": {
    \\      "type": "string",
    \\      "description": "Key information to remember for the current task"
    \\    },
    \\    "related_sop": {
    \\      "type": "string",
    \\      "description": "Related Standard Operating Procedure or workflow notes"
    \\    }
    \\  }
    \\}
    ,
    .func = updateWorkingCheckpoint,
};

/// start_long_term_update 工具定义
pub const start_long_term_update: ToolEntry = .{
    .name = "start_long_term_update",
    .description = "Trigger long-term memory distillation. Reads the current working checkpoint and creates a long-term memory entry in .checkpoint/long_term/.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "summary": {
    \\      "type": "string",
    \\      "description": "Optional summary of what was learned in this session"
    \\    }
    \\  }
    \\}
    ,
    .func = startLongTermUpdate,
};

/// ask_user 工具定义
pub const ask_user: ToolEntry = .{
    .name = "ask_user",
    .description = "Ask the user a question and wait for their input from stdin. Use this when you need clarification or additional information from the user.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "question": {
    \\      "type": "string",
    \\      "description": "The question to ask the user",
    \\      "default": "Please provide input:"
    \\    }
    \\  }
    \\}
    ,
    .func = askUser,
};

/// 获取所有记忆操作工具的注册条目列表
pub fn getToolEntries() []const ToolEntry {
    return &.{ update_working_checkpoint, start_long_term_update, ask_user };
}
