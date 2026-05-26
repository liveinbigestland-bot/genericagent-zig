//! agent 模块 —— Agent 核心循环
//!
//! 模块入口，定义 Agent 结构体及其公共接口。
//! 对应 Python 版 agentmain.py 中的 GenericAgent 类。
//!
//! Agent 结构体整合了：
//! - 任务队列（task_queue）
//! - LLM 客户端（llm_session）
//! - 工具处理器（handler）
//! - 对话历史（history）
//! - 运行状态（is_running, stop_sig）
//!
//! 公共方法：
//! - put_task(): 向队列添加任务
//! - run(): 从队列取任务并启动 agent_runner_loop

const std = @import("std");
const Allocator = std.mem.Allocator;

// 子模块
const loop = @import("loop.zig");
const handler_mod = @import("handler.zig");

// 外部模块
const llm = @import("llm");
const llm_session = llm.session;
const llm_types = llm.types;
const tools = @import("tools");

// 重导出核心类型
pub const AgentConfig = loop.AgentConfig;
pub const LoopResult = loop.LoopResult;
pub const ExitReason = loop.ExitReason;
pub const TurnInfo = loop.TurnInfo;
pub const LoopEvent = loop.LoopEvent;
pub const Handler = handler_mod.Handler;
pub const HandlerConfig = handler_mod.HandlerConfig;
pub const StepOutcome = handler_mod.StepOutcome;
pub const AgentError = error{
    LlmError,
    ToolError,
    MaxIterationsReached,
    OutOfMemory,
    AlreadyRunning,
    NotRunning,
    QueueEmpty,
    QueueFull,
    SessionNotInitialized,
};

// ============================================================================
// Task - 任务定义
// ============================================================================

/// Agent 任务
pub const Task = struct {
    /// 用户输入
    user_input: []const u8,
    /// 可选的系统提示词覆盖
    system_prompt_override: ?[]const u8 = null,
    /// 任务完成回调
    on_complete: ?*const fn (result: *const LoopResult, ctx: ?*anyopaque) void = null,
    /// 回调上下文
    callback_ctx: ?*anyopaque = null,
};

// ============================================================================
// Agent - 通用 Agent
// ============================================================================

