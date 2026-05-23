//! src/agent/handler.zig - 工具处理器
//!
//! 对应 Python 版 ga.py 中的 GenericAgentHandler。
//! 负责：
//! - 工具注册与调度（dispatch）
//! - 无工具调用时的处理逻辑（do_no_tool）
//! - 轮次结束回调（turn_end_callback）
//! - 工作记忆（working memory）管理
//! - 历史摘要（history info）管理
//! - 锚点提示词（anchor prompt）生成

const std = @import("std");
const Allocator = std.mem.Allocator;
const std_json = std.json;

const tools = @import("tools");
const ToolDef = tools.ToolDef;
const ToolError = tools.ToolError;

const llm = @import("llm");
const ToolDefinition = llm.ToolDefinition;

// ============================================================================
// StepOutcome - 单步执行结果
// ============================================================================

/// 工具调用的执行结果
pub const StepOutcome = struct {
    /// 工具返回的文本结果
    result: []const u8,
    /// 是否为错误结果
    is_error: bool = false,
    /// 是否应该退出循环
    should_exit: bool = false,
    /// 退出时携带的附加数据
    exit_data: ?std_json.Value = null,
    /// 下一轮的提示词（注入到 tool_results 之后）
    next_prompt: ?[]const u8 = null,
};

// ============================================================================
// NoToolAction - 无工具调用时的处理动作
// ============================================================================

/// 无工具调用时的处理动作
pub const NoToolAction = enum {
    /// 继续循环，注入提示词
    continue_with_prompt,
    /// 直接退出
    exit,
};

/// 无工具调用的处理结果
pub const NoToolOutcome = struct {
    action: NoToolAction,
    /// 当 action 为 continue_with_prompt 时使用的提示词
    prompt: ?[]const u8 = null,
};

// ============================================================================
// Handler - 工具处理器
// ============================================================================

