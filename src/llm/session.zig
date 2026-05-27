//! src/llm/session.zig - 会话管理
//!
//! 定义 SessionConfig、BaseSession 接口、ClaudeSession（Anthropic API）、
//! OaiSession（OpenAI 兼容 API）以及 resolveSession 工厂函数。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const types = @import("types.zig");
const client_mod = @import("client.zig");

/// 将字符串转义并验证 UTF-8，写入 JSON 数组
fn appendJsonString(array: *std.ArrayList(u8), input: []const u8) !void {
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];

        switch (c) {
            '"' => {
                try array.appendSlice("\\\"");
                i += 1;
            },
            '\\' => {
                try array.appendSlice("\\\\");
                i += 1;
            },
            '\n' => {
                try array.appendSlice("\\n");
                i += 1;
            },
            '\r' => {
                try array.appendSlice("\\r");
                i += 1;
            },
            '\t' => {
                try array.appendSlice("\\t");
                i += 1;
            },
            '\x08' => {
                try array.appendSlice("\\b");
                i += 1;
            },
            '\x0C' => {
                try array.appendSlice("\\f");
                i += 1;
            },
            else => {
                if (c < 0x80) {
                    try array.append(c);
                    i += 1;
                } else {
                    const len: usize = if (c < 0xE0) 2 else if (c < 0xF0) 3 else if (c < 0xF8) 4 else {
                        i += 1;
                        continue;
                    };

                    if (i + len > input.len) {
                        i += 1;
                        continue;
                    }

                    var valid = true;
                    var j: usize = 1;
                    while (j < len) : (j += 1) {
                        if ((input[i + j] & 0xC0) != 0x80) {
                            valid = false;
                            break;
                        }
                    }

                    if (valid) {
                        try array.appendSlice(input[i .. i + len]);
                    }
                    i += len;
                }
            },
        }
    }
}

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
// 交互日志工具函数
// ---------------------------------------------------------------------------

/// 日志条目结构体
const LogEntry = struct {
    timestamp: []const u8,
    turn: u32,
    request: []const u8,
    response: []const u8,
    status_code: u32,
};

/// 获取当前时间戳字符串（用于日志文件名）
fn getTimestamp(allocator: Allocator) ![]const u8 {
    const now = @divFloor(std.time.nanoTimestamp(), 1_000_000_000);
    return std.fmt.allocPrint(allocator, "{}", .{now});
}

/// 保存交互日志到文件
fn saveInteractionLog(allocator: Allocator, log_dir: []const u8, turn: u32, request: []const u8, response: []const u8, status_code: u32) void {
    // 创建日志目录
    std.fs.cwd().makePath(log_dir) catch |err| {
        std.log.err("failed to create log directory '{s}': {}", .{ log_dir, err });
        return;
    };

    // 生成文件名（包含轮次信息）
    const timestamp = getTimestamp(allocator) catch |err| {
        std.log.err("failed to get timestamp: {}", .{err});
        return;
    };
    defer allocator.free(timestamp);

    const file_name = std.fmt.allocPrint(allocator, "{s}/turn_{:03}_{s}.json", .{ log_dir, turn, timestamp }) catch |err| {
        std.log.err("failed to create log file name: {}", .{err});
        return;
    };
    defer allocator.free(file_name);

    // 构建日志内容
    var log_content = std.ArrayList(u8).init(allocator);
    defer log_content.deinit();

    log_content.appendSlice("{\"timestamp\":\"") catch return;
    log_content.appendSlice(timestamp) catch return;
    log_content.appendSlice("\",\"turn\":") catch return;
    const turn_str = std.fmt.allocPrint(allocator, "{}", .{turn}) catch return;
    defer allocator.free(turn_str);
    log_content.appendSlice(turn_str) catch return;
    log_content.appendSlice(",\"status_code\":") catch return;
    const status_str = std.fmt.allocPrint(allocator, "{}", .{status_code}) catch return;
    defer allocator.free(status_str);
    log_content.appendSlice(status_str) catch return;
    log_content.appendSlice(",\"request\":") catch return;
    log_content.appendSlice(request) catch return;
    log_content.appendSlice(",\"response\":") catch return;
    log_content.appendSlice(response) catch return;
    log_content.appendSlice("}") catch return;

    // 写入文件
    const file = std.fs.cwd().createFile(file_name, .{ .truncate = true }) catch |err| {
        std.log.err("failed to create log file '{s}': {}", .{ file_name, err });
        return;
    };
    defer file.close();

    file.writeAll(log_content.items) catch |err| {
        std.log.err("failed to write log file '{s}': {}", .{ file_name, err });
        return;
    };

    std.log.debug("[log] turn {} interaction saved to: {s}", .{ turn, file_name });
}

