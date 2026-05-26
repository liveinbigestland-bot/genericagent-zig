//! registry.zig - 工具注册与调度
//!
//! 定义 ToolRegistry，管理所有工具的注册和调度。
//! 提供 register() 和 dispatch() 方法，dispatch 根据 tool_name 查找并调用对应函数。

const std = @import("std");
const json = @import("json");

// ============================================================================
// 核心类型
// ============================================================================

/// 工具执行结果
pub const ToolResult = struct {
    /// 返回给 LLM 的数据
    data: ?Data = null,
    /// 需要追加到下一轮 prompt 的文本（可选）
    next_prompt: ?[]const u8 = null,
    /// 是否要求 Agent 退出循环
    should_exit: bool = false,

    /// 数据类型：可以是简单字符串或完整的 JSON Value
    pub const Data = union(enum) {
        text: []const u8,
        value: json.Value,
    };

    /// 创建一个仅包含文本数据的简单结果
    pub fn textResult(_: std.mem.Allocator, text: []const u8) ToolResult {
        return .{
            .data = .{ .text = text },
            .should_exit = false,
        };
    }

    /// 创建一个错误结果
    pub fn errorResult(_: std.mem.Allocator, err_msg: []const u8) ToolResult {
        return .{
            .data = .{ .text = err_msg },
            .should_exit = false,
        };
    }

    /// 创建一个要求退出的结果
    pub fn exitResult(_: std.mem.Allocator, text: []const u8) ToolResult {
        return .{
            .data = .{ .text = text },
            .should_exit = true,
        };
    }

    /// 创建一个包含 JSON Value 的结果
    pub fn jsonResult(value: json.Value) ToolResult {
        return .{
            .data = .{ .value = value },
            .should_exit = false,
        };
    }

    /// 释放 ToolResult 持有的堆内存
    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        if (self.data) |*d| {
            switch (d.*) {
                .text => allocator.free(d.text),
                .value => {},
            }
        }
        if (self.next_prompt) |p| allocator.free(p);
        self.* = .{};
    }
};

/// 工具执行上下文，传递给每个工具函数
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    /// 当前工作目录
    cwd: []const u8,
    /// 当前 Agent 循环的轮次
    current_turn: u32,
    /// Agent 实例的不透明指针（可用于回调）
    parent: ?*anyopaque = null,
};

/// 工具函数签名
pub const ToolFn = *const fn (ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult;

/// 工具注册条目
pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema 字符串，描述该工具的参数格式
    parameters_schema: []const u8,
    /// 实际执行函数
    func: ToolFn,
};

// ============================================================================
// ToolRegistry
// ============================================================================