/// 通用 Agent 工具处理器
///
/// 对应 Python 版 GenericAgentHandler，负责：
/// - 接收 LLM 的 tool_call 并分发到对应的工具执行函数
/// - 管理工作记忆（working memory）
/// - 管理历史摘要（history info）
/// - 在轮次结束时执行回调逻辑
pub const Handler = struct {
    allocator: Allocator,
    /// 工具注册表
    registry: tools.Registry,
    /// 工作记忆（键值对形式）
    working: std.StringHashMap([]const u8),
    /// 历史摘要列表
    history_info: std.ArrayList([]const u8),
    /// 当前工作目录
    cwd: []const u8,
    /// 当前轮次
    current_turn: u32,
    /// 最大轮次
    max_turns: u32,
    /// 下一轮提示词（由 dispatch 设置，由 loop 消费）
    next_prompt: ?[]const u8,
    /// 全局记忆（跨任务持久化）
    global_memory: ?[]const u8,
    /// 系统提示词（用于生成 anchor prompt）
    system_prompt: []const u8,
    /// 上一次的响应文本（用于 do_no_tool 检测）
    last_response_text: []const u8,
    /// 连续空响应计数
    empty_response_count: u32,
    /// 是否启用 verbose 模式
    verbose: bool,

    /// 初始化 Handler
    pub fn init(allocator: Allocator, config: HandlerConfig) Handler {
        return .{
            .allocator = allocator,
            .registry = tools.Registry.init(allocator),
            .working = std.StringHashMap([]const u8).init(allocator),
            .history_info = std.ArrayList([]const u8).init(allocator),
            .cwd = config.cwd orelse "/workspace",
            .current_turn = 0,
            .max_turns = config.max_turns orelse 40,
            .next_prompt = null,
            .global_memory = config.global_memory,
            .system_prompt = config.system_prompt orelse "",
            .last_response_text = "",
            .empty_response_count = 0,
            .verbose = config.verbose orelse true,
        };
    }

    /// 释放资源
    pub fn deinit(self: *Handler) void {
        // 释放工作记忆中的值
        var it = self.working.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.working.deinit();

        // 释放历史摘要
        for (self.history_info.items) |item| {
            self.allocator.free(item);
        }
        self.history_info.deinit();

        // 释放 next_prompt
        if (self.next_prompt) |p| {
            self.allocator.free(p);
        }

        // 释放全局记忆
        if (self.global_memory) |m| {
            self.allocator.free(m);
        }

        self.registry.deinit();
    }

    // ================================================================
    // 工具注册
    // ================================================================

    /// 注册一个工具
    pub fn registerTool(self: *Handler, tool: ToolDef) !void {
        try self.registry.register(tool);
    }

    /// 批量注册工具
    pub fn registerTools(self: *Handler, tool_list: []const ToolDef) !void {
        for (tool_list) |tool| {
            try self.registry.register(tool);
        }
    }

    // ================================================================
    // 工具调度 - dispatch
    // ================================================================

    /// 分发工具调用到对应的执行函数
    ///
    /// 对应 Python 版 GenericAgentHandler 的工具调用逻辑。
    /// 查找注册表中匹配的工具并执行，返回 StepOutcome。
    ///
    /// 特殊工具名处理：
    /// - "exit" / "finish"：设置 should_exit 标志
    /// - "working_memory_set"：更新工作记忆
    /// - "working_memory_get"：读取工作记忆
    pub fn dispatch(
        self: *Handler,
        tool_name: []const u8,
        args: std_json.Value,
        response: []const u8,
    ) StepOutcome {
        _ = response;
        self.current_turn += 1;

        // -----------------------------------------------------------
        // 内置工具处理
        // -----------------------------------------------------------

        // exit / finish 工具：标记退出
        if (std.mem.eql(u8, tool_name, "exit") or
            std.mem.eql(u8, tool_name, "finish"))
        {
            const exit_msg = if (args == .object and args.object.get("message") != null)
                args.object.get("message").?.string
            else
                "Agent 主动退出。";

            // Clone exit_data via JSON round-trip
            var exit_data_val: ?std_json.Value = null;
            if (args == .object) {
                const data_str = std.json.stringifyAlloc(self.allocator, args, .{}) catch "";
                const parsed = std.json.parseFromSlice(std_json.Value, self.allocator, data_str, .{}) catch null;
                if (parsed) |*p| {
                    exit_data_val = p.value;
                    self.allocator.free(data_str);
                } else {
                    self.allocator.free(data_str);
                }
            }

            return .{
                .result = exit_msg,
                .should_exit = true,
                .exit_data = exit_data_val,
            };
        }

        // working_memory_set：设置工作记忆
        if (std.mem.eql(u8, tool_name, "working_memory_set")) {
            return self.handleWorkingMemorySet(args);
        }

        // working_memory_get：获取工作记忆
        if (std.mem.eql(u8, tool_name, "working_memory_get")) {
            return self.handleWorkingMemoryGet(args);
        }

        // -----------------------------------------------------------
        // 查找并执行注册的工具
        // -----------------------------------------------------------
        const tool_def = self.registry.find(tool_name) orelse {
            const err_msg = std.fmt.allocPrint(
                self.allocator,
                "工具 '{s}' 未注册。可用工具请参考系统提示词。",
                .{tool_name},
            ) catch "未知工具";

            return .{
                .result = err_msg,
                .is_error = true,
            };
        };

        // 将参数序列化为 JSON 字符串传给工具执行函数
        const args_str = std.json.stringifyAlloc(self.allocator, args, .{}) catch "{}";
        defer self.allocator.free(args_str);

        // 执行工具
        const result = tool_def.execute(args_str, self.allocator) catch |err| {
            const err_msg = std.fmt.allocPrint(
                self.allocator,
                "工具 '{s}' 执行失败: {}",
                .{ tool_name, err },
            ) catch "工具执行失败";

            return .{
                .result = err_msg,
                .is_error = true,
            };
        };

        if (self.verbose) {
            std.log.info("[handler] tool '{s}' executed, result len: {d}", .{
                tool_name,
                result.len,
            });
        }

        return .{
            .result = result,
        };
    }

    // ================================================================
    // do_no_tool - 无工具调用处理
    // ================================================================

    /// 处理 LLM 响应中没有 tool_call 的情况
    ///
    /// 对应 Python 版 do_no_tool() 逻辑：
    /// - 检测空响应（LLM 返回空内容）
    /// - 检测大代码块但未调用工具（LLM 可能在"思考"而非行动）
    /// - 检测连续空响应（可能陷入循环）
    ///
    /// 参数：
    ///   - response_text: LLM 的文本响应
    ///   - turn: 当前轮次
    ///   - no_tool_count: 连续无工具调用次数
    ///
    /// 返回：NoToolOutcome 指示下一步动作
    pub fn doNoTool(
        self: *Handler,
        response_text: []const u8,
        turn: u32,
        no_tool_count: u32,
    ) NoToolOutcome {
        _ = turn;
        // -----------------------------------------------------------
        // 检测空响应
        // -----------------------------------------------------------
        const trimmed = std.mem.trim(u8, response_text, " \t\n\r");
        if (trimmed.len == 0) {
            self.empty_response_count += 1;

            if (self.empty_response_count >= 3) {
                // 连续 3 次空响应，注入更强提示
                return .{
                    .action = .continue_with_prompt,
                    .prompt = "你已连续多次未给出有效响应。请使用可用工具来完成任务，或明确告知任务已完成。",
                };
            }

            return .{
                .action = .continue_with_prompt,
                .prompt = "你的响应为空。请使用可用工具来完成任务。",
            };
        }

        // 有内容，重置空响应计数
        self.empty_response_count = 0;

        // -----------------------------------------------------------
        // 检测大代码块未调用工具
        // -----------------------------------------------------------
        if (self.containsLargeCodeBlock(response_text, 500)) {
            return .{
                .action = .continue_with_prompt,
                .prompt = "你输出了大段代码但未调用任何工具执行。请使用适当的工具（如 write_file、run_command 等）来实际执行你的方案。",
            };
        }

        // -----------------------------------------------------------
        // 检测连续无工具调用
        // -----------------------------------------------------------
        if (no_tool_count >= 3) {
            return .{
                .action = .continue_with_prompt,
                .prompt = std.fmt.allocPrint(
                    self.allocator,
                    "你已连续 {d} 轮未使用任何工具。如果任务需要执行操作，请调用相应工具。如果任务已完成，请直接给出最终回答。",
                    .{no_tool_count},
                ) catch "请使用工具或给出最终回答。",
            };
        }

        // -----------------------------------------------------------
        // 检测与上次响应相同（可能陷入循环）
        // -----------------------------------------------------------
        if (std.mem.eql(u8, response_text, self.last_response_text) and response_text.len > 0) {
            return .{
                .action = .continue_with_prompt,
                .prompt = "你的响应与上一轮相同，可能陷入了循环。请尝试不同的方法或使用工具来推进任务。",
            };
        }

        // 更新上次响应
        self.last_response_text = response_text;

        // 默认：正常退出（LLM 给出了最终回答）
        return .{
            .action = .exit,
        };
    }

    // ================================================================
    // turnEndCallback - 轮次结束回调
    // ================================================================

    /// 轮次结束时的回调逻辑
    ///
    /// 对应 Python 版 turn_end_callback()：
    /// 1. 提取本轮摘要（如果有文本响应）
    /// 2. 检查轮数限制，接近上限时注入提醒
    /// 3. 注入全局记忆（如果存在）
    /// 4. 返回摘要文本
    ///
    /// 返回值：本轮摘要文本（可能为空）
    pub fn turnEndCallback(self: *Handler, turn: u32, max_turns: u32) []const u8 {
        // -----------------------------------------------------------
        // 1. 检查轮数限制
        // -----------------------------------------------------------
        const remaining = max_turns -| turn;
        if (remaining <= 5 and remaining > 0) {
            // 接近上限，设置提醒提示
            const warning = std.fmt.allocPrint(
                self.allocator,
                "注意：你还有 {d} 轮可用。请尽快完成任务。",
                .{remaining},
            ) catch "";
            self.setNextPrompt(warning);
        } else if (remaining == 0) {
            self.setNextPrompt("已达到最大轮次限制。请给出最终回答。");
        }

        // -----------------------------------------------------------
        // 2. 注入全局记忆（每 5 轮注入一次）
        // -----------------------------------------------------------
        if (self.global_memory) |mem| {
            if (mem.len > 0 and turn % 5 == 0) {
                const prompt = std.fmt.allocPrint(
                    self.allocator,
                    "\n[全局记忆] {s}\n",
                    .{mem},
                ) catch "";
                // 追加到现有 next_prompt
                if (self.next_prompt) |existing| {
                    const combined = std.fmt.allocPrint(
                        self.allocator,
                        "{s}\n{s}",
                        .{ existing, prompt },
                    ) catch existing;
                    self.allocator.free(prompt);
                    self.setNextPrompt(combined);
                } else {
                    self.setNextPrompt(prompt);
                }
            }
        }

        // -----------------------------------------------------------
        // 3. 返回空摘要（实际摘要由 loop 层处理）
        // -----------------------------------------------------------
        return "";
    }

    // ================================================================
    // getAnchorPrompt - 锚点提示词
    // ================================================================

    /// 获取锚点提示词
    ///
    /// 锚点提示词用于在对话历史中注入上下文信息，帮助 LLM
    /// 理解当前状态和任务进度。
    ///
    /// 参数：
    ///   - skip: 是否跳过工作记忆的注入
    pub fn getAnchorPrompt(self: *Handler, skip: bool) []const u8 {
        if (skip) return "";

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        const writer = buf.writer();

        // 工作记忆
        if (self.working.count() > 0) {
            writer.writeAll("\n[工作记忆]\n") catch {};
            var it = self.working.iterator();
            while (it.next()) |entry| {
                writer.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch {};
            }
            writer.writeAll("\n") catch {};
        }

        // 历史摘要（最近 3 条）
        const info_count = @min(self.history_info.items.len, 3);
        if (info_count > 0) {
            writer.writeAll("[历史摘要]\n") catch {};
            const start = self.history_info.items.len - info_count;
            for (self.history_info.items[start..]) |info| {
                writer.print("  - {s}\n", .{info}) catch {};
            }
            writer.writeAll("\n") catch {};
        }

        // 当前状态
        writer.print("[状态] 轮次 {d}/{d}, 工作目录: {s}\n", .{
            self.current_turn,
            self.max_turns,
            self.cwd,
        }) catch {};

        return buf.toOwnedSlice() catch "";
    }

    // ================================================================
    // getToolDefinitions - 获取工具定义列表
    // ================================================================

    /// 从注册表生成 ToolDefinition 列表（用于发送给 LLM）
    pub fn getToolDefinitions(self: *Handler, allocator: Allocator) []const ToolDefinition {
        // 预留空间
        var defs = std.ArrayList(ToolDefinition).init(allocator);
        defer defs.deinit();

        // 遍历注册表中的所有工具
        var it = self.registry.tools.iterator();
        while (it.next()) |entry| {
            const tool = entry.value_ptr.*;
            defs.append(.{
                .name = tool.name,
                .description = tool.description,
                .parameters = tool.parameters_schema,
            }) catch continue;
        }

        // 添加内置工具定义
        defs.append(.{
            .name = "exit",
            .description = "退出 Agent 循环。当任务完成或需要提前终止时调用。",
            .parameters = "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\",\"description\":\"退出消息\"}},\"required\":[]}",
        }) catch {};

        defs.append(.{
            .name = "working_memory_set",
            .description = "设置工作记忆中的键值对。用于在轮次之间保存信息。",
            .parameters = "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\",\"description\":\"键名\"},\"value\":{\"type\":\"string\",\"description\":\"值\"}},\"required\":[\"key\",\"value\"]}",
        }) catch {};

        defs.append(.{
            .name = "working_memory_get",
            .description = "获取工作记忆中的值。",
            .parameters = "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\",\"description\":\"键名\"}},\"required\":[\"key\"]}",
        }) catch {};

        return defs.toOwnedSlice() catch &[_]ToolDefinition{};
    }

    // ================================================================
    // next_prompt 管理
    // ================================================================

    /// 设置下一轮提示词
    pub fn setNextPrompt(self: *Handler, prompt: []const u8) void {
        if (self.next_prompt) |old| {
            self.allocator.free(old);
        }
        self.next_prompt = self.allocator.dupe(u8, prompt) catch null;
    }

    /// 获取并消费下一轮提示词
    pub fn getNextPrompt(self: *Handler) []const u8 {
        const prompt = self.next_prompt orelse return "";
        self.next_prompt = null;
        return prompt;
    }

    // ================================================================
    // 工作记忆管理
    // ================================================================

    /// 设置工作记忆
    pub fn setWorkingMemory(self: *Handler, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, value);

        // 如果键已存在，释放旧值
        if (self.working.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }

        try self.working.put(owned_key, owned_value);
    }

    /// 获取工作记忆
    pub fn getWorkingMemory(self: *Handler, key: []const u8) ?[]const u8 {
        return self.working.get(key);
    }

    /// 清空工作记忆
    pub fn clearWorkingMemory(self: *Handler) void {
        var it = self.working.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.working.clearRetainingCapacity();
    }

    // ================================================================
    // 历史摘要管理
    // ================================================================

    /// 添加历史摘要
    pub fn addHistoryInfo(self: *Handler, info: []const u8) !void {
        const owned = try self.allocator.dupe(u8, info);
        try self.history_info.append(owned);
    }

    /// 获取最近 N 条历史摘要
    pub fn getRecentHistoryInfo(self: *Handler, count: usize) [][]const u8 {
        const start = if (self.history_info.items.len > count)
            self.history_info.items.len - count
        else
            0;
        return self.history_info.items[start..];
    }

    /// 清空历史摘要
    pub fn clearHistoryInfo(self: *Handler) void {
        for (self.history_info.items) |item| {
            self.allocator.free(item);
        }
        self.history_info.clearRetainingCapacity();
    }

    // ================================================================
    // 全局记忆管理
    // ================================================================

    /// 设置全局记忆
    pub fn setGlobalMemory(self: *Handler, memory: []const u8) void {
        if (self.global_memory) |old| {
            self.allocator.free(old);
        }
        self.global_memory = self.allocator.dupe(u8, memory) catch null;
    }

    /// 获取全局记忆
    pub fn getGlobalMemory(self: *Handler) ?[]const u8 {
        return self.global_memory;
    }

    // ================================================================
    // 内部工具处理函数
    // ================================================================

    fn handleWorkingMemorySet(self: *Handler, args: std_json.Value) StepOutcome {
        if (args != .object) {
            return .{
                .result = "参数格式错误：需要 JSON 对象。",
                .is_error = true,
            };
        }

        const key_val = args.object.get("key");
        const key = if (key_val != null and key_val.? == .string) key_val.?.string else {
            return .{
                .result = "缺少参数: key",
                .is_error = true,
            };
        };

        const value_val = args.object.get("value");
        const value = if (value_val != null and value_val.? == .string) value_val.?.string else {
            return .{
                .result = "缺少参数: value",
                .is_error = true,
            };
        };

        self.setWorkingMemory(key, value) catch |err| {
            return .{
                .result = std.fmt.allocPrint(
                    self.allocator,
                    "设置工作记忆失败: {}",
                    .{err},
                ) catch "设置工作记忆失败",
                .is_error = true,
            };
        };

        return .{
            .result = std.fmt.allocPrint(
                self.allocator,
                "已设置工作记忆: {s} = {s}",
                .{ key, value },
            ) catch "已设置工作记忆",
        };
    }

    fn handleWorkingMemoryGet(self: *Handler, args: std_json.Value) StepOutcome {
        if (args != .object) {
            return .{
                .result = "参数格式错误：需要 JSON 对象。",
                .is_error = true,
            };
        }

        const key_val = args.object.get("key");
        const key = if (key_val != null and key_val.? == .string) key_val.?.string else {
            return .{
                .result = "缺少参数: key",
                .is_error = true,
            };
        };

        const value = self.getWorkingMemory(key) orelse {
            return .{
                .result = std.fmt.allocPrint(
                    self.allocator,
                    "工作记忆中不存在键: {s}",
                    .{key},
                ) catch "键不存在",
                .is_error = true,
            };
        };

        return .{
            .result = std.fmt.allocPrint(
                self.allocator,
                "{s} = {s}",
                .{ key, value },
            ) catch value,
        };
    }

    // ================================================================
    // 辅助函数
    // ================================================================

    /// 检测文本中是否包含大代码块
    ///
    /// 查找 ```...``` 围栏代码块，如果总长度超过 threshold 则返回 true。
    fn containsLargeCodeBlock(self: *Handler, text: []const u8, threshold: u32) bool {
        _ = self;
        const marker = "```";
        var total_code_len: u32 = 0;
        var search_start: usize = 0;

        while (std.mem.indexOfPos(u8, text, search_start, marker)) |open_pos| {
            // 查找对应的关闭标记
            const content_start = open_pos + marker.len;
            if (std.mem.indexOfPos(u8, text, content_start, marker)) |close_pos| {
                const code_len: u32 = @intCast(close_pos - content_start);
                total_code_len += code_len;
                search_start = close_pos + marker.len;
            } else {
                break;
            }
        }

        return total_code_len > threshold;
    }
};

