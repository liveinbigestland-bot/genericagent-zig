//! src/agent/loop.zig - Agent 执行循环引擎
//!
//! 对应 Python 版 agent_loop.py 中的 agent_runner_loop() 函数。
//! 实现 ReAct (Reason + Act) 模式的核心循环：
//!   1. 初始化消息列表 [system_prompt, user_input]
//!   2. 循环（最多 max_turns 轮）：
//!      a. 调用 LLM 获取响应
//!      b. 解析响应中的 tool_calls
//!      c. 对每个 tool_call，调用 handler.dispatch()
//!      d. 收集 tool_results
//!      e. 检查 should_exit / next_prompt
//!      f. 调用 handler.turnEndCallback()
//!      g. 构建新的 user message（包含 tool_results + next_prompt）
//!   3. 返回 ExitReason

const std = @import("std");
const Allocator = std.mem.Allocator;

const handler_mod = @import("handler.zig");
const Handler = handler_mod.Handler;
const StepOutcome = handler_mod.StepOutcome;

const llm = @import("llm");
const llm_types = llm.types;
const llm_protocol = llm.protocol;
const Message = llm_types.Message;
const ToolCall = llm_types.ToolCall;
const ToolResult = llm_types.ToolResult;
const ToolDefinition = llm_types.ToolDefinition;
const MockResponse = llm_types.MockResponse;
const StopReason = llm_types.StopReason;
const Role = llm_types.Role;

const llm_session = llm.session;
const BaseSession = llm_session.BaseSession;

// ============================================================================
// AgentConfig - 循环配置
// ============================================================================

/// Agent 循环配置
pub const AgentConfig = struct {
    /// 最大循环轮次（默认 40）
    max_turns: u32 = 40,
    /// 是否输出详细日志
    verbose: bool = true,
    /// 每 N 轮重置工具描述（对应 Python 版 client.last_tools = ''）
    tool_reset_interval: u32 = 10,
    /// 检测大代码块未调用工具的阈值（字符数）
    large_code_threshold: u32 = 500,
    /// 连续无工具调用次数上限
    max_no_tool_count: u32 = 3,
    /// 保持的历史消息最大条数（包括 system prompt，默认 20）
    max_history_messages: u32 = 20,
    /// 启用消息滑动窗口（即只保留最新的 N 条消息）
    enable_sliding_window: bool = true,
    /// 工具结果截断的最大字符数（默认 2000）
    max_tool_result_length: u32 = 2000,
    /// 启用动态工具选择（只发送相关工具）
    enable_dynamic_tools: bool = true,
    /// 动态工具选择时发送的最大工具数量（默认 10）
    max_dynamic_tools: u32 = 10,
};

// ============================================================================
// TurnInfo - 轮次信息
// ============================================================================

/// 当前轮次信息
pub const TurnInfo = struct {
    /// 当前轮次编号（从 1 开始）
    turn: u32,
    /// 累计 token 用量
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
};

// ============================================================================
// ExitReason - 退出原因
// ============================================================================

/// Agent 循环退出原因
pub const ExitReason = enum {
    /// Agent 主动退出（调用了 exit 工具）
    exited,
    /// 当前任务完成（LLM 返回 end_turn 且无 tool_calls）
    current_task_done,
    /// 达到最大轮次限制
    max_turns_exceeded,
    /// 发生错误
    err,

    pub fn toString(self: ExitReason) []const u8 {
        return switch (self) {
            .exited => "EXITED",
            .current_task_done => "CURRENT_TASK_DONE",
            .max_turns_exceeded => "MAX_TURNS_EXCEEDED",
            .err => "ERROR",
        };
    }
};

// ============================================================================
// LoopResult - 循环结果
// ============================================================================

/// Agent 循环的最终结果
pub const LoopResult = struct {
    /// 退出原因
    reason: ExitReason,
    /// 最终的文本响应（可能为 null）
    response: ?[]const u8,
    /// 退出时携带的附加数据（如 exit 工具的参数）
    data: ?std.json.Value,
    /// 总轮次
    total_turns: u32,
    /// 总输入 token 数
    total_input_tokens: u64,
    /// 总输出 token 数
    total_output_tokens: u64,

    pub fn deinit(self: *LoopResult, allocator: Allocator) void {
        if (self.response) |r| allocator.free(r);
        // std.json.Value doesn't need explicit deinit in Zig 0.13.0
    }
};

// ============================================================================
// LoopEvent - 循环事件（用于回调/流式输出）
// ============================================================================