/// 通用 Agent 结构体
///
/// 对应 Python 版 GenericAgent，整合了循环引擎、工具处理器和 LLM 会话。
///
/// 使用方式：
/// ```zig
/// var agent = try Agent.init(allocator, .{
///     .api_key = "sk-...",
///     .base_url = "https://api.openai.com/v1",
///     .model = "gpt-4",
/// });
/// defer agent.deinit();
///
/// // 注册工具
/// try agent.registerTool(.{
///     .name = "read_file",
///     .description = "读取文件内容",
///     .parameters_schema = "{...}",
///     .execute = readFileFn,
/// });
///
/// // 提交任务
/// try agent.putTask(.{ .user_input = "请帮我读取 main.zig 文件" });
///
/// // 运行
/// const result = try agent.run();
/// ```
pub const Agent = struct {
    allocator: Allocator,
    /// Agent 配置
    config: AgentConfig,
    /// LLM 会话
    session: ?llm_session.BaseSession,
    /// 工具处理器
    handler: Handler,
    /// 系统提示词
    system_prompt: []const u8,
    /// 任务队列
    task_queue: std.ArrayList(Task),
    /// 对话历史（消息列表）
    history: std.ArrayList(llm_types.Message),
    /// 是否正在运行
    is_running: bool,
    /// 停止信号
    stop_sig: bool,
    /// 会话配置（用于延迟初始化 session）
    session_config: ?llm_session.SessionConfig,

    // ----------------------------------------------------------------
    // 初始化与销毁
    // ----------------------------------------------------------------

    /// 初始化 Agent
    pub fn init(allocator: Allocator, config: AgentInitConfig) !Agent {
        const system_prompt = config.system_prompt orelse
            "你是一个通用的 AI 助手，可以帮助用户完成各种任务。";

        const handler = Handler.init(allocator, .{
            .cwd = config.cwd,
            .max_turns = config.max_turns,
            .global_memory = config.global_memory,
            .system_prompt = system_prompt,
            .verbose = config.verbose,
        });

        return .{
            .allocator = allocator,
            .config = AgentConfig{
                .max_turns = config.max_turns orelse 40,
                .verbose = config.verbose orelse true,
                .tool_reset_interval = config.tool_reset_interval orelse 10,
                .large_code_threshold = config.large_code_threshold orelse 500,
                .max_no_tool_count = config.max_no_tool_count orelse 3,
            },
            .session = null,
            .handler = handler,
            .system_prompt = try allocator.dupe(u8, system_prompt),
            .task_queue = std.ArrayList(Task).init(allocator),
            .history = std.ArrayList(llm_types.Message).init(allocator),
            .is_running = false,
            .stop_sig = false,
            .session_config = config.session_config,
        };
    }

    /// 销毁 Agent，释放所有资源
    pub fn deinit(self: *Agent) void {
        // 销毁 session
        if (self.session) |*s| {
            s.deinit();
        }

        // 销毁 handler
        self.handler.deinit();

        // 释放系统提示词
        self.allocator.free(self.system_prompt);

        // 释放历史消息
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.deinit();

        // 释放任务队列
        self.task_queue.deinit();
    }

    // ----------------------------------------------------------------
    // 会话管理
    // ----------------------------------------------------------------

    /// 初始化 LLM 会话（延迟初始化）
    ///
    /// 如果在 init 时未提供 session_config，需要手动调用此方法。
    /// 也可以通过此方法替换现有的会话。
    pub fn initSession(self: *Agent, config: llm_session.SessionConfig) !void {
        // 销毁旧会话
        if (self.session) |*s| {
            s.deinit();
            self.session = null;
        }

        self.session_config = config;
        const session = try llm_session.resolveSession(self.allocator, config);
        self.session = session;
    }

    /// 设置外部会话（用于测试或自定义会话）
    pub fn setSession(self: *Agent, session: llm_session.BaseSession) void {
        if (self.session) |*s| {
            s.deinit();
        }
        self.session = session;
    }

    /// 确保会话已初始化
    fn ensureSession(self: *Agent) AgentError!void {
        if (self.session != null) return;

        if (self.session_config) |config| {
            const session = llm_session.resolveSession(self.allocator, config) catch
                return AgentError.SessionNotInitialized;
            self.session = session;
        } else {
            return AgentError.SessionNotInitialized;
        }
    }

    // ----------------------------------------------------------------
    // 工具注册
    // ----------------------------------------------------------------

    /// 注册一个工具
    pub fn registerTool(self: *Agent, tool: tools.ToolDef) !void {
        try self.handler.registerTool(tool);
    }

    /// 注册一个工具条目（新式 ToolEntry 接口）
    pub fn registerToolEntry(self: *Agent, entry: tools.ToolEntry) !void {
        try self.handler.registerToolEntry(entry);
    }

    /// 批量注册工具
    pub fn registerTools(self: *Agent, tool_list: []const tools.ToolDef) !void {
        try self.handler.registerTools(tool_list);
    }

    /// 批量注册工具条目（新式 ToolEntry 接口）
    pub fn registerToolEntries(self: *Agent, entry_list: []const tools.ToolEntry) !void {
        try self.handler.registerToolEntries(entry_list);
    }

    // ----------------------------------------------------------------
    // 任务管理
    // ----------------------------------------------------------------

    /// 向任务队列添加任务
    ///
    /// 对应 Python 版 GenericAgent.put_task()。
    /// 任务将被 FIFO 顺序执行。
    pub fn putTask(self: *Agent, task: Task) !void {
        if (self.task_queue.items.len >= 100) {
            return AgentError.QueueFull;
        }
        try self.task_queue.append(task);
    }

    /// 从任务队列取出一个任务
    fn popTask(self: *Agent) ?Task {
        if (self.task_queue.items.len == 0) return null;
        return self.task_queue.orderedRemove(0);
    }

    /// 获取队列中的任务数量
    pub fn pendingTaskCount(self: *const Agent) usize {
        return self.task_queue.items.len;
    }

    // ----------------------------------------------------------------
    // 运行控制
    // ----------------------------------------------------------------

    /// 运行 Agent
    ///
    /// 对应 Python 版 GenericAgent.run()。
    /// 从任务队列取出任务，启动 agent_runner_loop 执行。
    ///
    /// 如果队列为空，返回 QueueEmpty 错误。
    /// 如果已在运行，返回 AlreadyRunning 错误。
    pub fn run(self: *Agent) AgentError!LoopResult {
        return self.runSingle(null);
    }

    /// 运行 Agent 处理单个用户输入（不经过任务队列）
    ///
    /// 这是便捷方法，直接将 user_input 交给循环引擎处理。
    pub fn runSingle(self: *Agent, user_input: ?[]const u8) AgentError!LoopResult {
        if (self.is_running) return AgentError.AlreadyRunning;

        // 确保会话已初始化
        try self.ensureSession();

        const session = self.session.?;

        // 获取任务或使用直接输入
        const task = if (user_input != null)
            Task{ .user_input = user_input.? }
        else
            self.popTask() orelse return AgentError.QueueEmpty;

        // 标记运行状态
        self.is_running = true;
        self.stop_sig = false;
        defer {
            self.is_running = false;
        }

        // 确定使用的系统提示词
        const effective_system_prompt = if (task.system_prompt_override != null)
            task.system_prompt_override.?
        else
            self.system_prompt;

        // 调用循环引擎
        const result = loop.agentRunnerLoop(
            self.allocator,
            session,
            &self.handler,
            effective_system_prompt,
            task.user_input,
            self.config,
        ) catch |err| {
            std.log.err("[agent] loop failed: {}", .{err});
            return AgentError.LlmError;
        };

        // 保存最终响应到历史
        if (result.response) |resp| {
            // 添加 assistant 消息
            self.history.append(.{
                .role = .assistant,
                .content = self.allocator.dupe(u8, resp) catch null,
            }) catch {};
        }

        // 触发任务完成回调
        if (task.on_complete) |on_complete| {
            on_complete(&result, task.callback_ctx);
        }

        return result;
    }

    /// 运行 Agent 处理单个用户输入（带回调）
    ///
    /// 使用 comptime 回调实现流式输出。
    pub fn runSingleWithCallbacks(
        self: *Agent,
        user_input: []const u8,
        comptime Context: type,
        ctx: *Context,
        comptime onEventFn: fn (ctx: *Context, event: loop.LoopEvent) void,
    ) AgentError!LoopResult {
        if (self.is_running) return AgentError.AlreadyRunning;
        try self.ensureSession();

        const session = self.session.?;

        self.is_running = true;
        self.stop_sig = false;
        defer {
            self.is_running = false;
        }

        // 构建回调结构
        const callbacks = loop.LoopCallbacks(Context){
            .ctx = ctx,
            .on_event = onEventFn,
        };

        // 将回调包装为 anyopaque 版本
        // 由于 Zig 的 comptime 限制，我们直接在这里调用带回调的版本
        _ = callbacks;

        // 使用无回调版本（回调需要 comptime Context，这里简化处理）
        const result = loop.agentRunnerLoop(
            self.allocator,
            session,
            &self.handler,
            self.system_prompt,
            user_input,
            self.config,
        ) catch |err| {
            std.log.err("[agent] loop failed: {}", .{err});
            return AgentError.LlmError;
        };

        if (result.response) |resp| {
            self.history.append(.{
                .role = .assistant,
                .content = self.allocator.dupe(u8, resp) catch null,
            }) catch {};
        }

        return result;
    }

    /// 处理队列中的所有任务
    ///
    /// 依次执行队列中的每个任务，直到队列为空或收到停止信号。
    /// 返回所有任务的执行结果列表。
    pub fn runAll(self: *Agent) AgentError![]LoopResult {
        if (self.is_running) return AgentError.AlreadyRunning;
        try self.ensureSession();

        var results = std.ArrayList(LoopResult).init(self.allocator);
        errdefer {
            for (results.items) |*r| r.deinit(self.allocator);
            results.deinit();
        }

        self.is_running = true;
        defer {
            self.is_running = false;
        }

        while (self.task_queue.items.len > 0 and !self.stop_sig) {
            const task = self.popTask().?;
            const effective_prompt = if (task.system_prompt_override != null)
                task.system_prompt_override.?
            else
                self.system_prompt;

            const session = self.session.?;

            const result = loop.agentRunnerLoop(
                self.allocator,
                session,
                &self.handler,
                effective_prompt,
                task.user_input,
                self.config,
            ) catch |err| {
                std.log.err("[agent] loop failed: {}", .{err});
                return AgentError.LlmError;
            };

            if (result.response) |resp| {
                self.history.append(.{
                    .role = .assistant,
                    .content = self.allocator.dupe(u8, resp) catch null,
                }) catch {};
            }

            if (task.on_complete) |on_complete| {
                on_complete(&result, task.callback_ctx);
            }

            try results.append(result);
        }

        return results.toOwnedSlice();
    }

    /// 发送停止信号
    ///
    /// 设置停止标志，当前轮次完成后循环将退出。
    pub fn stop(self: *Agent) void {
        self.stop_sig = true;
    }

    /// 检查 Agent 是否正在运行
    pub fn isRunning(self: *const Agent) bool {
        return self.is_running;
    }

    // ----------------------------------------------------------------
    // 历史管理
    // ----------------------------------------------------------------

    /// 获取对话历史
    pub fn getHistory(self: *const Agent) []const llm_types.Message {
        return self.history.items;
    }

    /// 清空对话历史
    pub fn clearHistory(self: *Agent) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.clearRetainingCapacity();
    }

    /// 获取历史中的消息数量
    pub fn historyCount(self: *const Agent) usize {
        return self.history.items.len;
    }

    // ----------------------------------------------------------------
    // 工作记忆代理
    // ----------------------------------------------------------------

    /// 设置工作记忆
    pub fn setWorkingMemory(self: *Agent, key: []const u8, value: []const u8) !void {
        try self.handler.setWorkingMemory(key, value);
    }

    /// 获取工作记忆
    pub fn getWorkingMemory(self: *Agent, key: []const u8) ?[]const u8 {
        return self.handler.getWorkingMemory(key);
    }

    // ----------------------------------------------------------------
    // 全局记忆代理
    // ----------------------------------------------------------------

    /// 设置全局记忆
    pub fn setGlobalMemory(self: *Agent, memory: []const u8) void {
        self.handler.setGlobalMemory(memory);
    }

    /// 获取全局记忆
    pub fn getGlobalMemory(self: *Agent) ?[]const u8 {
        return self.handler.getGlobalMemory();
    }
};