// ============================================================================
// HandlerConfig - Handler 配置
// ============================================================================

/// Handler 初始化配置
pub const HandlerConfig = struct {
    /// 工作目录（默认 "/workspace"）
    cwd: ?[]const u8 = null,
    /// 最大轮次（默认 40）
    max_turns: ?u32 = null,
    /// 全局记忆
    global_memory: ?[]const u8 = null,
    /// 系统提示词
    system_prompt: ?[]const u8 = null,
    /// 是否启用详细日志
    verbose: ?bool = null,
};

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "Handler init and deinit" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    try testing.expectEqual(@as(u32, 0), handler.current_turn);
    try testing.expectEqual(@as(u32, 40), handler.max_turns);
}

test "Handler working memory" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    try handler.setWorkingMemory("key1", "value1");
    const val = handler.getWorkingMemory("key1");
    try testing.expect(val != null);
    try testing.expectEqualStrings("value1", val.?);

    // 覆盖
    try handler.setWorkingMemory("key1", "value2");
    const val2 = handler.getWorkingMemory("key1");
    try testing.expectEqualStrings("value2", val2.?);

    // 不存在的键
    const missing = handler.getWorkingMemory("nonexistent");
    try testing.expect(missing == null);
}

test "Handler next_prompt management" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    handler.setNextPrompt("hello");
    try testing.expectEqualStrings("hello", handler.getNextPrompt());

    // 消费后应为空
    try testing.expectEqualStrings("", handler.getNextPrompt());
}