/// Agent 循环过程中产生的事件，通过回调传递给调用方实现流式输出。
pub const LoopEvent = union(enum) {
    /// 新的一轮开始
    turn_start: struct {
        turn: u32,
    },
    /// 收到 LLM 的 thinking 内容
    thinking: struct {
        text: []const u8,
    },
    /// 收到 LLM 的文本内容
    text: struct {
        text: []const u8,
    },
    /// 即将调用工具
    tool_call_start: struct {
        id: []const u8,
        name: []const u8,
        arguments: []const u8,
    },
    /// 工具调用完成
    tool_call_end: struct {
        id: []const u8,
        name: []const u8,
        result: []const u8,
        is_error: bool,
    },
    /// 一轮结束
    turn_end: struct {
        turn: u32,
        summary: ?[]const u8,
    },
    /// 循环结束
    loop_end: struct {
        reason: ExitReason,
        total_turns: u32,
    },
    /// 错误发生
    error_occurred: struct {
        message: []const u8,
    },
};

// ============================================================================
// LoopCallbacks - 回调接口
// ============================================================================

/// Agent 循环回调函数集合。
/// 使用 comptime 函数指针实现零开销的回调机制。
pub fn LoopCallbacks(comptime Context: type) type {
    return struct {
        /// 上下文指针
        ctx: *Context,

        /// 收到循环事件时的回调
        on_event: *const fn (ctx: *Context, event: LoopEvent) void,

        /// 构建工具描述时的回调（可用于动态修改工具列表）
        /// 返回 null 表示使用默认工具描述
        get_tools_override: ?*const fn (ctx: *Context, turn: u32) ?[]const ToolDefinition = null,
    };
}

// ============================================================================
// agentRunnerLoop - 核心循环
// ============================================================================

/// Agent 执行循环引擎
///
/// 对应 Python 版 agent_runner_loop() 函数。
/// 使用回调模式实现流式输出，避免 Zig 中缺乏 generator/async 的限制。
///
/// 参数：
///   - allocator: 内存分配器
///   - session: LLM 会话（BaseSession 接口）
///   - handler: 工具处理器
///   - system_prompt: 系统提示词
///   - user_input: 用户输入
///   - config: 循环配置
///   - callbacks: 回调函数集合（可选，用于流式输出）
///
/// 返回：LoopResult 包含退出原因和最终结果
pub fn agentRunnerLoop(
    allocator: Allocator,
    session: *BaseSession,
    handler: *Handler,
    system_prompt: []const u8,
    user_input: []const u8,
    config: AgentConfig,
) !LoopResult {
    // 无回调版本：使用 noop 回调
    return agentRunnerLoopWithCallbacks(allocator, session, handler, system_prompt, user_input, config, void, null, null);
}

///   - history: 可选的现有消息历史（用于继续对话）
///
/// 返回：LoopResult 包含退出原因和最终结果
pub fn agentRunnerLoopWithHistory(
    allocator: Allocator,
    session: *BaseSession,
    handler: *Handler,
    system_prompt: []const u8,
    user_input: []const u8,
    config: AgentConfig,
    history: ?[]Message,
) !LoopResult {
    // 无回调版本：使用 noop 回调
    return agentRunnerLoopWithCallbacks(allocator, session, handler, system_prompt, user_input, config, void, null, history);
}