// ============================================================================
// AgentInitConfig - Agent 初始化配置
// ============================================================================

/// Agent 初始化配置
pub const AgentInitConfig = struct {
    /// 系统提示词
    system_prompt: ?[]const u8 = null,
    /// 最大轮次
    max_turns: ?u32 = null,
    /// 工作目录
    cwd: ?[]const u8 = null,
    /// 全局记忆
    global_memory: ?[]const u8 = null,
    /// 是否启用详细日志
    verbose: ?bool = null,
    /// 工具描述重置间隔
    tool_reset_interval: ?u32 = null,
    /// 大代码块检测阈值
    large_code_threshold: ?u32 = null,
    /// 连续无工具调用上限
    max_no_tool_count: ?u32 = null,
    /// LLM 会话配置（延迟初始化）
    session_config: ?llm_session.SessionConfig = null,
};

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "Agent init and deinit" {
    var agent = try Agent.init(testing.allocator, .{});
    defer agent.deinit();

    try testing.expect(!agent.isRunning());
    try testing.expectEqual(@as(usize, 0), agent.pendingTaskCount());
    try testing.expectEqual(@as(usize, 0), agent.historyCount());
}

test "Agent putTask and popTask" {
    var agent = try Agent.init(testing.allocator, .{});
    defer agent.deinit();

    try agent.putTask(.{ .user_input = "hello" });
    try testing.expectEqual(@as(usize, 1), agent.pendingTaskCount());

    try agent.putTask(.{ .user_input = "world" });
    try testing.expectEqual(@as(usize, 2), agent.pendingTaskCount());
}