// ---------------------------------------------------------------------------
// SessionConfig
// ---------------------------------------------------------------------------

/// 会话配置
pub const SessionConfig = struct {
    /// API 密钥
    api_key: []const u8 = "",
    /// API 基础 URL
    base_url: []const u8 = "",
    /// 模型名称
    model: []const u8 = "",
    /// 最大令牌数
    max_tokens: u32 = 4096,
    /// 温度
    temperature: f32 = 0.7,
    /// API 模式
    api_mode: ApiMode = .chat_completions,
    /// 超时时间（毫秒）
    timeout_ms: u32 = 60000,
    /// 是否启用交互日志（保存请求/响应数据包到文件）
    enable_logging: bool = false,
    /// 日志文件目录（默认为当前目录下的 logs 文件夹）
    log_dir: []const u8 = "logs",
};

// ---------------------------------------------------------------------------
// BaseSession Interface
// ---------------------------------------------------------------------------

/// 会话接口
pub const BaseSession = struct {
    vtable: *const VTable,
    data: *anyopaque,
    allocator: Allocator,

    pub const VTable = struct {
        complete: *const fn (*anyopaque, []const Message, ?[]const ToolDefinition, u32) anyerror!MockResponse,
        completeStream: *const fn (*anyopaque, []const Message, ?[]const ToolDefinition) anyerror!void,
        deinit: *const fn (*anyopaque, Allocator) void,
    };

    pub fn complete(self: *BaseSession, messages: []const Message, tools: ?[]const ToolDefinition, turn: u32) !MockResponse {
        return self.vtable.complete(self.data, messages, tools, turn);
    }

    pub fn completeStream(self: *BaseSession, messages: []const Message, tools: ?[]const ToolDefinition) !void {
        return self.vtable.completeStream(self.data, messages, tools);
    }

    pub fn deinit(self: *BaseSession) void {
        self.vtable.deinit(self.data, self.allocator);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// ClaudeSession
// ---------------------------------------------------------------------------

/// Claude API 会话
pub const ClaudeSession = struct {
    allocator: Allocator,
    client: LlmClient,
    config: SessionConfig,

    pub fn init(allocator: Allocator, config: SessionConfig) ClaudeSession {
        return .{
            .allocator = allocator,
            .client = LlmClient.init(allocator, .{
                .base_url = config.base_url,
                .api_key = config.api_key,
                .timeout_ms = config.timeout_ms,
            }),
            .config = config,
        };
    }

    pub fn deinit(self: *ClaudeSession) void {
        self.client.deinit();
    }

    fn buildUrl(self: *ClaudeSession) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{self.client.config.base_url});
    }

    fn buildHeaders(self: *ClaudeSession) !RequestHeaders {
        return .{
            .api_key = self.client.config.api_key,
            .content_type = "application/json",
        };
    }

    fn buildRequestBody(self: *ClaudeSession, messages: []const Message, tools: ?[]const ToolDefinition) ![]const u8 {
        var array = std.ArrayList(u8).init(self.allocator);
        errdefer array.deinit();

        try array.appendSlice("{\"model\":\"");
        try array.appendSlice(self.config.model);
        try array.appendSlice("\",\"max_tokens\":");
        var max_tokens_str: []const u8 = "4096";
        var should_free_max_tokens = false;
        if (std.fmt.allocPrint(self.allocator, "{}", .{self.config.max_tokens})) |allocated| {
            max_tokens_str = allocated;
            should_free_max_tokens = true;
        } else |_| {}
        errdefer if (should_free_max_tokens) self.allocator.free(max_tokens_str);
        try array.appendSlice(max_tokens_str);

        var temp_str: ?[]const u8 = null;
        if (self.config.temperature >= 0) {
            try array.appendSlice(",\"temperature\":");
            temp_str = try std.fmt.allocPrint(self.allocator, "{d}", .{@as(f64, @floatCast(self.config.temperature))});
            errdefer if (temp_str) |s| self.allocator.free(s);
            try array.appendSlice(temp_str.?);
        }

        if (tools) |tool_list| {
            try array.appendSlice(",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try array.appendSlice(",");
                try array.appendSlice("{\"name\":\"");
                try appendJsonString(&array, tool.name);
                try array.appendSlice("\",\"description\":\"");
                try appendJsonString(&array, tool.description);
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
            try appendJsonString(&array, sc);
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
                try appendJsonString(&array, c);
                try array.appendSlice("\"}");
            } else if (msg.content_blocks) |blocks| {
                for (blocks, 0..) |block, j| {
                    if (j > 0) try array.appendSlice(",");
                    switch (block.tag) {
                        .text => {
                            try array.appendSlice("{\"type\":\"text\",\"thinking\":\"\",\"text\":\"");
                            if (block.text) |text| {
                                try appendJsonString(&array, text);
                            }
                            try array.appendSlice("\"}");
                        },
                        .thinking => {
                            try array.appendSlice("{\"type\":\"thinking\",\"thinking\":\"\",\"text\":\"");
                            if (block.text) |text| {
                                try appendJsonString(&array, text);
                            }
                            try array.appendSlice("\"}");
                        },
                        .tool_use => {
                            try array.appendSlice("{\"type\":\"tool_use\",\"thinking\":\"\",\"id\":\"");
                            if (block.id) |id| {
                                try appendJsonString(&array, id);
                            }
                            try array.appendSlice("\",\"name\":\"");
                            if (block.name) |name| {
                                try appendJsonString(&array, name);
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
                                try appendJsonString(&array, media_type);
                            }
                            try array.appendSlice("\",\"data\":\"");
                            if (block.data) |data| {
                                try appendJsonString(&array, data);
                            }
                            try array.appendSlice("\"}}");
                        },
                        .tool_result => {
                            try array.appendSlice("{\"type\":\"tool_result\",\"thinking\":\"\",\"tool_use_id\":\"");
                            if (block.tool_use_id) |tool_use_id| {
                                try appendJsonString(&array, tool_use_id);
                            }
                            try array.appendSlice("\",\"content\":\"");
                            if (block.content) |content| {
                                try appendJsonString(&array, content);
                            }
                            try array.appendSlice("\"}");
                        },
                    }
                }
            }
            try array.appendSlice("]}");
        }
        try array.appendSlice("]}");

        if (should_free_max_tokens) {
            self.allocator.free(max_tokens_str);
        }
        if (temp_str) |s| {
            self.allocator.free(s);
        }

        return array.toOwnedSlice();
    }

    pub fn complete(self: *ClaudeSession, messages: []const Message, tools: ?[]const ToolDefinition, turn: u32) !MockResponse {
        const url = try self.buildUrl();
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();

        const body = try self.buildRequestBody(messages, tools);
        defer self.allocator.free(body);

        const response = try self.client.post(url, headers, body);
        defer self.allocator.free(response.body);

        // 记录交互日志
        if (self.config.enable_logging) {
            saveInteractionLog(self.allocator, self.config.log_dir, turn, body, response.body, response.status_code);
        }

        return try parseClaudeResponse(self.allocator, response.body);
    }

    pub fn completeStream(self: *ClaudeSession, messages: []const Message, tools: ?[]const ToolDefinition) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{self.client.config.base_url});
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();

        const body = try self.buildRequestBody(messages, tools);
        defer self.allocator.free(body);

        try self.client.postStream(url, headers, body, self, handleSseEvent);
    }

    pub fn asBase(self: *ClaudeSession) BaseSession {
        return .{
            .vtable = &claude_vtable,
            .data = self,
        };
    }

    fn parseClaudeResponse(allocator: Allocator, body: []const u8) !MockResponse {
        var parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
        defer parsed.deinit();

        var response: MockResponse = .{};

        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("content")) |content_val| {
                if (content_val == .array) {
                    var content_str = std.ArrayList(u8).init(allocator);
                    defer content_str.deinit();

                    var tool_calls = std.ArrayList(types.ToolCall).init(allocator);
                    defer {
                        for (tool_calls.items) |*tc| tc.deinit(allocator);
                        tool_calls.deinit();
                    }

                    for (content_val.array.items) |item| {
                        if (item == .object) {
                            const item_obj = item.object;
                            if (item_obj.get("type")) |type_val| {
                                if (type_val == .string) {
                                    if (std.mem.eql(u8, type_val.string, "text")) {
                                        if (item_obj.get("text")) |text_val| {
                                            if (text_val == .string) {
                                                try content_str.appendSlice(text_val.string);
                                            }
                                        }
                                    } else if (std.mem.eql(u8, type_val.string, "tool_use")) {
                                        var tc: types.ToolCall = undefined;

                                        // 解析 id
                                        if (item_obj.get("id")) |id_val| {
                                            if (id_val == .string) {
                                                tc.id = try allocator.dupe(u8, id_val.string);
                                            } else {
                                                tc.id = try allocator.dupe(u8, "");
                                            }
                                        } else {
                                            tc.id = try allocator.dupe(u8, "");
                                        }

                                        // 解析 name
                                        if (item_obj.get("name")) |name_val| {
                                            if (name_val == .string) {
                                                tc.name = try allocator.dupe(u8, name_val.string);
                                            } else {
                                                tc.name = try allocator.dupe(u8, "");
                                            }
                                        } else {
                                            tc.name = try allocator.dupe(u8, "");
                                        }

                                        // 解析 input（作为 arguments）
                                        if (item_obj.get("input")) |input_val| {
                                            // 需要复制 JSON 值，因为 parsed.deinit() 会释放原始数据
                                            const args_str = std.json.stringifyAlloc(allocator, input_val, .{}) catch "{}";
                                            defer allocator.free(args_str);
                                            const parsed_args = std.json.parseFromSlice(json.Value, allocator, args_str, .{}) catch {
                                                tc.arguments = .null;
                                                continue;
                                            };
                                            // 不调用 parsed_args.deinit()，将所有权转移给 tc.arguments
                                            // ToolCall.deinit() 会负责释放它
                                            tc.arguments = parsed_args.value;
                                        } else {
                                            tc.arguments = .null;
                                        }

                                        try tool_calls.append(tc);
                                    }
                                }
                            }
                        }
                    }

                    if (content_str.items.len > 0) {
                        response.content = try content_str.toOwnedSlice();
                    }

                    if (tool_calls.items.len > 0) {
                        response.tool_calls = try tool_calls.toOwnedSlice();
                    }
                }
            }

            if (obj.get("stop_reason")) |stop_val| {
                if (stop_val == .string) {
                    response.stop_reason = types.StopReason.fromString(stop_val.string);
                }
            }
        }

        return response;
    }

    fn handleSseEvent(ctx: *anyopaque, event: client_mod.SseEvent) anyerror!void {
        _ = ctx;
        _ = event;
    }
};

