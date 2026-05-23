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
    session: BaseSession,
    handler: *Handler,
    system_prompt: []const u8,
    user_input: []const u8,
    config: AgentConfig,
) !LoopResult {
    // 无回调版本：使用 noop 回调
    return agentRunnerLoopWithCallbacks(allocator, session, handler, system_prompt, user_input, config, null);
}

/// 带回调的 Agent 执行循环引擎
pub fn agentRunnerLoopWithCallbacks(
    allocator: Allocator,
    session: BaseSession,
    handler: *Handler,
    system_prompt: []const u8,
    user_input: []const u8,
    config: AgentConfig,
    comptime callbacks: ?LoopCallbacks(anyopaque),
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

    // 添加 system prompt
    try messages.append(.{
        .role = .system,
        .content = try allocator.dupe(u8, system_prompt),
    });

    // 添加用户输入
    try messages.append(.{
        .role = .user,
        .content = try allocator.dupe(u8, user_input),
    });

    // ---------------------------------------------------------------
    // 2. 循环
    // ---------------------------------------------------------------
    var turn: u32 = 0;
    const total_input_tokens: u64 = 0;
    const total_output_tokens: u64 = 0;
    var last_tools_reset_turn: u32 = 0;
    var no_tool_count: u32 = 0;
    var final_response: ?[]const u8 = null;
    var exit_data: ?std.json.Value = null;

    // 获取工具定义
    const tool_defs = handler.getToolDefinitions(allocator);

    while (turn < config.max_turns) : (turn += 1) {
        const turn_num = turn + 1;

        // 通知回调：轮次开始
        if (callbacks) |cb| {
            cb.on_event(cb.ctx, .{ .turn_start = .{ .turn = turn_num } });
        }

        if (config.verbose) {
            std.log.info("[loop] turn {d}/{d} starting", .{ turn_num, config.max_turns });
        }

        // 每 tool_reset_interval 轮重置工具描述
        // 对应 Python 版 client.last_tools = ''
        var effective_tools: ?[]const ToolDefinition = tool_defs;
        if (turn_num - last_tools_reset_turn >= config.tool_reset_interval) {
            last_tools_reset_turn = turn_num;
            if (config.verbose) {
                std.log.info("[loop] resetting tool descriptions at turn {d}", .{turn_num});
            }
            // 回调可覆盖工具列表
            if (callbacks) |cb| {
                if (cb.get_tools_override) |get_tools| {
                    effective_tools = get_tools(cb.ctx, turn_num);
                }
            }
        }

        // -----------------------------------------------------------
        // a. 调用 LLM 获取响应
        // -----------------------------------------------------------
        const llm_response = session.complete(messages.items, effective_tools) catch |err| {
            std.log.err("[loop] LLM call failed at turn {d}: {}", .{ turn_num, err });

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

        // 通知回调：thinking 内容
        if (llm_response.thinking) |thinking_text| {
            if (thinking_text.len > 0) {
                if (callbacks) |cb| {
                    cb.on_event(cb.ctx, .{ .thinking = .{ .text = thinking_text } });
                }
            }
        }

        // 通知回调：文本内容
        if (llm_response.content) |content_text| {
            if (content_text.len > 0) {
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

        if (llm_response.thinking) |t| {
            if (t.len > 0) {
                try content_blocks.append(.{
                    .tag = .thinking,
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

        for (tool_calls) |*tc| {
            // Clone arguments via JSON round-trip (std.json.dynamic.Value has no deepClone)
            const args_str = std.json.stringifyAlloc(allocator, tc.arguments, .{}) catch "{}";
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                args_str,
                .{},
            ) catch break;
            defer parsed.deinit();
            allocator.free(args_str);

            try content_blocks.append(.{
                .tag = .tool_use,
                .id = try allocator.dupe(u8, tc.id),
                .name = try allocator.dupe(u8, tc.name),
                .input = parsed.value,
            });
        }

        const blocks_owned = try allocator.alloc(llm_types.ContentBlock, content_blocks.items.len);
        @memcpy(blocks_owned, content_blocks.items);

        try messages.append(.{
            .role = .assistant,
            .content_blocks = blocks_owned,
        });

        // -----------------------------------------------------------
        // c. 处理 tool_calls 或 no_tool 情况
        // -----------------------------------------------------------
        if (tool_calls.len == 0) {
            // 无工具调用 → 触发 no_tool 处理
            no_tool_count += 1;

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
                    std.log.info("[loop] task done at turn {d}", .{turn_num});
                }

                break;
            }

            // do_no_tool 逻辑：检测空响应、大代码块未调用工具等
            const no_tool_outcome = handler.doNoTool(response_text, turn_num, no_tool_count);

            switch (no_tool_outcome.action) {
                .continue_with_prompt => {
                    // 注入提示让 LLM 继续工作
                    const prompt = no_tool_outcome.prompt orelse "请继续完成任务。如果需要使用工具，请直接调用。";
                    try messages.append(.{
                        .role = .user,
                        .content = try allocator.dupe(u8, prompt),
                    });
                    continue;
                },
                .exit => {
                    final_response = if (response_text.len > 0)
                        try allocator.dupe(u8, response_text)
                    else
                        null;
                    break;
                },
            }
        } else {
            // 有工具调用，重置 no_tool 计数
            no_tool_count = 0;

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

            for (tool_calls) |*tc| {
                // 通知回调：工具调用开始
                if (callbacks) |cb| {
                    const args_str = std.json.stringifyAlloc(allocator, tc.arguments, .{}) catch "{}";
                    defer allocator.free(args_str);
                    cb.on_event(cb.ctx, .{
                        .tool_call_start = .{
                            .id = tc.id,
                            .name = tc.name,
                            .arguments = args_str,
                        },
                    });
                }

                // 调用 handler 分发工具
                const outcome = handler.dispatch(
                    tc.name,
                    tc.arguments,
                    llm_response.content orelse "",
                );

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
                    if (outcome.exit_data) |d| {
                        // Clone via JSON round-trip
                        const data_str = std.json.stringifyAlloc(allocator, d, .{}) catch "";
                        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data_str, .{}) catch break;
                        exit_data = parsed.value;
                        allocator.free(data_str);
                    }
                }

                // 检查 next_prompt
                if (outcome.next_prompt) |prompt| {
                    if (prompt.len > 0) {
                        // 保存 next_prompt，将在后面作为用户消息
                        handler.setNextPrompt(prompt);
                    }
                }
            }

            // -------------------------------------------------------
            // e. 检查退出
            // -------------------------------------------------------
            if (should_exit) {
                final_response = if (llm_response.content) |c|
                    try allocator.dupe(u8, c)
                else
                    null;
                break;
            }

            // -------------------------------------------------------
            // g. 构建新的 user message（包含 tool_results）
            // -------------------------------------------------------
            // 将 tool_results 作为 user 消息的 content_blocks 发送
            var result_blocks = std.ArrayList(llm_types.ContentBlock).init(allocator);
            defer {
                for (result_blocks.items) |*b| b.deinit(allocator);
                result_blocks.deinit();
            }

            for (tool_results.items) |*tr| {
                try result_blocks.append(.{
                    .tag = .tool_result,
                    .tool_use_id = try allocator.dupe(u8, tr.tool_use_id),
                    .content = try allocator.dupe(u8, tr.content),
                    .is_error = tr.is_error,
                });
            }

            // 如果 handler 有 next_prompt，附加到 tool_results 之后
            const next_prompt = handler.getNextPrompt();
            if (next_prompt.len > 0) {
                try result_blocks.append(.{
                    .tag = .text,
                    .text = try allocator.dupe(u8, next_prompt),
                });
            }

            const result_blocks_owned = try allocator.alloc(llm_types.ContentBlock, result_blocks.items.len);
            @memcpy(result_blocks_owned, result_blocks.items);

            try messages.append(.{
                .role = .user,
                .content_blocks = result_blocks_owned,
            });
        }

        // -----------------------------------------------------------
        // f. 调用 handler.turnEndCallback()
        // -----------------------------------------------------------
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

        if (config.verbose) {
            std.log.info("[loop] turn {d} completed", .{turn_num});
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