/// 工具注册表：管理所有工具的注册和调度
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    /// 工具名称 -> 工具条目
    entries: std.StringHashMap(ToolEntry),
    /// 保持注册顺序的工具名称列表
    ordered_names: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(ToolEntry).init(allocator),
            .ordered_names = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        // 释放有序名称列表（名称本身由 entries 的 key 持有，不单独释放）
        self.ordered_names.deinit();
        self.entries.deinit();
    }

    /// 注册一个工具。name 会被复制到 allocator 管理的内存中。
    pub fn register(self: *ToolRegistry, entry: ToolEntry) !void {
        const owned_name = try self.allocator.dupe(u8, entry.name);
        errdefer self.allocator.free(owned_name);

        const owned_entry = ToolEntry{
            .name = owned_name,
            .description = entry.description,
            .parameters_schema = entry.parameters_schema,
            .func = entry.func,
        };

        try self.entries.put(owned_name, owned_entry);
        try self.ordered_names.append(owned_name);
    }

    /// 根据 tool_name 查找工具条目
    pub fn find(self: *const ToolRegistry, name: []const u8) ?ToolEntry {
        return self.entries.get(name);
    }

    /// 根据 tool_name 调度执行工具
    /// 返回 ToolResult，调用方负责在不再需要时调用 result.deinit()
    pub fn dispatch(
        self: *const ToolRegistry,
        ctx: *ToolContext,
        tool_name: []const u8,
        args: json.Value,
        response: []const u8,
    ) ToolResult {
        const entry = self.entries.get(tool_name) orelse {
            return ToolResult.errorResult(ctx.allocator, "tool not found");
        };
        return entry.func(ctx, args, response);
    }

    /// 获取所有已注册工具的名称（按注册顺序）
    pub fn getToolNames(self: *const ToolRegistry) []const []const u8 {
        return self.ordered_names.items;
    }

    /// 获取已注册工具的数量
    pub fn count(self: *const ToolRegistry) usize {
        return self.entries.count();
    }

    /// 生成所有工具定义的 JSON Schema 数组（用于发送给 LLM）
    /// 返回的字符串由 allocator 管理，调用方负责 free
    pub fn buildToolsSchema(self: *ToolRegistry) ![]const u8 {
        const std_json = std.json;

        var tools = std.ArrayList(std_json.Value).init(self.allocator);
        errdefer tools.deinit();

        for (self.ordered_names.items) |name| {
            const entry = self.entries.get(name).?;

            var func_obj = std_json.ObjectMap.init(self.allocator);
            errdefer func_obj.deinit();

            try func_obj.put("name", .{ .string = entry.name });
            try func_obj.put("description", .{ .string = entry.description });

            // parameters: 从 JSON Schema 字符串解析
            const params_val = std_json.parseFromSlice(std_json.Value, self.allocator, entry.parameters_schema, .{}) catch
                std_json.Value.null;
            defer if (params_val != .null) params_val.deinit(self.allocator);
            try func_obj.put("parameters", params_val);

            var obj = std_json.ObjectMap.init(self.allocator);
            errdefer obj.deinit();

            try obj.put("type", .{ .string = "function" });
            try obj.put("function", .{ .object = func_obj });

            try tools.append(.{ .object = obj });
        }

        return std_json.stringifyAlloc(self.allocator, tools.items, .{});
    }
};

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "ToolRegistry - register and find" {
    const allocator = testing.allocator;

    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const dummyFn: ToolFn = struct {
        fn dummy(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
            _ = args;
            _ = response;
            return ToolResult.textResult(ctx.allocator, "ok");
        }
    }.dummy;

    try registry.register(.{
        .name = "test_tool",
        .description = "A test tool",
        .parameters_schema = "{}",
        .func = dummyFn,
    });

    try testing.expectEqual(@as(usize, 1), registry.count());

    const entry = registry.find("test_tool");
    try testing.expect(entry != null);
    try testing.expectEqualStrings("test_tool", entry.?.name);
    try testing.expectEqualStrings("A test tool", entry.?.description);
}

test "ToolRegistry - dispatch" {
    const allocator = testing.allocator;

    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const echoFn: ToolFn = struct {
        fn echo(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
            _ = response;
            if (args.getString("message")) |msg| {
                return ToolResult.textResult(ctx.allocator, msg);
            }
            return ToolResult.errorResult(ctx.allocator, "missing message");
        }
    }.echo;

    try registry.register(.{
        .name = "echo",
        .description = "Echo a message",
        .parameters_schema = "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}}}",
        .func = echoFn,
    });

    var ctx = ToolContext{
        .allocator = allocator,
        .cwd = "/tmp",
        .current_turn = 1,
    };

    const args = try json.parseFromString(allocator, "{\"message\":\"hello\"}");
    defer args.deinit(allocator);

    const result = registry.dispatch(&ctx, "echo", args, "");
    defer result.deinit(allocator);

    try testing.expect(result.data != null);
    try testing.expectEqual(@as(std.meta.Tag(json.Value), .string), std.meta.activeTag(result.data.?));
    try testing.expectEqualStrings("hello", result.data.?.string);
    try testing.expect(!result.should_exit);
}

test "ToolRegistry - dispatch unknown tool" {
    const allocator = testing.allocator;

    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    var ctx = ToolContext{
        .allocator = allocator,
        .cwd = "/tmp",
        .current_turn = 1,
    };

    const args = json.Value.null;
    const result = registry.dispatch(&ctx, "nonexistent", args, "");
    defer result.deinit(allocator);

    try testing.expect(result.data != null);
    try testing.expectEqualStrings("tool not found", result.data.?.string);
}