const claude_vtable = BaseSession.VTable{
    .complete = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const ToolDefinition, turn: u32) anyerror!MockResponse {
            const self: *ClaudeSession = @ptrCast(@alignCast(data));
            return self.complete(messages, tools, turn);
        }
    }.impl,
    .completeStream = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const ToolDefinition) anyerror!void {
            const self: *ClaudeSession = @ptrCast(@alignCast(data));
            return self.completeStream(messages, tools);
        }
    }.impl,
    .deinit = struct {
        fn impl(data: *anyopaque, allocator: Allocator) void {
            const self: *ClaudeSession = @ptrCast(@alignCast(data));
            self.deinit();
            allocator.destroy(self);
        }
    }.impl,
};

// ---------------------------------------------------------------------------
// OaiSession (OpenAI compatible)
// ---------------------------------------------------------------------------

/// OpenAI 兼容 API 会话
pub const OaiSession = struct {
    allocator: Allocator,
    client: LlmClient,
    config: SessionConfig,

    pub fn init(allocator: Allocator, config: SessionConfig) OaiSession {
        return .{
            .allocator = allocator,
            .client = LlmClient.init(allocator, .{
                .base_url = config.base_url,
                .api_key = config.api_key,
                .timeout_ms = config.timeout_ms,
            }),
            .config = config,
        };
    }

    pub fn deinit(self: *OaiSession) void {
        self.client.deinit();
    }

    fn buildUrl(self: *OaiSession) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{self.client.config.base_url});
    }

    fn buildHeaders(self: *OaiSession) !RequestHeaders {
        return .{
            .api_key = self.client.config.api_key,
            .content_type = "application/json",
        };
    }

    fn buildRequestBody(self: *OaiSession, messages: []const Message, tools: ?[]const ToolDefinition) ![]const u8 {
        var array = std.ArrayList(u8).init(self.allocator);
        errdefer array.deinit();

        try array.appendSlice("{\"model\":\"");
        try array.appendSlice(self.config.model);
        try array.appendSlice("\",\"max_tokens\":");
        var max_tokens_str: []const u8 = "4096";
        var should_free_max_tokens = false;
        if (std.fmt.allocPrint(self.allocator, "{}", .{self.config.max_tokens})) |allocated| {
            max_tokens_str = allocated;
            should_free_max_tokens = true;
        } else |_| {}
        errdefer if (should_free_max_tokens) self.allocator.free(max_tokens_str);
        try array.appendSlice(max_tokens_str);

        var temp_str: ?[]const u8 = null;
        if (self.config.temperature >= 0) {
            try array.appendSlice(",\"temperature\":");
            temp_str = try std.fmt.allocPrint(self.allocator, "{d}", .{@as(f64, @floatCast(self.config.temperature))});
            errdefer if (temp_str) |s| self.allocator.free(s);
            try array.appendSlice(temp_str.?);
        }

        if (tools) |tool_list| {
            try array.appendSlice(",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try array.appendSlice(",");
                try array.appendSlice("{\"type\":\"function\",\"function\":{\"name\":\"");
                try appendJsonString(&array, tool.name);
                try array.appendSlice("\",\"description\":\"");
                try appendJsonString(&array, tool.description);
                try array.appendSlice("\",\"parameters\":");
                try array.appendSlice(tool.parameters);
                try array.appendSlice("}}");
            }
            try array.appendSlice("]");
        }

        try array.appendSlice(",\"messages\":[");
        for (messages, 0..) |msg, i| {
            if (i > 0) try array.appendSlice(",");
            try array.appendSlice("{\"role\":\"");
            try array.appendSlice(msg.role.toString());
            try array.appendSlice("\",\"content\":");

            if (msg.content) |c| {
                try array.appendSlice("\"");
                try appendJsonString(&array, c);
                try array.appendSlice("\"");
            } else if (msg.content_blocks) |blocks| {
                try array.appendSlice("[");
                for (blocks, 0..) |block, j| {
                    if (j > 0) try array.appendSlice(",");
                    switch (block.tag) {
                        .text => {
                            try array.appendSlice("{\"type\":\"text\",\"text\":\"");
                            if (block.text) |text| {
                                try appendJsonString(&array, text);
                            }
                            try array.appendSlice("\"}");
                        },
                        .thinking => {
                            try array.appendSlice("{\"type\":\"text\",\"text\":\"");
                            if (block.text) |text| {
                                try appendJsonString(&array, text);
                            }
                            try array.appendSlice("\"}");
                        },
                        .tool_use => {
                            try array.appendSlice("{\"tool_call\":{\"id\":\"");
                            if (block.id) |id| {
                                try appendJsonString(&array, id);
                            }
                            try array.appendSlice("\",\"type\":\"function\",\"function\":{\"name\":\"");
                            if (block.name) |name| {
                                try appendJsonString(&array, name);
                            }
                            try array.appendSlice("\",\"arguments\":");
                            if (block.input) |input| {
                                const args_json = std.json.stringifyAlloc(self.allocator, input, .{}) catch "{}";
                                defer self.allocator.free(args_json);
                                try array.appendSlice(args_json);
                            } else {
                                try array.appendSlice("{}");
                            }
                            try array.appendSlice("}}}");
                        },
                        .image => {
                            try array.appendSlice("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                            if (block.media_type) |media_type| {
                                try appendJsonString(&array, media_type);
                            }
                            try array.appendSlice(";base64,");
                            if (block.data) |data| {
                                try appendJsonString(&array, data);
                            }
                            try array.appendSlice("\"}}");
                        },
                        .tool_result => {
                            try array.appendSlice("{\"type\":\"text\",\"text\":\"");
                            if (block.content) |content| {
                                try appendJsonString(&array, content);
                            }
                            try array.appendSlice("\"}");
                        },
                    }
                }
                try array.appendSlice("]");
            }
            try array.appendSlice("}");
        }
        try array.appendSlice("]");

        if (should_free_max_tokens) {
            self.allocator.free(max_tokens_str);
        }
        if (temp_str) |s| {
            self.allocator.free(s);
        }

        return array.toOwnedSlice();
    }

    pub fn complete(self: *OaiSession, messages: []const Message, tools: ?[]const ToolDefinition, turn: u32) !MockResponse {
        const url = try self.buildUrl();
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();

        const body = try self.buildRequestBody(messages, tools);
        defer self.allocator.free(body);

        const response = try self.client.post(url, headers, body);
        defer self.allocator.free(response.body);

        // 记录交互日志
        if (self.config.enable_logging) {
            saveInteractionLog(self.allocator, self.config.log_dir, turn, body, response.body, response.status_code);
        }

        return try parseOaiResponse(self.allocator, response.body);
    }

    pub fn completeStream(self: *OaiSession, messages: []const Message, tools: ?[]const ToolDefinition) !void {
        const url = try self.buildUrl();
        defer self.allocator.free(url);

        const headers = try self.buildHeaders();

        const body = try self.buildRequestBody(messages, tools);
        defer self.allocator.free(body);

        try self.client.postStream(url, headers, body, self, handleOaiSseEvent);
    }

    fn parseOaiResponse(allocator: Allocator, body: []const u8) !MockResponse {
        var parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
        defer parsed.deinit();

        var response: MockResponse = .{};

        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("choices")) |choices_val| {
                if (choices_val == .array and choices_val.array.items.len > 0) {
                    const choice = choices_val.array.items[0];
                    if (choice == .object) {
                        const choice_obj = choice.object;
                        if (choice_obj.get("message")) |msg_val| {
                            if (msg_val == .object) {
                                const msg_obj = msg_val.object;
                                if (msg_obj.get("content")) |content_val| {
                                    if (content_val == .string) {
                                        response.content = try allocator.dupe(u8, content_val.string);
                                    }
                                }
                                if (msg_obj.get("tool_calls")) |tool_calls_val| {
                                    if (tool_calls_val == .array) {
                                        var tool_calls = std.ArrayList(types.ToolCall).init(allocator);
                                        defer tool_calls.deinit();

                                        for (tool_calls_val.array.items) |tc_val| {
                                            if (tc_val == .object) {
                                                const tc_obj = tc_val.object;
                                                var tc: types.ToolCall = undefined;
                                                if (tc_obj.get("id")) |id_val| {
                                                    if (id_val == .string) {
                                                        tc.id = try allocator.dupe(u8, id_val.string);
                                                    } else {
                                                        tc.id = try allocator.dupe(u8, "");
                                                    }
                                                } else {
                                                    tc.id = try allocator.dupe(u8, "");
                                                }
                                                if (tc_obj.get("function")) |func_val| {
                                                    if (func_val == .object) {
                                                        const func_obj = func_val.object;
                                                        if (func_obj.get("name")) |name_val| {
                                                            if (name_val == .string) {
                                                                tc.name = try allocator.dupe(u8, name_val.string);
                                                            } else {
                                                                tc.name = try allocator.dupe(u8, "");
                                                            }
                                                        } else {
                                                            tc.name = try allocator.dupe(u8, "");
                                                        }
                                                        if (func_obj.get("arguments")) |args_val| {
                                                            const args_str = std.json.stringifyAlloc(allocator, args_val, .{}) catch "{}";
                                                            defer allocator.free(args_str);
                                                            const parsed_args = std.json.parseFromSlice(json.Value, allocator, args_str, .{}) catch |_| {
                                                                tc.arguments = .null;
                                                            };
                                                            tc.arguments = parsed_args.value;
                                                        } else {
                                                            tc.arguments = .null;
                                                        }
                                                    } else {
                                                        tc.name = try allocator.dupe(u8, "");
                                                        tc.arguments = .null;
                                                    }
                                                } else {
                                                    tc.name = try allocator.dupe(u8, "");
                                                    tc.arguments = .null;
                                                }
                                                try tool_calls.append(tc);
                                            }
                                        }
                                        response.tool_calls = try tool_calls.toOwnedSlice();
                                    }
                                }
                            }
                        }
                        if (choice_obj.get("finish_reason")) |reason_val| {
                            if (reason_val == .string) {
                                response.stop_reason = types.StopReason.fromString(reason_val.string);
                            }
                        }
                    }
                }
            }
        }

        return response;
    }

    fn handleOaiSseEvent(ctx: *anyopaque, event: client_mod.SseEvent) anyerror!void {
        _ = ctx;
        _ = event;
    }

    pub fn asBase(self: *OaiSession) BaseSession {
        return .{
            .vtable = &oai_vtable,
            .data = self,
        };
    }
};

