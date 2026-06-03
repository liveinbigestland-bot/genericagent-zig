//! src/llm/claude_session.zig - Claude API 会话实现

const std = @import("std");
const json = std.json;

const types = @import("types.zig");
const client_mod = @import("client.zig");
const session = @import("session.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Message = types.Message;
const ContentBlock = types.ContentBlock;
const ToolCall = types.ToolCall;
const MockResponse = types.MockResponse;
const StopReason = types.StopReason;
const LlmClient = client_mod.LlmClient;
const RequestHeaders = client_mod.RequestHeaders;
const SseEvent = client_mod.SseEvent;

pub const ClaudeSession = struct {
    impl: session.SessionImpl,

    pub fn init(allocator: Allocator, config: session.SessionConfig) ClaudeSession {
        return .{
            .impl = session.createSessionImpl(allocator, config),
        };
    }

    pub fn deinit(self: *ClaudeSession) void {
        session.destroySessionImpl(&self.impl);
    }

    fn buildUrl(self: *ClaudeSession) ![]const u8 {
        return std.fmt.allocPrint(self.impl.allocator, "{s}/v1/messages", .{self.impl.client.config.base_url});
    }

    fn buildHeaders(self: *ClaudeSession) RequestHeaders {
        return .{
            .api_key = self.impl.client.config.api_key,
            .content_type = "application/json",
        };
    }

    fn buildRequestBody(self: *ClaudeSession, messages: []const Message, tools: ?[]const types.ToolDefinition) ![]const u8 {
        var array = std.ArrayList(u8).init(self.impl.allocator);
        errdefer array.deinit();

        try array.appendSlice("{\"model\":\"");
        try protocol.appendJsonStringArray(&array, self.impl.config.model);
        try array.appendSlice("\",\"max_tokens\":");
        try session.appendJsonNumber(&array, self.impl.config.max_tokens);

        if (self.impl.config.temperature >= 0) {
            try array.appendSlice(",\"temperature\":");
            try session.appendJsonFloat(&array, self.impl.config.temperature);
        }

        if (tools) |tool_list| {
            try array.appendSlice(",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try array.appendSlice(",");
                try array.appendSlice("{\"name\":\"");
                try protocol.appendJsonStringArray(&array, tool.name);
                try array.appendSlice("\",\"description\":\"");
                try protocol.appendJsonStringArray(&array, tool.description);
                try array.appendSlice("\",\"input_schema\":");
                try array.appendSlice(tool.parameters);
                try array.appendSlice("}");
            }
            try array.appendSlice("]");
        }

        var system_content: ?[]const u8 = null;
        var user_messages = std.ArrayList(Message).init(self.impl.allocator);
        defer user_messages.deinit();

        for (messages) |msg| {
            if (msg.role == .system) {
                system_content = msg.content;
            } else {
                try user_messages.append(msg);
            }
        }

        if (system_content) |sc| {
            try array.appendSlice(",\"system\":\"");
            try protocol.appendJsonStringArray(&array, sc);
            try array.appendSlice("\"");
        }

        try array.appendSlice(",\"messages\":[");
        for (user_messages.items, 0..) |msg, i| {
            if (i > 0) try array.appendSlice(",");
            try array.appendSlice("{\"role\":\"");
            try array.appendSlice(msg.role.toString());
            try array.appendSlice("\",\"content\":[");

            if (msg.content_blocks) |blocks| {
                for (blocks, 0..) |block, j| {
                    if (j > 0) try array.appendSlice(",");
                    try protocol.appendContentBlockClaude(&array, block, self.impl.allocator);
                }
            } else if (msg.content) |c| {
                try array.appendSlice("{\"type\":\"text\",\"thinking\":\"\",\"text\":\"");
                try protocol.appendJsonStringArray(&array, c);
                try array.appendSlice("\"}");
            }
            try array.appendSlice("]}");
        }
        try array.appendSlice("]}");

        return array.toOwnedSlice();
    }

    pub fn complete(self: *ClaudeSession, messages: []const Message, tools: ?[]const types.ToolDefinition, turn: u32) !MockResponse {
        const url = try self.buildUrl();
        defer self.impl.allocator.free(url);

        const headers = self.buildHeaders();
        const body = try self.buildRequestBody(messages, tools);
        defer self.impl.allocator.free(body);

        const response = try self.impl.client.post(url, headers, body);
        defer self.impl.allocator.free(response.body);

        if (self.impl.config.enable_logging) {
            session.saveInteractionLog(self.impl.allocator, self.impl.config.log_dir, turn, body, response.body, response.status_code);
        }

        return try parseClaudeResponse(self.impl.allocator, response.body);
    }

    pub fn completeStream(self: *ClaudeSession, messages: []const Message, tools: ?[]const types.ToolDefinition) !void {
        const url = try self.buildUrl();
        defer self.impl.allocator.free(url);

        const headers = self.buildHeaders();
        const body = try self.buildRequestBody(messages, tools);
        defer self.impl.allocator.free(body);

        try self.impl.client.postStream(url, headers, body, self, handleClaudeSseEvent);
    }

    pub fn asBase(self: *ClaudeSession) session.BaseSession {
        return .{
            .vtable = &claude_vtable,
            .data = self,
            .allocator = self.impl.allocator,
        };
    }

    fn handleClaudeSseEvent(ctx: *anyopaque, event: SseEvent) anyerror!void {
        _ = ctx;
        _ = event;
    }
};

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

                var content_blocks = std.ArrayList(types.ContentBlock).init(allocator);
                defer {
                    for (content_blocks.items) |*b| b.deinit(allocator);
                    content_blocks.deinit();
                }

                var tool_calls = std.ArrayList(ToolCall).init(allocator);
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
                                    var thinking: ?[]const u8 = null;
                                    var text: ?[]const u8 = null;

                                    if (item_obj.get("thinking")) |thinking_val| {
                                        if (thinking_val == .string) {
                                            thinking = try allocator.dupe(u8, thinking_val.string);
                                        }
                                    }
                                    if (item_obj.get("text")) |text_val| {
                                        if (text_val == .string) {
                                            text = try allocator.dupe(u8, text_val.string);
                                            try content_str.appendSlice(text_val.string);
                                        }
                                    }

                                    try content_blocks.append(.{
                                        .tag = .text,
                                        .thinking = thinking,
                                        .text = text,
                                    });
                                } else if (std.mem.eql(u8, type_val.string, "thinking")) {
                                    var thinking: ?[]const u8 = null;
                                    var text: ?[]const u8 = null;

                                    if (item_obj.get("thinking")) |thinking_val| {
                                        if (thinking_val == .string) {
                                            thinking = try allocator.dupe(u8, thinking_val.string);
                                        }
                                    }
                                    if (item_obj.get("text")) |text_val| {
                                        if (text_val == .string) {
                                            text = try allocator.dupe(u8, text_val.string);
                                            try content_str.appendSlice(text_val.string);
                                            // 保存 thinking 内容到 response.thinking
                                            if (response.thinking == null) {
                                                response.thinking = try allocator.dupe(u8, text_val.string);
                                            }
                                        }
                                    }

                                    try content_blocks.append(.{
                                        .tag = .thinking,
                                        .thinking = thinking,
                                        .text = text,
                                    });
                                } else if (std.mem.eql(u8, type_val.string, "tool_use")) {
                                    const tc = try protocol.parseToolCallClaude(allocator, item_obj);
                                    try tool_calls.append(tc);
                                }
                            }
                        }
                    }
                }

                if (content_str.items.len > 0) {
                    response.content = try content_str.toOwnedSlice();
                }
                if (content_blocks.items.len > 0) {
                    response.content_blocks = try content_blocks.toOwnedSlice();
                    content_blocks.items.len = 0;
                }
                if (tool_calls.items.len > 0) {
                    response.tool_calls = try tool_calls.toOwnedSlice();
                    tool_calls.items.len = 0;
                }
            }
        }

        if (obj.get("stop_reason")) |stop_val| {
            if (stop_val == .string) {
                response.stop_reason = StopReason.fromString(stop_val.string);
            }
        }

        if (obj.get("usage")) |usage_val| {
            if (usage_val == .object) {
                const usage_obj = usage_val.object;
                if (usage_obj.get("input_tokens")) |input_val| {
                    if (input_val == .integer) {
                        response.usage.input_tokens = @intCast(input_val.integer);
                    }
                }
                if (usage_obj.get("output_tokens")) |output_val| {
                    if (output_val == .integer) {
                        response.usage.output_tokens = @intCast(output_val.integer);
                    }
                }
                if (usage_obj.get("cache_creation_input_tokens")) |cache_create_val| {
                    if (cache_create_val == .integer) {
                        response.usage.cache_creation_tokens = @intCast(cache_create_val.integer);
                    }
                }
                if (usage_obj.get("cache_read_input_tokens")) |cache_read_val| {
                    if (cache_read_val == .integer) {
                        response.usage.cache_read_tokens = @intCast(cache_read_val.integer);
                    }
                }
            }
        }
    }

    return response;
}

pub const claude_vtable = session.BaseSession.VTable{
    .complete = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const types.ToolDefinition, turn: u32) anyerror!MockResponse {
            const self: *ClaudeSession = @ptrCast(@alignCast(data));
            return self.complete(messages, tools, turn);
        }
    }.impl,
    .completeStream = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const types.ToolDefinition) anyerror!void {
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