/// 带回调的 Agent 执行循环引擎
pub fn agentRunnerLoopWithCallbacks(
    allocator: Allocator,
    session: *BaseSession,
    handler: *Handler,
    system_prompt: []const u8,
    user_input: []const u8,
    config: AgentConfig,
    comptime Context: type,
    callbacks: ?*const LoopCallbacks(Context),
    history: ?[]Message,
) !LoopResult {
    // ---------------------------------------------------------------
    // 1. 初始化消息列表
    // ---------------------------------------------------------------
    var messages = std.ArrayList(Message).init(allocator);
    defer {
        for (messages.items) |*msg| {
            msg.deinit(allocator);
        }
        messages.deinit();
    }

    if (config.verbose) {
        std.log.info("[loop] 初始化消息列表...", .{});
        if (history) |hist| {
            std.log.info("[loop] 使用历史消息: {d} 条", .{hist.len});
        } else {
            std.log.info("[loop] 没有历史消息，开始新对话", .{});
        }
    }

    // 如果有历史消息，使用历史（跳过 system prompt，因为会单独添加）
    if (history) |hist| {
        for (hist) |msg| {
            if (msg.role != .system) {
                try messages.append(.{
                    .role = msg.role,
                    .content = if (msg.content) |c| try allocator.dupe(u8, c) else null,
                    .content_blocks = if (msg.content_blocks) |blocks| blk: {
                        const new_blocks = try allocator.alloc(llm_types.ContentBlock, blocks.len);
                        for (blocks, 0..) |block, i| {
                            new_blocks[i] = .{
                                .tag = block.tag,
                                .thinking = if (block.thinking) |t| try allocator.dupe(u8, t) else null,
                                .text = if (block.text) |t| try allocator.dupe(u8, t) else null,
                                .id = if (block.id) |t| try allocator.dupe(u8, t) else null,
                                .name = if (block.name) |t| try allocator.dupe(u8, t) else null,
                                .input = if (block.input) |*input| blk2: {
                                    const args_str = try std.json.stringifyAlloc(allocator, input.*, .{});
                                    defer allocator.free(args_str);
                                    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_str, .{});
                                    break :blk2 parsed.value;
                                } else null,
                                .tool_use_id = if (block.tool_use_id) |t| try allocator.dupe(u8, t) else null,
                                .content = if (block.content) |t| try allocator.dupe(u8, t) else null,
                                .is_error = block.is_error,
                                .source_type = if (block.source_type) |t| try allocator.dupe(u8, t) else null,
                                .media_type = if (block.media_type) |t| try allocator.dupe(u8, t) else null,
                                .data = if (block.data) |t| try allocator.dupe(u8, t) else null,
                            };
                        }
                        break :blk new_blocks;
                    } else null,
                });
            }
        }
    }

    // 添加 system prompt（如果历史为空或历史中没有 system prompt）
    if (history == null or history.?.len == 0) {
        if (config.verbose) {
            std.log.info("[loop] 添加系统提示词: {d} 字符", .{system_prompt.len});
        }
        try messages.append(.{
            .role = .system,
            .content = try allocator.dupe(u8, system_prompt),
        });
    }

    // 添加用户输入
    if (config.verbose) {
        std.log.info("[loop] 添加用户输入: {d} 字符", .{user_input.len});
    }
    try messages.append(.{
        .role = .user,
        .content = try allocator.dupe(u8, user_input),
    });

    if (config.verbose) {
        std.log.info("[loop] 初始化完成，消息列表: {d} 条", .{messages.items.len});
    }

    // ---------------------------------------------------------------
    // 2. 循环
    // ---------------------------------------------------------------
    var turn: u32 = 0;
    var total_input_tokens: u64 = 0;
    var total_output_tokens: u64 = 0;
    var last_tools_reset_turn: u32 = 0;
    var no_tool_count: u32 = 0;
    var final_response: ?[]const u8 = null;
    var exit_data: ?std.json.Value = null;
    var total_estimated_tool_tokens_saved: i64 = 0;

    // 获取完整的工具定义（用于初始显示）
    const all_tool_defs = handler.getToolDefinitions(allocator);
    defer allocator.free(all_tool_defs);

    if (config.verbose) {
        std.log.info("[loop] 完整工具列表: {d} 个", .{all_tool_defs.len});
    }

    while (turn < config.max_turns) : (turn += 1) {
        const turn_num = turn + 1;

        // 通知回调：轮次开始
        if (callbacks) |cb| {
            cb.on_event(cb.ctx, .{ .turn_start = .{ .turn = turn_num } });
        }

        if (config.verbose) {
            std.log.info("[loop] ===== 第 {d}/{d} 轮开始 =====", .{ turn_num, config.max_turns });
            std.log.info("[loop] 当前消息历史: {d} 条", .{messages.items.len});
            logMessageStats(messages.items, config.verbose);
        }

        // 应用消息滑动窗口优化
        try applySlidingWindow(&messages, config, allocator);

        // 选择有效的工具定义
        var effective_tools: ?[]const ToolDefinition = null;
        var tools_need_free = false;

        // 首先检查回调是否覆盖工具列表
        if (callbacks) |cb| {
            if (cb.get_tools_override) |get_tools| {
                effective_tools = get_tools(cb.ctx, turn_num);
            }
        }

        // 如果没有回调覆盖，使用动态工具选择或完整工具列表
        if (effective_tools == null) {
            if (config.enable_dynamic_tools) {
                // 使用动态工具选择
                effective_tools = handler.getFilteredToolDefinitions(allocator, config.max_dynamic_tools);
                tools_need_free = true;

                // 计算并累加估计的 Token 节省
                if (effective_tools != null) {
                    var total_all_chars: usize = 0;
                    var total_selected_chars: usize = 0;

                    for (all_tool_defs) |tool| {
                        total_all_chars += tool.name.len;
                        total_all_chars += tool.description.len;
                        total_all_chars += tool.parameters.len;
                    }

                    for (effective_tools.?) |tool| {
                        total_selected_chars += tool.name.len;
                        total_selected_chars += tool.description.len;
                        total_selected_chars += tool.parameters.len;
                    }

                    const saved_chars: isize = @as(isize, @intCast(total_all_chars)) - @as(isize, @intCast(total_selected_chars));
                    const estimated_saved_tokens = @divTrunc(saved_chars, 3);
                    total_estimated_tool_tokens_saved += estimated_saved_tokens;
                }
            } else {
                // 使用完整工具列表
                effective_tools = all_tool_defs;
            }
        }

        // 每 tool_reset_interval 轮可以重置（这里我们已经每轮都重新选择工具了）
        if (turn_num - last_tools_reset_turn >= config.tool_reset_interval) {
            last_tools_reset_turn = turn_num;
            if (config.verbose) {
                std.log.info("[loop] 达到工具重置间隔 ({d} 轮)", .{config.tool_reset_interval});
            }
        }

        // -----------------------------------------------------------
        // a. 调用 LLM 获取响应
        // -----------------------------------------------------------
        if (config.verbose) {
            std.log.info("[loop] 正在调用 LLM 获取响应...", .{});
        }

        var llm_response = session.complete(messages.items, effective_tools, turn_num) catch |err| {
            std.log.err("[loop] LLM 调用失败 (第 {d} 轮): {}", .{ turn_num, err });

            // 通知回调：错误
            if (callbacks) |cb| {
                const err_msg = std.fmt.allocPrint(allocator, "LLM call failed: {}", .{err}) catch "unknown error";
                defer allocator.free(err_msg);
                cb.on_event(cb.ctx, .{ .error_occurred = .{ .message = err_msg } });
            }

            return LoopResult{
                .reason = .err,
                .response = final_response,
                .data = exit_data,
                .total_turns = turn_num,
                .total_input_tokens = total_input_tokens,
                .total_output_tokens = total_output_tokens,
            };
        };
        defer llm_response.deinit(allocator);

        total_input_tokens += llm_response.usage.input_tokens;
        total_output_tokens += llm_response.usage.output_tokens;

        if (config.verbose) {
            std.log.info("[loop] LLM 响应成功", .{});
            std.log.info("[loop] Token 使用: 输入 {d}, 输出 {d}, 累计输入 {d}, 累计输出 {d}", .{ llm_response.usage.input_tokens, llm_response.usage.output_tokens, total_input_tokens, total_output_tokens });
        }

        // 通知回调：thinking 内容
        if (llm_response.thinking) |thinking_text| {
            if (thinking_text.len > 0) {
                if (config.verbose) {
                    std.log.info("[loop] Thinking 内容: {d} 字符", .{thinking_text.len});
                }
                if (callbacks) |cb| {
                    cb.on_event(cb.ctx, .{ .thinking = .{ .text = thinking_text } });
                }
            }
        }

        // 通知回调：文本内容
        if (llm_response.content) |content_text| {
            if (content_text.len > 0) {
                if (config.verbose) {
                    std.log.info("[loop] LLM 文本回复: {d} 字符", .{content_text.len});
                }
                if (callbacks) |cb| {
                    cb.on_event(cb.ctx, .{ .text = .{ .text = content_text } });
                }
            }
        }

        // -----------------------------------------------------------
        // b. 解析响应中的 tool_calls
        // -----------------------------------------------------------
        const tool_calls = llm_response.tool_calls orelse &[0]ToolCall{};

        // 将 assistant 消息加入历史
        // 构建 content_blocks 来保存完整的 assistant 响应
        var content_blocks = std.ArrayList(llm_types.ContentBlock).init(allocator);
        defer {
            for (content_blocks.items) |*b| b.deinit(allocator);
            content_blocks.deinit();
        }

        // 如果有完整的 content_blocks，直接使用
        if (llm_response.content_blocks) |blocks| {
            for (blocks) |block| {
                try content_blocks.append(.{
                    .tag = block.tag,
                    .thinking = if (block.thinking) |t| try allocator.dupe(u8, t) else null,
                    .text = if (block.text) |t| try allocator.dupe(u8, t) else null,
                    .id = if (block.id) |t| try allocator.dupe(u8, t) else null,
                    .name = if (block.name) |t| try allocator.dupe(u8, t) else null,
                    .input = if (block.input) |*input| blk: {
                        const args_str = try std.json.stringifyAlloc(allocator, input.*, .{});
                        defer allocator.free(args_str);
                        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_str, .{});
                        break :blk parsed.value;
                    } else null,
                });
            }
        } else {
            // 回退到旧的构建方式
            if (llm_response.thinking) |t| {
                if (t.len > 0) {
                    try content_blocks.append(.{
                        .tag = .thinking,
                        .thinking = try allocator.dupe(u8, t),
                        .text = try allocator.dupe(u8, t),
                    });
                }
            }

            if (llm_response.content) |c| {
                if (c.len > 0) {
                    try content_blocks.append(.{
                        .tag = .text,
                        .text = try allocator.dupe(u8, c),
                    });
                }
            }
        }

        // 添加 tool_calls 作为 content_blocks
        for (tool_calls) |*tc| {
            var args_str: []const u8 = "{}";
            var args_str_owned = false;
            if (std.json.stringifyAlloc(allocator, tc.arguments, .{}) catch null) |s| {
                args_str = s;
                args_str_owned = true;
            }
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                args_str,
                .{},
            ) catch {
                if (args_str_owned) allocator.free(args_str);
                break;
            };

            // 深拷贝 JSON 值，避免悬空指针
            const cloned_input = try llm_protocol.cloneJsonValue(allocator, parsed.value);
            parsed.deinit();
            if (args_str_owned) allocator.free(args_str);

            try content_blocks.append(.{
                .tag = .tool_use,
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.name),
                .input = cloned_input,
            });
        }

        if (content_blocks.items.len > 0) {
            const blocks_owned = try allocator.alloc(llm_types.ContentBlock, content_blocks.items.len);
            @memcpy(blocks_owned, content_blocks.items);
            content_blocks.items.len = 0;

            try messages.append(.{
                .role = .assistant,
                .content_blocks = blocks_owned,
            });
        }

        // -----------------------------------------------------------
        // c. 处理 tool_calls 或 no_tool 情况
        // -----------------------------------------------------------
        if (config.verbose) {
            std.log.info("[loop] 检测到工具调用: {d} 个", .{tool_calls.len});
        }

        if (tool_calls.len == 0) {
            // 无工具调用 → 触发 no_tool 处理
            no_tool_count += 1;
            if (config.verbose) {
                std.log.info("[loop] 无工具调用，连续次数: {d}/{d}", .{ no_tool_count, config.max_no_tool_count });
            }

            const response_text = llm_response.content orelse "";

            // 检查是否需要退出
            if (llm_response.stop_reason == .end_turn or
                llm_response.stop_reason == .stop_sequence)
            {
                // LLM 认为任务完成
                final_response = if (response_text.len > 0)
                    try allocator.dupe(u8, response_text)
                else
                    null;

                if (config.verbose) {
                    std.log.info("[loop] LLM 认为任务完成，准备退出 (stop_reason: {s})", .{@tagName(llm_response.stop_reason)});
                    std.log.info("[loop] 任务在第 {d} 轮完成", .{turn_num});
                }

                // 释放动态选择的工具
                if (tools_need_free and effective_tools != null) {
                    allocator.free(effective_tools.?);
                }

                break;
            }

            // do_no_tool 逻辑：检测空响应、大代码块未调用工具等
            if (config.verbose) {
                std.log.info("[loop] 调用 doNoTool 处理...", .{});
            }
            const no_tool_outcome = handler.doNoTool(response_text, turn_num, no_tool_count);

            switch (no_tool_outcome.action) {
                .continue_with_prompt => {
                    // 注入提示让 LLM 继续工作
                    const prompt = no_tool_outcome.prompt orelse "请继续完成任务。如果需要使用工具，请直接调用。";
                    if (config.verbose) {
                        std.log.info("[loop] 注入提示让 LLM 继续: {d} 字符", .{prompt.len});
                    }
                    try messages.append(.{
                        .role = .user,
                        .content = try allocator.dupe(u8, prompt),
                    });
                    // 释放动态选择的工具
                    if (tools_need_free and effective_tools != null) {
                        allocator.free(effective_tools.?);
                    }
                    continue;
                },
                .exit => {
                    if (config.verbose) {
                        std.log.info("[loop] doNoTool 返回 exit 指令，准备退出", .{});
                    }
                    final_response = if (response_text.len > 0)
                        try allocator.dupe(u8, response_text)
                    else
                        null;
                    // 释放动态选择的工具
                    if (tools_need_free and effective_tools != null) {
                        allocator.free(effective_tools.?);
                    }
                    break;
                },
            }
        } else {
            // 有工具调用，重置 no_tool 计数
            no_tool_count = 0;
            if (config.verbose) {
                std.log.info("[loop] 开始处理 {d} 个工具调用...", .{tool_calls.len});
            }

            // -------------------------------------------------------
            // c-d. 对每个 tool_call 调用 handler.dispatch()，收集结果
            // -------------------------------------------------------
            var tool_results = std.ArrayList(ToolResult).init(allocator);
            defer {
                for (tool_results.items) |*tr| {
                    tr.deinit(allocator);
                }
                tool_results.deinit();
            }

            var should_exit = false;
            var exit_reason: ?ExitReason = null;

            for (tool_calls, 0..) |*tc, i| {
                if (config.verbose) {
                    std.log.info("[loop] 处理工具调用 {d}/{d}: id={s}, name={s}", .{ i + 1, tool_calls.len, tc.id, tc.name });
                }

                // 通知回调：工具调用开始
                if (callbacks) |cb| {
                    var args_str: []const u8 = "{}";
                    var args_str_owned = false;
                    if (std.json.stringifyAlloc(allocator, tc.arguments, .{}) catch null) |s| {
                        args_str = s;
                        args_str_owned = true;
                    }
                    if (args_str_owned) {
                        defer allocator.free(args_str);
                    }
                    cb.on_event(cb.ctx, .{
                        .tool_call_start = .{
                            .id = tc.id,
                            .name = tc.name,
                            .arguments = args_str,
                        },
                    });
                }

                // 调用 handler 分发工具
                if (config.verbose) {
                    std.log.info("[loop] 调用工具 {s}...", .{tc.name});
                }
                var outcome = handler.dispatch(
                    tc.name,
                    tc.arguments,
                    llm_response.content orelse "",
                );

                if (config.verbose) {
                    std.log.info("[loop] 工具 {s} 返回: is_error={}, result_len={d}", .{ tc.name, outcome.is_error, outcome.result.len });
                }

                // 通知回调：工具调用结束
                if (callbacks) |cb| {
                    cb.on_event(cb.ctx, .{
                        .tool_call_end = .{
                            .id = tc.id,
                            .name = tc.name,
                            .result = outcome.result,
                            .is_error = outcome.is_error,
                        },
                    });
                }

                // 收集工具结果
                try tool_results.append(.{
                    .tool_use_id = try allocator.dupe(u8, tc.id),
                    .content = try allocator.dupe(u8, outcome.result),
                    .is_error = outcome.is_error,
                });

                // 检查退出信号
                if (outcome.should_exit) {
                    should_exit = true;
                    exit_reason = .exited;
                    if (config.verbose) {
                        std.log.info("[loop] 工具 {s} 返回退出信号", .{tc.name});
                    }
                    if (outcome.exit_data) |d| {
                        // Clone via JSON round-trip
                        var data_str: []const u8 = "{}";
                        var data_str_owned = false;
                        if (std.json.stringifyAlloc(allocator, d, .{}) catch null) |s| {
                            data_str = s;
                            data_str_owned = true;
                        }
                        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data_str, .{}) catch {
                            if (data_str_owned) allocator.free(data_str);
                            break;
                        };
                        exit_data = parsed.value;
                        if (data_str_owned) allocator.free(data_str);
                    }
                }

                // 检查 next_prompt
                if (outcome.next_prompt) |prompt| {
                    if (prompt.len > 0) {
                        // 保存 next_prompt，将在后面作为用户消息
                        handler.setNextPrompt(prompt);
                        if (config.verbose) {
                            std.log.info("[loop] 设置 next_prompt: {d} 字符", .{prompt.len});
                        }
                    }
                }

                // 清理 outcome 资源
                outcome.deinit(allocator);
            }

            // -------------------------------------------------------
            // e. 检查退出
            // -------------------------------------------------------
            if (should_exit) {
                if (config.verbose) {
                    std.log.info("[loop] 收到退出信号，准备结束循环", .{});
                }
                final_response = if (llm_response.content) |c|
                    try allocator.dupe(u8, c)
                else
                    null;
                // 释放动态选择的工具
                if (tools_need_free and effective_tools != null) {
                    allocator.free(effective_tools.?);
                }
                break;
            }

            // -------------------------------------------------------
            // g. 构建新的 user message（包含 tool_results）
            // -------------------------------------------------------
            if (config.verbose) {
                std.log.info("[loop] 构建包含工具结果的 user 消息...", .{});
            }

            // 将 tool_results 作为 user 消息的 content_blocks 发送
            var result_blocks = std.ArrayList(llm_types.ContentBlock).init(allocator);
            defer {
                for (result_blocks.items) |*b| b.deinit(allocator);
                result_blocks.deinit();
            }

            for (tool_results.items, 0..) |*tr, i| {
                if (config.verbose) {
                    std.log.info("[loop] 添加工具结果 {d}/{d}: tool_use_id={s}, is_error={}", .{ i + 1, tool_results.items.len, tr.tool_use_id, tr.is_error });
                }

                // 应用工具结果截断优化
                const content_to_use = if (tr.content.len > config.max_tool_result_length) blk: {
                    const truncated = try truncateToolResult(allocator, tr.content, config.max_tool_result_length);
                    std.log.info("[token-opt] 工具结果已截断: {d} -> {d} 字符", .{ tr.content.len, truncated.len });
                    break :blk truncated;
                } else try allocator.dupe(u8, tr.content);

                try result_blocks.append(.{
                    .tag = .tool_result,
                    .tool_use_id = try allocator.dupe(u8, tr.tool_use_id),
                    .content = content_to_use,
                    .is_error = tr.is_error,
                });
            }

            // 如果 handler 有 next_prompt，附加到 tool_results 之后
            const next_prompt = handler.getNextPrompt();
            if (next_prompt.len > 0) {
                if (config.verbose) {
                    std.log.info("[loop] 添加 next_prompt 到 user 消息", .{});
                }
                try result_blocks.append(.{
                    .tag = .text,
                    .text = try allocator.dupe(u8, next_prompt),
                });
            }

            const result_blocks_owned = try allocator.alloc(llm_types.ContentBlock, result_blocks.items.len);
            @memcpy(result_blocks_owned, result_blocks.items);
            result_blocks.items.len = 0;

            try messages.append(.{
                .role = .user,
                .content_blocks = result_blocks_owned,
            });

            if (config.verbose) {
                std.log.info("[loop] user 消息已添加到历史 (content_blocks: {d} 个)", .{result_blocks_owned.len});
            }
        }

        // -----------------------------------------------------------
        // f. 调用 handler.turnEndCallback()
        // -----------------------------------------------------------
        if (config.verbose) {
            std.log.info("[loop] 调用 turnEndCallback...", .{});
        }
        const turn_summary = handler.turnEndCallback(turn_num, config.max_turns);

        // 通知回调：轮次结束
        if (callbacks) |cb| {
            cb.on_event(cb.ctx, .{
                .turn_end = .{
                    .turn = turn_num,
                    .summary = if (turn_summary.len > 0) turn_summary else null,
                },
            });
        }

        // 释放动态选择的工具
        if (tools_need_free and effective_tools != null) {
            allocator.free(effective_tools.?);
        }

        if (config.verbose) {
            std.log.info("[loop] 第 {d} 轮完成，继续下一轮...", .{turn_num});
        }
    }

    // ---------------------------------------------------------------
    // 3. 确定退出原因
    // ---------------------------------------------------------------
    const reason: ExitReason = if (exit_data != null)
        .exited
    else if (turn >= config.max_turns)
        .max_turns_exceeded
    else
        .current_task_done;

    if (config.verbose) {
        std.log.info("[loop] ===== 循环结束 =====", .{});
        std.log.info("[loop] 退出原因: {s}", .{reason.toString()});
        std.log.info("[loop] 总轮次数: {d}", .{turn + 1});
        std.log.info("[loop] 总 Token: 输入 {d}, 输出 {d}", .{ total_input_tokens, total_output_tokens });
        if (final_response) |resp| {
            std.log.info("[loop] 最终响应: {d} 字符", .{resp.len});
        }

        // Token 优化汇总统计
        if (config.enable_dynamic_tools or config.enable_sliding_window) {
            std.log.info("[token-opt] ========================================", .{});
            std.log.info("[token-opt]  Token 优化汇总统计", .{});
            std.log.info("[token-opt] ========================================", .{});

            if (config.enable_dynamic_tools) {
                std.log.info("[token-opt] [动态工具选择] 已启用", .{});
                std.log.info("[token-opt]   累计估计节省工具定义 Token: ~{d}", .{total_estimated_tool_tokens_saved});
            }

            if (config.enable_sliding_window) {
                std.log.info("[token-opt] [消息滑动窗口] 已启用", .{});
                std.log.info("[token-opt]   最大历史消息数: {d}", .{config.max_history_messages});
            }

            if (config.max_tool_result_length < 99999) {
                std.log.info("[token-opt] [工具结果截断] 已启用", .{});
                std.log.info("[token-opt]   最大工具结果长度: {d}", .{config.max_tool_result_length});
            }

            // 总节省估算
            const total_tokens: u64 = total_input_tokens + total_output_tokens;
            const estimated_saved_percentage: f64 = if (total_estimated_tool_tokens_saved > 0 and total_tokens > 0)
                (@as(f64, @floatFromInt(total_estimated_tool_tokens_saved)) / @as(f64, @floatFromInt(total_tokens + @as(u64, @intCast(total_estimated_tool_tokens_saved))))) * 100.0
            else
                0.0;

            std.log.info("[token-opt] ========================================", .{});
            std.log.info("[token-opt]  总估计节省 Token: ~{d} (~{d:.1}%)", .{ total_estimated_tool_tokens_saved, estimated_saved_percentage });
            std.log.info("[token-opt] ========================================", .{});
        }
    }

    // 通知回调：循环结束
    if (callbacks) |cb| {
        cb.on_event(cb.ctx, .{
            .loop_end = .{
                .reason = reason,
                .total_turns = turn + 1,
            },
        });
    }

    return LoopResult{
        .reason = reason,
        .response = final_response,
        .data = exit_data,
        .total_turns = turn + 1,
        .total_input_tokens = total_input_tokens,
        .total_output_tokens = total_output_tokens,
    };
}

