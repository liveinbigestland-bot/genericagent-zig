//! registry.zig - 工具注册与调度
//!
//! 定义 ToolRegistry，管理所有工具的注册和调度。
//! 提供 register() 和 dispatch() 方法，dispatch 根据 tool_name 查找并调用对应函数。
const std = @import("std");
const json = std.json;

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
    pub fn textResult(allocator: std.mem.Allocator, text: []const u8) ToolResult {
        const owned_text = allocator.dupe(u8, text) catch {
            return .{ .data = .{ .text = "" }, .should_exit = false };
        };
        return .{
            .data = .{ .text = owned_text },
            .should_exit = false,
        };
    }

    /// 创建一个错误结果
    pub fn errorResult(allocator: std.mem.Allocator, err_msg: []const u8) ToolResult {
        const owned_msg = allocator.dupe(u8, err_msg) catch {
            return .{ .data = .{ .text = "unknown error" }, .should_exit = false };
        };
        return .{
            .data = .{ .text = owned_msg },
            .should_exit = false,
        };
    }

    /// 创建一个错误结果（直接接管已分配的字符串，不重复复制）
    pub fn errorResultOwned(err_msg: []const u8) ToolResult {
        return .{
            .data = .{ .text = err_msg },
            .should_exit = false,
        };
    }

    /// 创建一个要求退出的结果
    pub fn exitResult(allocator: std.mem.Allocator, text: []const u8) ToolResult {
        const owned_text = allocator.dupe(u8, text) catch {
            return .{ .data = .{ .text = "" }, .should_exit = true };
        };
        return .{
            .data = .{ .text = owned_text },
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
                .text => {
                    // 只释放非空且长度大于0的字符串
                    if (d.text.len > 0) {
                        allocator.free(d.text);
                    }
                },
                .value => {}, // json.Value 不需要显式 deinit
            }
        }
        if (self.next_prompt) |p| {
            if (p.len > 0) {
                allocator.free(p);
            }
        }
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
    /// Handler 实例指针（用于访问工作记忆等内部状态）
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

/// 工具定义（用于发送给 LLM）
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

/// 工具调度器接口（用于依赖注入）
pub const ToolDispatcher = struct {
    ctx: *anyopaque,
    register: *const fn (ctx: *anyopaque, entry: ToolEntry) error{OutOfMemory}!void,
    registerEntries: *const fn (ctx: *anyopaque, entries: []const ToolEntry) error{OutOfMemory}!void,
    dispatch: *const fn (ctx: *anyopaque, tool_ctx: *ToolContext, tool_name: []const u8, args: json.Value, response: []const u8) ToolResult,
    getToolDefinitions: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) []const ToolDefinition,
    getToolNames: *const fn (ctx: *anyopaque) []const []const u8,
    count: *const fn (ctx: *anyopaque) usize,
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
        // 释放所有注册时复制的工具名称
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.ordered_names.deinit();
        self.entries.deinit();
        // 重置为初始状态以支持多次 deinit
        self.entries = std.StringHashMap(ToolEntry).init(self.allocator);
        self.ordered_names = std.ArrayList([]const u8).init(self.allocator);
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

    /// 获取工具定义列表（用于发送给 LLM）
    pub fn getToolDefinitions(self: *const ToolRegistry, allocator: std.mem.Allocator) ![]const ToolDefinition {
        var defs = std.ArrayList(ToolDefinition).init(allocator);
        errdefer defs.deinit();

        for (self.ordered_names.items) |name| {
            if (@intFromPtr(name.ptr) == 0 or name.len == 0) continue;
            if (self.entries.get(name)) |entry| {
                try defs.append(.{
                    .name = entry.name,
                    .description = entry.description,
                    .parameters = entry.parameters_schema,
                });
            }
        }

        return defs.toOwnedSlice();
    }

    /// 转换为 ToolDispatcher 接口
    pub fn asDispatcher(self: *ToolRegistry) ToolDispatcher {
        return .{
            .ctx = self,
            .register = registerDispatcher,
            .registerEntries = registerEntriesDispatcher,
            .dispatch = dispatchDispatcher,
            .getToolDefinitions = getToolDefinitionsDispatcher,
            .getToolNames = getToolNamesDispatcher,
            .count = countDispatcher,
        };
    }

    fn registerDispatcher(ctx: *anyopaque, entry: ToolEntry) !void {
        const self: *ToolRegistry = @ptrCast(@alignCast(ctx));
        try self.register(entry);
    }

    fn registerEntriesDispatcher(ctx: *anyopaque, entries: []const ToolEntry) !void {
        const self: *ToolRegistry = @ptrCast(@alignCast(ctx));
        for (entries) |entry| {
            try self.register(entry);
        }
    }

    fn dispatchDispatcher(ctx: *anyopaque, tool_ctx: *ToolContext, tool_name: []const u8, args: json.Value, response: []const u8) ToolResult {
        const self: *ToolRegistry = @ptrCast(@alignCast(ctx));
        return self.dispatch(tool_ctx, tool_name, args, response);
    }

    fn getToolDefinitionsDispatcher(ctx: *anyopaque, allocator: std.mem.Allocator) []const ToolDefinition {
        const self: *ToolRegistry = @ptrCast(@alignCast(ctx));
        return self.getToolDefinitions(allocator) catch &.{};
    }

    fn getToolNamesDispatcher(ctx: *anyopaque) []const []const u8 {
        const self: *ToolRegistry = @ptrCast(@alignCast(ctx));
        return self.getToolNames();
    }

    fn countDispatcher(ctx: *anyopaque) usize {
        const self: *ToolRegistry = @ptrCast(@alignCast(ctx));
        return self.count();
    }
};

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "ToolRegistry init and deinit" {
    var registry = ToolRegistry.init(testing.allocator);
    defer registry.deinit();

    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "ToolRegistry register and find" {
    var registry = ToolRegistry.init(testing.allocator);
    defer registry.deinit();

    const entry = ToolEntry{
        .name = "test_tool",
        .description = "A test tool",
        .parameters_schema = "{}",
        .func = testToolFunc,
    };

    try registry.register(entry);

    try testing.expectEqual(@as(usize, 1), registry.count());

    const found = registry.find("test_tool");
    try testing.expect(found != null);
    try testing.expectEqualStrings("test_tool", found.?.name);
}

fn testToolFunc(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = args;
    _ = response;
    return ToolResult.textResult(ctx.allocator, "test result");
}

test "ToolRegistry dispatch" {
    var registry = ToolRegistry.init(testing.allocator);
    defer registry.deinit();

    const entry = ToolEntry{
        .name = "test_dispatch",
        .description = "Test dispatch",
        .parameters_schema = "{}",
        .func = testToolFunc,
    };

    try registry.register(entry);

    var ctx = ToolContext{
        .allocator = testing.allocator,
        .cwd = "/tmp",
        .current_turn = 1,
    };

    const args = json.Value{ .null = {} };
    var result = registry.dispatch(&ctx, "test_dispatch", args, "");
    defer result.deinit(testing.allocator);

    try testing.expect(result.data != null);
}

test "ToolRegistry dispatch - tool not found" {
    var registry = ToolRegistry.init(testing.allocator);
    defer registry.deinit();

    var ctx = ToolContext{
        .allocator = testing.allocator,
        .cwd = "/tmp",
        .current_turn = 1,
    };

    const args = json.Value{ .null = {} };
    var result = registry.dispatch(&ctx, "nonexistent", args, "");
    defer result.deinit(testing.allocator);

    try testing.expect(result.data != null);
}
