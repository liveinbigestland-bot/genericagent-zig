//! src/llm/session.zig - 会话管理
//!
//! 定义 SessionConfig、BaseSession 接口、ClaudeSession（Anthropic API）、
//! OaiSession（OpenAI 兼容 API）以及 resolveSession 工厂函数。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const types = @import("types.zig");
const client_mod = @import("client.zig");

const Message = types.Message;
const ContentBlock = types.ContentBlock;
const ContentBlockTag = types.ContentBlockTag;
const ToolCall = types.ToolCall;
const ToolResult = types.ToolResult;
const ToolDefinition = types.ToolDefinition;
const MockResponse = types.MockResponse;
const Usage = types.Usage;
const StopReason = types.StopReason;
const Role = types.Role;
const ApiMode = types.ApiMode;
const HistoryStats = types.HistoryStats;

const LlmClient = client_mod.LlmClient;
const ClientConfig = client_mod.ClientConfig;
const RequestHeaders = client_mod.RequestHeaders;
const SseEvent = client_mod.SseEvent;
const LlmError = client_mod.LlmError;

// ---------------------------------------------------------------------------
// SessionConfig
// ---------------------------------------------------------------------------

/// 会话配置
pub const SessionConfig = struct {
    /// API 密钥
    api_key: []const u8 = "",
    /// API 基础 URL
    api_base: []const u8 = "",
    /// 模型名称
    model: []const u8 = "",
    /// 上下文窗口大小（token 数）
    context_window: u32 = 200000,
    /// 温度参数
    temperature: f32 = 0.0,
    /// 最大输出 token 数
    max_tokens: u32 = 4096,
    /// 是否使用流式响应
    stream: bool = true,
    /// 最大重试次数
    max_retries: u32 = 3,
    /// 连接超时（毫秒）
    connect_timeout_ms: u32 = 30000,
    /// 读取超时（毫秒）
    read_timeout_ms: u32 = 120000,
    /// 代理地址
    proxy: ?[]const u8 = null,
    /// API 模式（仅 OpenAI 兼容）
    api_mode: ApiMode = .chat_completions,
    /// 会话类型标识：claude / oai
    session_type: []const u8 = "claude",
    /// Anthropic 特有：是否启用 thinking
    thinking: bool = false,
    /// Anthropic 特有：thinking budget tokens
    thinking_budget_tokens: u32 = 10000,
    /// 系统提示词
    system_prompt: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// SessionVTable - 接口模式
// ---------------------------------------------------------------------------

/// Session 虚函数表（接口）
pub const SessionVTable = struct {
    /// 获取会话类型名称
    name: *const fn () []const u8,
    /// 发送消息并获取响应
    complete: *const fn (*anyopaque, []const Message, ?[]const ToolDefinition) anyerror!MockResponse,
    /// 流式发送消息
    completeStream: *const fn (*anyopaque, []const Message, ?[]const ToolDefinition, *anyopaque, *const fn (*anyopaque, SseEvent) anyerror!void) anyerror!void,
    /// 获取消息历史
    getHistory: *const fn (*anyopaque) []const Message,
    /// 添加消息到历史
    addMessage: *const fn (*anyopaque, Message) void,
    /// 清空历史
    clearHistory: *const fn (*anyopaque) void,
    /// 压缩历史
    trimHistory: *const fn (*anyopaque, u32) void,
    /// 销毁
    deinit: *const fn (*anyopaque) void,
};

/// BaseSession - 通用会话包装器
pub const BaseSession = struct {
    ptr: *anyopaque,
    vtable: *const SessionVTable,

    pub fn name(self: BaseSession) []const u8 {
        return self.vtable.name();
    }

    pub fn complete(self: BaseSession, messages: []const Message, tools: ?[]const ToolDefinition) anyerror!MockResponse {
        return self.vtable.complete(self.ptr, messages, tools);
    }

    pub fn completeStream(
        self: BaseSession,
        messages: []const Message,
        tools: ?[]const ToolDefinition,
        ctx: *anyopaque,
        onEvent: *const fn (*anyopaque, SseEvent) anyerror!void,
    ) anyerror!void {
        return self.vtable.completeStream(self.ptr, messages, tools, ctx, onEvent);
    }

    pub fn getHistory(self: BaseSession) []const Message {
        return self.vtable.getHistory(self.ptr);
    }

    pub fn addMessage(self: BaseSession, msg: Message) void {
        self.vtable.addMessage(self.ptr, msg);
    }

    pub fn clearHistory(self: BaseSession) void {
        self.vtable.clearHistory(self.ptr);
    }

    pub fn trimHistory(self: BaseSession, max_messages: u32) void {
        self.vtable.trimHistory(self.ptr, max_messages);
    }

    pub fn deinit(self: BaseSession) void {
        self.vtable.deinit(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// ClaudeSession - Anthropic API
// ---------------------------------------------------------------------------

/// Anthropic Claude 会话
pub const ClaudeSession = struct {
    allocator: Allocator,
    config: SessionConfig,
    client: LlmClient,
    history: std.ArrayList(Message),
    system_prompt: ?[]const u8 = null,

    pub fn init(allocator: Allocator, config: SessionConfig) !ClaudeSession {
        const client_config = ClientConfig{
            .max_retries = config.max_retries,
            .connect_timeout_ms = config.connect_timeout_ms,
            .read_timeout_ms = config.read_timeout_ms,
            .proxy = config.proxy,
        };
        return .{
            .allocator = allocator,
            .config = config,
            .client = LlmClient.init(allocator, client_config),
            .history = std.ArrayList(Message).init(allocator),
            .system_prompt = config.system_prompt,
        };
    }

    pub fn deinit(self: *ClaudeSession) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.deinit();
        self.client.deinit();
    }

    /// 构建请求 URL
    fn buildUrl(self: *ClaudeSession) ![]const u8 {
        var base = self.config.api_base;
        // 移除末尾的 /
        while (base.len > 0 and base[base.len - 1] == '/') {
            base = base[0 .. base.len - 1];
        }
        return std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{base});
    }

    /// 构建请求头
    fn buildHeaders(self: *ClaudeSession) !RequestHeaders {
        const auth = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.config.api_key},
        );
        return .{
            .authorization = auth,
            .content_type = "application/json",
            .accept = if (self.config.stream) "text/event-stream" else "application/json",
            .extra = &[_]RequestHeaders.HeaderEntry{
                .{ .name = "anthropic-version", .value = "2023-06-01" },
            },
        };
    }

    /// 构建请求体 JSON
    fn buildRequestBody(
        self: *ClaudeSession,
        messages: []const Message,
        tools: ?[]const ToolDefinition,
        stream: bool,
    ) ![]const u8 {
        var array = std.ArrayList(u8).init(self.allocator);
        defer array.deinit();

        try array.appendSlice("{\"model\":\"");
        try array.appendSlice(self.config.model);
        try array.appendSlice("\",\"max_tokens\":");
        try array.writer().print("{}", .{self.config.max_tokens});
        try array.appendSlice(",\"stream\":");
        try array.appendSlice(if (stream) "true" else "false");
        try array.appendSlice(",\"temperature\":");
        try array.writer().print("{d}", .{self.config.temperature});

        // 添加工具定义（Anthropic Claude 格式）
        if (tools) |tool_list| {
            try array.appendSlice(",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try array.appendSlice(",");
                try array.appendSlice("{\"name\":\"");
                try array.appendSlice(tool.name);
                try array.appendSlice("\",\"description\":\"");
                for (tool.description) |ch| {
                    if (ch == '"') {
                        try array.appendSlice("\\\"");
                    } else if (ch == '\\') {
                        try array.appendSlice("\\\\");
                    } else {
                        try array.append(ch);
                    }
                }
                try array.appendSlice("\",\"input_schema\":");
                try array.appendSlice(tool.parameters);
                try array.appendSlice("}");
            }
            try array.appendSlice("]");
        }

        var system_content: ?[]const u8 = null;
        var user_messages = std.ArrayList(Message).init(self.allocator);
        defer user_messages.deinit();

        for (messages) |msg| {
            if (msg.role == .system) {
                system_content = msg.content;
            } else {
                user_messages.append(msg) catch {};
            }
        }

        if (system_content) |sc| {
            try array.appendSlice(",\"system\":\"");
            for (sc) |ch| {
                if (ch == '"') {
                    try array.appendSlice("\\\"");
                } else if (ch == '\\') {
                    try array.appendSlice("\\\\");
                } else if (ch == '\n') {
                    try array.appendSlice("\\n");
                } else if (ch == '\r') {
                    try array.appendSlice("\\r");
                } else if (ch == '\t') {
                    try array.appendSlice("\\t");
                } else {
                    try array.append(ch);
                }
            }
            try array.appendSlice("\"");
        }

        try array.appendSlice(",\"messages\":[");
        for (user_messages.items, 0..) |msg, i| {
            if (i > 0) try array.appendSlice(",");
            try array.appendSlice("{\"role\":\"");
            try array.appendSlice(msg.role.toString());
            try array.appendSlice("\",\"content\":[");

            if (msg.content) |c| {
                try array.appendSlice("{\"type\":\"text\",\"thinking\":\"\",\"text\":\"");
                for (c) |ch| {
                    if (ch == '"') {
                        try array.appendSlice("\\\"");
                    } else if (ch == '\\') {
                        try array.appendSlice("\\\\");
                    } else if (ch == '\n') {
                        try array.appendSlice("\\n");
                    } else if (ch == '\r') {
                        try array.appendSlice("\\r");
                    } else if (ch == '\t') {
                        try array.appendSlice("\\t");
                    } else {
                        try array.append(ch);
                    }
                }
                try array.appendSlice("\"}");
            } else if (msg.content_blocks) |blocks| {
                for (blocks, 0..) |block, j| {
                    if (j > 0) try array.appendSlice(",");
                    switch (block.tag) {
                        .text => {
                            try array.appendSlice("{\"type\":\"text\",\"thinking\":\"\",\"text\":\"");
                            if (block.text) |text| {
                                for (text) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else if (ch == '\n') {
                                        try array.appendSlice("\\n");
                                    } else if (ch == '\r') {
                                        try array.appendSlice("\\r");
                                    } else if (ch == '\t') {
                                        try array.appendSlice("\\t");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\"}");
                        },
                        .thinking => {
                            try array.appendSlice("{\"type\":\"thinking\",\"thinking\":\"\",\"text\":\"");
                            if (block.text) |text| {
                                for (text) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else if (ch == '\n') {
                                        try array.appendSlice("\\n");
                                    } else if (ch == '\r') {
                                        try array.appendSlice("\\r");
                                    } else if (ch == '\t') {
                                        try array.appendSlice("\\t");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\"}");
                        },
                        .tool_use => {
                            try array.appendSlice("{\"type\":\"tool_use\",\"thinking\":\"\",\"id\":\"");
                            if (block.id) |id| {
                                for (id) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\",\"name\":\"");
                            if (block.name) |name| {
                                for (name) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\",\"input\":");
                            if (block.input) |input| {
                                const args_json = std.json.stringifyAlloc(self.allocator, input, .{}) catch "{}";
                                defer self.allocator.free(args_json);
                                try array.appendSlice(args_json);
                            } else {
                                try array.appendSlice("{}");
                            }
                            try array.appendSlice("}");
                        },
                        .image => {
                            try array.appendSlice("{\"type\":\"image\",\"thinking\":\"\",\"source\":{\"type\":\"base64\",\"media_type\":\"");
                            if (block.media_type) |media_type| {
                                for (media_type) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\",\"data\":\"");
                            if (block.data) |data| {
                                for (data) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\"}}");
                        },
                        .tool_result => {
                            try array.appendSlice("{\"type\":\"tool_result\",\"thinking\":\"\",\"tool_use_id\":\"");
                            if (block.tool_use_id) |tool_use_id| {
                                for (tool_use_id) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\",\"content\":\"");
                            if (block.content) |content| {
                                for (content) |ch| {
                                    if (ch == '"') {
                                        try array.appendSlice("\\\"");
                                    } else if (ch == '\\') {
                                        try array.appendSlice("\\\\");
                                    } else if (ch == '\n') {
                                        try array.appendSlice("\\n");
                                    } else if (ch == '\r') {
                                        try array.appendSlice("\\r");
                                    } else if (ch == '\t') {
                                        try array.appendSlice("\\t");
                                    } else {
                                        try array.append(ch);
                                    }
                                }
                            }
                            try array.appendSlice("\"}");
                        },
                    }
                }
            }
            try array.appendSlice("]}");
        }
        try array.appendSlice("]}");

        return array.toOwnedSlice();
    }

    /// 发送请求（非流式）
    pub fn complete(self: *ClaudeSession, messages: []const Message, tools: ?[]const ToolDefinition) !MockResponse {
        const url = try self.buildUrl();
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();
        defer if (headers.authorization) |auth| self.allocator.free(auth);
        const body = try self.buildRequestBody(messages, tools, false);
        defer self.allocator.free(body);

        const result = self.client.post(url, headers, body) catch |err| {
            std.log.err("Claude request failed: {}", .{err});
            return err;
        };
        defer self.allocator.free(result.body);

        if (result.body.len == 0) {
            std.log.err("Empty response body", .{});
            return LlmError.InvalidResponse;
        }

        return self.parseResponse(result.body);
    }

    /// 发送请求（流式）
    pub fn completeStream(
        self: *ClaudeSession,
        messages: []const Message,
        tools: ?[]const ToolDefinition,
        ctx: *anyopaque,
        onEvent: *const fn (*anyopaque, SseEvent) anyerror!void,
    ) !void {
        const url = try self.buildUrl();
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();
        defer if (headers.authorization) |auth| self.allocator.free(auth);
        const body = try self.buildRequestBody(messages, tools, true);
        defer self.allocator.free(body);

        return self.client.postStream(url, headers, body, ctx, onEvent);
    }

    /// 解析 Claude API 响应
    fn parseResponse(self: *ClaudeSession, body: []const u8) !MockResponse {
        var parsed = json.parseFromSlice(json.Value, self.allocator, body, .{}) catch
            return LlmError.JsonParseError;
        defer parsed.deinit();

        const root = parsed.value;
        var response = MockResponse{};

        // 解析 stop_reason
        if (root.object.get("stop_reason")) |sr| {
            if (sr == .string) {
                response.stop_reason = StopReason.fromString(sr.string);
            }
        }

        // 解析 content 数组
        if (root.object.get("content")) |content_arr| {
            if (content_arr == .array) {
                var thinking_buf = std.ArrayList(u8).init(self.allocator);
                defer thinking_buf.deinit();
                var content_buf = std.ArrayList(u8).init(self.allocator);
                defer content_buf.deinit();
                var tool_calls_list = std.ArrayList(ToolCall).init(self.allocator);

                for (content_arr.array.items) |item| {
                    if (item == .object) {
                        const block_type = item.object.get("type") orelse continue;
                        if (block_type != .string) continue;

                        if (std.mem.eql(u8, block_type.string, "thinking")) {
                            // 首先从 thinking 字段读取（原始 Claude API）
                            if (item.object.get("thinking")) |thinking_val| {
                                if (thinking_val == .string and thinking_val.string.len > 0) {
                                    if (thinking_buf.items.len > 0) {
                                        thinking_buf.append('\n') catch {};
                                    }
                                    thinking_buf.appendSlice(thinking_val.string) catch {};
                                }
                            }
                            // 如果 thinking 字段为空，尝试从 text 字段读取（DeepSeek Claude API 可能使用这种格式）
                            if (thinking_buf.items.len == 0) {
                                if (item.object.get("text")) |thinking_val| {
                                    if (thinking_val == .string) {
                                        thinking_buf.appendSlice(thinking_val.string) catch {};
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, block_type.string, "text")) {
                            if (item.object.get("text")) |text_val| {
                                if (text_val == .string) {
                                    if (content_buf.items.len > 0) {
                                        content_buf.append('\n') catch {};
                                    }
                                    content_buf.appendSlice(text_val.string) catch {};
                                }
                            }
                        } else if (std.mem.eql(u8, block_type.string, "tool_use")) {
                            const id_val = item.object.get("id");
                            const name_val = item.object.get("name");
                            const input_val = item.object.get("input");

                            const id_str = if (id_val != null and id_val.? == .string)
                                try self.allocator.dupe(u8, id_val.?.string)
                            else
                                try self.allocator.dupe(u8, "");
                            errdefer self.allocator.free(id_str);

                            const name_str = if (name_val != null and name_val.? == .string)
                                try self.allocator.dupe(u8, name_val.?.string)
                            else
                                try self.allocator.dupe(u8, "");
                            errdefer self.allocator.free(name_str);

                            const input_copy = if (input_val != null) blk: {
                                const serialized = std.json.stringifyAlloc(self.allocator, input_val.?, .{}) catch
                                    break :blk json.Value.null;
                                defer self.allocator.free(serialized);
                                const cloned = std.json.parseFromSlice(json.Value, self.allocator, serialized, .{}) catch
                                    break :blk json.Value.null;
                                defer cloned.deinit();
                                break :blk cloned.value;
                            } else json.Value.null;
                            // Note: json.dynamic.Value does not have deinit; memory managed by arena allocator

                            try tool_calls_list.append(.{
                                .id = id_str,
                                .name = name_str,
                                .arguments = input_copy,
                            });
                        }
                    }
                }

                if (thinking_buf.items.len > 0) {
                    response.thinking = thinking_buf.toOwnedSlice() catch null;
                }
                if (content_buf.items.len > 0) {
                    response.content = content_buf.toOwnedSlice() catch null;
                }
                if (tool_calls_list.items.len > 0) {
                    response.tool_calls = tool_calls_list.toOwnedSlice() catch null;
                }
            }
        }

        return response;
    }

    // -- 历史管理 --

    pub fn getHistory(self: *ClaudeSession) []const Message {
        return self.history.items;
    }

    pub fn addMessage(self: *ClaudeSession, msg: Message) void {
        self.history.append(msg) catch {};
    }

    pub fn clearHistory(self: *ClaudeSession) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.clearRetainingCapacity();
    }

    /// 压缩消息历史，保留最近的 max_messages 条
    pub fn trimHistory(self: *ClaudeSession, max_messages: u32) void {
        if (self.history.items.len <= max_messages) return;

        const start = self.history.items.len - @as(usize, max_messages);
        // 释放被裁剪的消息
        for (self.history.items[0..start]) |*msg| {
            msg.deinit(self.allocator);
        }
        // 将保留的消息移到前面
        const remaining = self.history.items[start..];
        std.mem.copyForwards(Message, self.history.items, remaining);
        self.history.items.len = remaining.len;
    }

    /// 转换为 BaseSession
    pub fn toBaseSession(self: *ClaudeSession) BaseSession {
        return .{
            .ptr = self,
            .vtable = &claude_vtable,
        };
    }
};

// Claude vtable 实现
const claude_vtable = SessionVTable{
    .name = claudeSessionName,
    .complete = claudeSessionComplete,
    .completeStream = claudeSessionCompleteStream,
    .getHistory = claudeSessionGetHistory,
    .addMessage = claudeSessionAddMessage,
    .clearHistory = claudeSessionClearHistory,
    .trimHistory = claudeSessionTrimHistory,
    .deinit = claudeSessionDeinit,
};

fn claudeSessionName() []const u8 {
    return "claude";
}

fn claudeSessionComplete(ptr: *anyopaque, messages: []const Message, tools: ?[]const ToolDefinition) anyerror!MockResponse {
    const self: *ClaudeSession = @ptrCast(@alignCast(ptr));
    return self.complete(messages, tools);
}

fn claudeSessionCompleteStream(
    ptr: *anyopaque,
    messages: []const Message,
    tools: ?[]const ToolDefinition,
    ctx: *anyopaque,
    onEvent: *const fn (*anyopaque, SseEvent) anyerror!void,
) anyerror!void {
    const self: *ClaudeSession = @ptrCast(@alignCast(ptr));
    return self.completeStream(messages, tools, ctx, onEvent);
}

fn claudeSessionGetHistory(ptr: *anyopaque) []const Message {
    const self: *ClaudeSession = @ptrCast(@alignCast(ptr));
    return self.getHistory();
}

fn claudeSessionAddMessage(ptr: *anyopaque, msg: Message) void {
    const self: *ClaudeSession = @ptrCast(@alignCast(ptr));
    self.addMessage(msg);
}

fn claudeSessionClearHistory(ptr: *anyopaque) void {
    const self: *ClaudeSession = @ptrCast(@alignCast(ptr));
    self.clearHistory();
}

fn claudeSessionTrimHistory(ptr: *anyopaque, max_messages: u32) void {
    const self: *ClaudeSession = @ptrCast(@alignCast(ptr));
    self.trimHistory(max_messages);
}

fn claudeSessionDeinit(ptr: *anyopaque) void {
    const self: *ClaudeSession = @ptrCast(@alignCast(ptr));
    self.deinit();
    self.allocator.destroy(self);
}

// ---------------------------------------------------------------------------
// OaiSession - OpenAI 兼容 API
// ---------------------------------------------------------------------------

/// OpenAI 兼容会话（支持 chat/completions 和 responses 两种模式）
pub const OaiSession = struct {
    allocator: Allocator,
    config: SessionConfig,
    client: LlmClient,
    history: std.ArrayList(Message),
    system_prompt: ?[]const u8 = null,

    pub fn init(allocator: Allocator, config: SessionConfig) !OaiSession {
        const client_config = ClientConfig{
            .max_retries = config.max_retries,
            .connect_timeout_ms = config.connect_timeout_ms,
            .read_timeout_ms = config.read_timeout_ms,
            .proxy = config.proxy,
        };
        return .{
            .allocator = allocator,
            .config = config,
            .client = LlmClient.init(allocator, client_config),
            .history = std.ArrayList(Message).init(allocator),
            .system_prompt = config.system_prompt,
        };
    }

    pub fn deinit(self: *OaiSession) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.deinit();
        self.client.deinit();
    }

    /// 构建请求 URL
    fn buildUrl(self: *OaiSession) ![]const u8 {
        var base = self.config.api_base;
        while (base.len > 0 and base[base.len - 1] == '/') {
            base = base[0 .. base.len - 1];
        }
        return switch (self.config.api_mode) {
            .chat_completions => std.fmt.allocPrint(
                self.allocator,
                "{s}/v1/chat/completions",
                .{base},
            ),
            .responses => std.fmt.allocPrint(
                self.allocator,
                "{s}/v1/responses",
                .{base},
            ),
        };
    }

    /// 构建请求头
    fn buildHeaders(self: *OaiSession) !RequestHeaders {
        const auth = try std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.config.api_key},
        );
        return .{
            .authorization = auth,
            .content_type = "application/json",
            .accept = if (self.config.stream) "text/event-stream" else "application/json",
        };
    }

    /// 构建 chat/completions 请求体
    fn buildChatCompletionsBody(
        self: *OaiSession,
        messages: []const Message,
        tools: ?[]const ToolDefinition,
    ) ![]const u8 {
        _ = tools;
        _ = messages;
        return std.json.stringifyAlloc(self.allocator, .{
            .model = self.config.model,
            .max_tokens = self.config.max_tokens,
            .stream = self.config.stream,
            .temperature = self.config.temperature,
        }, .{}) catch return LlmError.AllocationFailed;
    }

    /// 构建 responses API 请求体
    fn buildResponsesBody(
        self: *OaiSession,
        messages: []const Message,
        tools: ?[]const ToolDefinition,
    ) ![]const u8 {
        _ = tools;
        _ = messages;
        return std.json.stringifyAlloc(self.allocator, .{
            .model = self.config.model,
            .max_output_tokens = self.config.max_tokens,
            .stream = self.config.stream,
            .temperature = self.config.temperature,
        }, .{}) catch return LlmError.AllocationFailed;
    }

    /// 发送请求（非流式）
    pub fn complete(self: *OaiSession, messages: []const Message, tools: ?[]const ToolDefinition) !MockResponse {
        const url = try self.buildUrl();
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();
        defer if (headers.authorization) |auth| self.allocator.free(auth);

        const body = switch (self.config.api_mode) {
            .chat_completions => try self.buildChatCompletionsBody(messages, tools),
            .responses => try self.buildResponsesBody(messages, tools),
        };
        defer self.allocator.free(body);

        const result = self.client.post(url, headers, body) catch |err| {
            std.log.err("OAI request failed: {}", .{err});
            return err;
        };
        defer self.allocator.free(result.body);

        return self.parseResponse(result.body);
    }

    /// 发送请求（流式）
    pub fn completeStream(
        self: *OaiSession,
        messages: []const Message,
        tools: ?[]const ToolDefinition,
        ctx: *anyopaque,
        onEvent: *const fn (*anyopaque, SseEvent) anyerror!void,
    ) !void {
        const url = try self.buildUrl();
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();
        defer if (headers.authorization) |auth| self.allocator.free(auth);

        const body = switch (self.config.api_mode) {
            .chat_completions => try self.buildChatCompletionsBody(messages, tools),
            .responses => try self.buildResponsesBody(messages, tools),
        };
        defer self.allocator.free(body);

        return self.client.postStream(url, headers, body, ctx, onEvent);
    }

    /// 解析 OpenAI 兼容 API 响应
    fn parseResponse(self: *OaiSession, body: []const u8) !MockResponse {
        var parsed = json.parseFromSlice(json.Value, self.allocator, body, .{}) catch
            return LlmError.JsonParseError;
        defer parsed.deinit();

        const root = parsed.value;
        var response = MockResponse{};

        // 解析 choices
        if (root.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const choice = choices.array.items[0];
                if (choice == .object) {
                    // finish_reason
                    if (choice.object.get("finish_reason")) |fr| {
                        if (fr == .string) {
                            response.stop_reason = StopReason.fromString(fr.string);
                        }
                    }

                    // message
                    if (choice.object.get("message")) |msg| {
                        if (msg == .object) {
                            // reasoning_content (DeepSeek 等)
                            if (msg.object.get("reasoning_content")) |rc| {
                                if (rc == .string and rc.string.len > 0) {
                                    response.thinking = try self.allocator.dupe(u8, rc.string);
                                }
                            }

                            // content
                            if (msg.object.get("content")) |content_val| {
                                if (content_val == .string and content_val.string.len > 0) {
                                    response.content = try self.allocator.dupe(u8, content_val.string);
                                }
                            }

                            // tool_calls
                            if (msg.object.get("tool_calls")) |tc| {
                                if (tc == .array and tc.array.items.len > 0) {
                                    var tool_calls_list = std.ArrayList(ToolCall).init(self.allocator);
                                    for (tc.array.items) |tc_item| {
                                        if (tc_item == .object) {
                                            const tc_id = tc_item.object.get("id");
                                            const tc_fn = tc_item.object.get("function");
                                            if (tc_fn != null and tc_fn.? == .object) {
                                                const fn_name = tc_fn.?.object.get("name");
                                                const fn_args = tc_fn.?.object.get("arguments");

                                                const id_str = if (tc_id != null and tc_id.? == .string)
                                                    try self.allocator.dupe(u8, tc_id.?.string)
                                                else
                                                    try self.allocator.dupe(u8, "");
                                                errdefer self.allocator.free(id_str);

                                                const name_str = if (fn_name != null and fn_name.? == .string)
                                                    try self.allocator.dupe(u8, fn_name.?.string)
                                                else
                                                    try self.allocator.dupe(u8, "");
                                                errdefer self.allocator.free(name_str);

                                                var args_val: json.Value = .null;
                                                if (fn_args != null) {
                                                    if (fn_args.? == .string) {
                                                        const args_parsed = json.parseFromSlice(
                                                            json.Value,
                                                            self.allocator,
                                                            fn_args.?.string,
                                                            .{},
                                                        ) catch continue;
                                                        args_val = args_parsed.value;
                                                    } else {
                                                        const serialized = std.json.stringifyAlloc(self.allocator, fn_args.?, .{}) catch continue;
                                                        const args_parsed2 = std.json.parseFromSlice(json.Value, self.allocator, serialized, .{}) catch continue;
                                                        args_val = args_parsed2.value;
                                                    }
                                                }
                                                // Note: json.dynamic.Value does not have deinit; memory managed by arena allocator

                                                try tool_calls_list.append(.{
                                                    .id = id_str,
                                                    .name = name_str,
                                                    .arguments = args_val,
                                                });
                                            }
                                        }
                                    }
                                    if (tool_calls_list.items.len > 0) {
                                        response.tool_calls = tool_calls_list.toOwnedSlice() catch null;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return response;
    }

    // -- 历史管理 --

    pub fn getHistory(self: *OaiSession) []const Message {
        return self.history.items;
    }

    pub fn addMessage(self: *OaiSession, msg: Message) void {
        self.history.append(msg) catch {};
    }

    pub fn clearHistory(self: *OaiSession) void {
        for (self.history.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.history.clearRetainingCapacity();
    }

    pub fn trimHistory(self: *OaiSession, max_messages: u32) void {
        if (self.history.items.len <= max_messages) return;

        const start = self.history.items.len - @as(usize, max_messages);
        for (self.history.items[0..start]) |*msg| {
            msg.deinit(self.allocator);
        }
        const remaining = self.history.items[start..];
        std.mem.copyForwards(Message, self.history.items, remaining);
        self.history.items.len = remaining.len;
    }

    pub fn toBaseSession(self: *OaiSession) BaseSession {
        return .{
            .ptr = self,
            .vtable = &oai_vtable,
        };
    }
};

// OAI vtable 实现
const oai_vtable = SessionVTable{
    .name = oaiSessionName,
    .complete = oaiSessionComplete,
    .completeStream = oaiSessionCompleteStream,
    .getHistory = oaiSessionGetHistory,
    .addMessage = oaiSessionAddMessage,
    .clearHistory = oaiSessionClearHistory,
    .trimHistory = oaiSessionTrimHistory,
    .deinit = oaiSessionDeinit,
};

fn oaiSessionName() []const u8 {
    return "oai";
}

fn oaiSessionComplete(ptr: *anyopaque, messages: []const Message, tools: ?[]const ToolDefinition) anyerror!MockResponse {
    const self: *OaiSession = @ptrCast(@alignCast(ptr));
    return self.complete(messages, tools);
}

fn oaiSessionCompleteStream(
    ptr: *anyopaque,
    messages: []const Message,
    tools: ?[]const ToolDefinition,
    ctx: *anyopaque,
    onEvent: *const fn (*anyopaque, SseEvent) anyerror!void,
) anyerror!void {
    const self: *OaiSession = @ptrCast(@alignCast(ptr));
    return self.completeStream(messages, tools, ctx, onEvent);
}

fn oaiSessionGetHistory(ptr: *anyopaque) []const Message {
    const self: *OaiSession = @ptrCast(@alignCast(ptr));
    return self.getHistory();
}

fn oaiSessionAddMessage(ptr: *anyopaque, msg: Message) void {
    const self: *OaiSession = @ptrCast(@alignCast(ptr));
    self.addMessage(msg);
}

fn oaiSessionClearHistory(ptr: *anyopaque) void {
    const self: *OaiSession = @ptrCast(@alignCast(ptr));
    self.clearHistory();
}

fn oaiSessionTrimHistory(ptr: *anyopaque, max_messages: u32) void {
    const self: *OaiSession = @ptrCast(@alignCast(ptr));
    self.trimHistory(max_messages);
}

fn oaiSessionDeinit(ptr: *anyopaque) void {
    const self: *OaiSession = @ptrCast(@alignCast(ptr));
    self.deinit();
    self.allocator.destroy(self);
}

// ---------------------------------------------------------------------------
// resolveSession - 工厂函数
// ---------------------------------------------------------------------------

/// 根据配置创建对应的 Session 实例
pub fn resolveSession(allocator: Allocator, config: SessionConfig) !BaseSession {
    if (std.mem.eql(u8, config.session_type, "claude")) {
        const session = try allocator.create(ClaudeSession);
        session.* = try ClaudeSession.init(allocator, config);
        return session.toBaseSession();
    } else if (std.mem.eql(u8, config.session_type, "oai")) {
        const session = try allocator.create(OaiSession);
        session.* = try OaiSession.init(allocator, config);
        return session.toBaseSession();
    } else {
        // 默认使用 Claude
        const session = try allocator.create(ClaudeSession);
        session.* = try ClaudeSession.init(allocator, config);
        return session.toBaseSession();
    }
}

// ---------------------------------------------------------------------------
// 消息历史管理工具函数
// ---------------------------------------------------------------------------

/// 压缩消息历史：保留 system 消息 + 最近的消息
pub fn trimMessagesHistory(
    allocator: Allocator,
    messages: []const Message,
    max_messages: u32,
) ![]const Message {
    if (messages.len <= max_messages) {
        return messages;
    }

    // 计算需要保留的 system 消息数量
    var system_count: usize = 0;
    for (messages) |msg| {
        if (msg.role == .system) system_count += 1;
    }

    const available = @as(usize, max_messages) -| system_count;
    const start = messages.len - available;

    var result = std.ArrayList(Message).init(allocator);
    errdefer result.deinit();

    // 保留 system 消息
    for (messages[0..system_count]) |msg| {
        try result.append(msg);
    }
    // 保留最近的消息
    for (messages[start..]) |msg| {
        try result.append(msg);
    }

    return result.toOwnedSlice();
}

/// 计算消息历史的统计信息
pub fn computeHistoryStats(messages: []const Message) HistoryStats {
    var stats = HistoryStats{};
    for (messages) |msg| {
        stats.message_count += 1;
        if (msg.content) |c| {
            stats.total_chars += c.len;
        }
        if (msg.content_blocks) |blocks| {
            for (blocks) |block| {
                if (block.text) |t| {
                    stats.total_chars += t.len;
                }
            }
        }
    }
    // 粗略估算：4 字符 ≈ 1 token
    stats.estimated_tokens = stats.total_chars / 4;
    return stats;
}

/// 确保消息历史中角色交替（user/assistant）
pub fn ensureAlternatingRoles(messages: []const Message, allocator: Allocator) ![]const Message {
    if (messages.len <= 1) return messages;

    var result = std.ArrayList(Message).init(allocator);
    errdefer {
        for (result.items) |*m| m.deinit(allocator);
        result.deinit();
    }

    var last_role: ?Role = null;
    for (messages) |msg| {
        if (last_role) |lr| {
            if (lr == msg.role) {
                // 连续相同角色，跳过
                continue;
            }
        }
        try result.append(msg);
        last_role = msg.role;
    }

    return result.toOwnedSlice();
}