// ============================================================================
// Token 优化辅助函数
// ============================================================================

/// 截断过长的工具结果，减少 Token 消耗（返回新分配的内存）
fn truncateToolResult(allocator: Allocator, content: []const u8, max_length: u32) ![]const u8 {
    if (content.len <= max_length) {
        return try allocator.dupe(u8, content);
    }

    const half = max_length / 2;
    const ellipsis = "\n\n... [内容已截断，省略中间部分] ...\n\n";

    var result = std.ArrayList(u8).init(allocator);
    try result.appendSlice(content[0..half]);
    try result.appendSlice(ellipsis);
    try result.appendSlice(content[content.len - half ..]);

    return result.toOwnedSlice();
}

/// 应用消息滑动窗口 - 保留最新的 N 条消息
fn applySlidingWindow(messages: *std.ArrayList(Message), config: AgentConfig, allocator: Allocator) !void {
    if (!config.enable_sliding_window) {
        return;
    }

    const max_messages = config.max_history_messages;
    if (messages.items.len <= max_messages) {
        return;
    }

    const remove_count = messages.items.len - max_messages;

    if (config.verbose) {
        std.log.info("[token-opt] 应用消息滑动窗口: 删除 {d} 条历史消息，保留最近 {d} 条", .{ remove_count, max_messages });
    }

    // 释放需要删除的消息资源
    var i: usize = 0;
    while (i < remove_count) : (i += 1) {
        messages.items[i].deinit(allocator);
    }

    // 移动剩余消息到前面
    for (remove_count.., 0..messages.items.len) |src_idx, dest_idx| {
        messages.items[dest_idx] = messages.items[src_idx];
    }

    // 调整数组大小
    try messages.resize(max_messages);
}