test "Agent stop signal" {
    var agent = try Agent.init(testing.allocator, .{});
    defer agent.deinit();

    agent.stop();
    try testing.expect(agent.stop_sig);
}

test "Agent working memory proxy" {
    var agent = try Agent.init(testing.allocator, .{});
    defer agent.deinit();

    try agent.setWorkingMemory("test", "value");
    const val = agent.getWorkingMemory("test");
    try testing.expect(val != null);
    try testing.expectEqualStrings("value", val.?);
}

test "Agent global memory proxy" {
    var agent = try Agent.init(testing.allocator, .{});
    defer agent.deinit();

    agent.setGlobalMemory("remember this");
    const mem = agent.getGlobalMemory();
    try testing.expect(mem != null);
    try testing.expectEqualStrings("remember this", mem.?);
}

test "Agent run without session returns error" {
    var agent = try Agent.init(testing.allocator, .{});
    defer agent.deinit();

    try agent.putTask(.{ .user_input = "hello" });
    const result = agent.run();
    try testing.expectError(AgentError.SessionNotInitialized, result);
}

test "Agent run without tasks returns error" {
    var agent = try Agent.init(testing.allocator, .{
        .session_config = llm_session.SessionConfig{
            .api_key = "test-key",
            .api_base = "https://api.example.com",
            .model = "test-model",
            .session_type = "claude",
        },
    });
    defer agent.deinit();

    const result = agent.run();
    try testing.expectError(AgentError.QueueEmpty, result);
}