const oai_vtable = BaseSession.VTable{
    .complete = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const ToolDefinition, turn: u32) anyerror!MockResponse {
            const self: *OaiSession = @ptrCast(@alignCast(data));
            return self.complete(messages, tools, turn);
        }
    }.impl,
    .completeStream = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const ToolDefinition) anyerror!void {
            const self: *OaiSession = @ptrCast(@alignCast(data));
            return self.completeStream(messages, tools);
        }
    }.impl,
    .deinit = struct {
        fn impl(data: *anyopaque, allocator: Allocator) void {
            const self: *OaiSession = @ptrCast(@alignCast(data));
            self.deinit();
            allocator.destroy(self);
        }
    }.impl,
};

// ---------------------------------------------------------------------------
// Factory Function
// ---------------------------------------------------------------------------

/// 根据配置创建会话
pub fn resolveSession(allocator: Allocator, config: SessionConfig) !*BaseSession {
    const session = try allocator.create(BaseSession);

    switch (config.api_mode) {
        .chat_completions => {
            const oai = try allocator.create(OaiSession);
            oai.* = OaiSession.init(allocator, config);
            session.* = .{
                .vtable = &oai_vtable,
                .data = oai,
                .allocator = allocator,
            };
        },
        .responses => {
            const claude = try allocator.create(ClaudeSession);
            claude.* = ClaudeSession.init(allocator, config);
            session.* = .{
                .vtable = &claude_vtable,
                .data = claude,
                .allocator = allocator,
            };
        },
    }

    return session;
}