/// 计算并记录消息历史的字符/Token 估计
fn logMessageStats(messages: []const Message, verbose: bool) void {
    if (!verbose) {
        return;
    }

    var total_chars: usize = 0;
    for (messages) |msg| {
        if (msg.content) |content| {
            total_chars += content.len;
        }
        if (msg.content_blocks) |blocks| {
            for (blocks) |block| {
                if (block.text) |text| {
                    total_chars += text.len;
                }
                if (block.thinking) |thinking| {
                    total_chars += thinking.len;
                }
                if (block.content) |content| {
                    total_chars += content.len;
                }
            }
        }
    }

    // 简单估计：中文字符约 1 Token，英文字符约 4 Token
    const estimated_tokens = total_chars / 3;
    std.log.info("[token-opt] 消息历史统计: {d} 条消息, 约 {d} 字符, 估计 {d} Token", .{ messages.len, total_chars, estimated_tokens });
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "AgentConfig defaults" {
    const config = AgentConfig{};
    try testing.expectEqual(@as(u32, 40), config.max_turns);
    try testing.expectEqual(true, config.verbose);
    try testing.expectEqual(@as(u32, 10), config.tool_reset_interval);
}

test "ExitReason toString" {
    try testing.expectEqualStrings("EXITED", ExitReason.exited.toString());
    try testing.expectEqualStrings("CURRENT_TASK_DONE", ExitReason.current_task_done.toString());
    try testing.expectEqualStrings("MAX_TURNS_EXCEEDED", ExitReason.max_turns_exceeded.toString());
    try testing.expectEqualStrings("ERROR", ExitReason.err.toString());
}