test "Handler doNoTool - empty response" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    const outcome = handler.doNoTool("", 1, 1);
    try testing.expectEqual(NoToolAction.continue_with_prompt, outcome.action);
}

test "Handler doNoTool - normal response" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    const outcome = handler.doNoTool("任务已完成，结果是42。", 1, 0);
    try testing.expectEqual(NoToolAction.exit, outcome.action);
}

test "Handler containsLargeCodeBlock" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    // 小代码块
    const small = "```js\nconsole.log('hi');\n```";
    try testing.expect(!handler.containsLargeCodeBlock(small, 500));

    // 大代码块
    var big_code = std.ArrayList(u8).init(testing.allocator);
    defer big_code.deinit();
    big_code.appendSlice("```python\n") catch {};
    for (0..600) |_| {
        big_code.appendSlice("x = 1\n") catch {};
    }
    big_code.appendSlice("```\n") catch {};

    try testing.expect(handler.containsLargeCodeBlock(big_code.items, 500));
}

test "Handler dispatch - exit tool" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    // Create a std.json.dynamic.Value object using parseFromSlice
    const json_str = "{\"message\":\"done\"}";
    const parsed = try std.json.parseFromSlice(std_json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    const outcome = handler.dispatch("exit", parsed.value, "");
    try testing.expect(outcome.should_exit);
}

test "Handler dispatch - unknown tool" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    const outcome = handler.dispatch("nonexistent_tool", .null, "");
    try testing.expect(outcome.is_error);
}

test "Handler turnEndCallback - near limit" {
    var handler = Handler.init(testing.allocator, .{});
    defer handler.deinit();

    // 模拟接近上限
    const summary = handler.turnEndCallback(38, 40);
    _ = summary;

    const prompt = handler.getNextPrompt();
    try testing.expect(std.mem.indexOf(u8, prompt, "2") != null);
}
