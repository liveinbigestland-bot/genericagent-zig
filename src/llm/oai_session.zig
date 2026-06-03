//! src/llm/oai_session.zig - OpenAI API 会话实现

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

pub const OaiSession = struct {
    impl: session.SessionImpl,

    pub fn init(allocator: Allocator, config: session.SessionConfig) OaiSession {
        return .{
            .impl = session.createSessionImpl(allocator, config),
        };
    }

    pub fn deinit(self: *OaiSession) void {
        session.destroySessionImpl(&self.impl);
    }

    fn buildUrl(self: *OaiSession) ![]const u8 {
        return std.fmt.allocPrint(self.impl.allocator, "{s}/v1/chat/completions", .{self.impl.client.config.base_url});
    }

    fn buildHeaders(self: *OaiSession) RequestHeaders {
        return .{
            .api_key = self.impl.client.config.api_key,
            .content_type = "application/json",
        };
    }

    fn buildRequestBody(self: *OaiSession, messages: []const Message, tools: ?[]const types.ToolDefinition) ![]const u8 {
        var array = std.ArrayList(u8).init(self.impl.allocator);
        errdefer array.deinit();

        try array.appendSlice("{\"model\":\"");
        try protocol.appendJsonStringArray(&array, self.impl.config.model);
        try array.appendSlice("\",\"max_tokens\":");
        try session.appendJsonNumber(&array, self.impl.config.max_tokens);

        if (self.impl.config.temperature >= 0 and !self.impl.config.enable_thinking) {
            try array.appendSlice(",\"temperature\":");
            try session.appendJsonFloat(&array, self.impl.config.temperature);
        }

        if (self.impl.config.enable_thinking) {
            try array.appendSlice(",\"reasoning_effort\":\"");
            try protocol.appendJsonStringArray(&array, self.impl.config.reasoning_effort);
            try array.appendSlice("\",\"extra_body\":{\"thinking\":{\"type\":\"enabled\"}}");
        }

        if (tools) |tool_list| {
            try array.appendSlice(",\"tools\":[");
            for (tool_list, 0..) |tool, i| {
                if (i > 0) try array.appendSlice(",");
                try array.appendSlice("{\"type\":\"function\",\"function\":{\"name\":\"");
                try protocol.appendJsonStringArray(&array, tool.name);
                try array.appendSlice("\",\"description\":\"");
                try protocol.appendJsonStringArray(&array, tool.description);
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

            if (msg.reasoning_content) |r| {
                try array.appendSlice("\",\"reasoning_content\":\"");
                try protocol.appendJsonStringArray(&array, r);
            }

            try array.appendSlice("\",\"content\":[");

            if (msg.content) |c| {
                try array.appendSlice("{\"type\":\"text\",\"text\":\"");
                try protocol.appendJsonStringArray(&array, c);
                try array.appendSlice("\"}");
            } else if (msg.content_blocks) |blocks| {
                for (blocks, 0..) |block, j| {
                    if (j > 0) try array.appendSlice(",");
                    try protocol.appendContentBlockOai(&array, block, self.impl.allocator);
                }
            }
            try array.appendSlice("]}");
        }
        try array.appendSlice("]}\n");

        return array.toOwnedSlice();
    }

    pub fn complete(self: *OaiSession, messages: []const Message, tools: ?[]const types.ToolDefinition, turn: u32) !MockResponse {
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

        return try parseOaiResponse(self.impl.allocator, response.body);
    }

    pub fn completeStream(self: *OaiSession, messages: []const Message, tools: ?[]const types.ToolDefinition) !void {
        const url = try self.buildUrl();
        defer self.impl.allocator.free(url);

        const headers = self.buildHeaders();
        const body = try self.buildRequestBody(messages, tools);
        defer self.impl.allocator.free(body);

        try self.impl.client.postStream(url, headers, body, self, handleOaiSseEvent);
    }

    pub fn asBase(self: *OaiSession) session.BaseSession {
        return .{
            .vtable = &oai_vtable,
            .data = self,
            .allocator = self.impl.allocator,
        };
    }

    fn handleOaiSseEvent(ctx: *anyopaque, event: SseEvent) anyerror!void {
        _ = ctx;
        _ = event;
    }
};

fn parseOaiResponse(allocator: Allocator, body: []const u8) !MockResponse {
    var parsed = try json.parseFromSlice(json.Value, allocator, body, .{});
    defer parsed.deinit();

    var response: MockResponse = .{};

    if (parsed.value == .object) {
        const obj = parsed.value.object;
        if (obj.get("choices")) |choices_val| {
            if (choices_val == .array and choices_val.array.items.len > 0) {
                const first_choice = choices_val.array.items[0];
                if (first_choice == .object) {
                    const choice_obj = first_choice.object;
                    if (choice_obj.get("message")) |msg_val| {
                        if (msg_val == .object) {
                            const msg_obj = msg_val.object;
                            if (msg_obj.get("content")) |content_val| {
                                if (content_val == .string) {
                                    response.content = try allocator.dupe(u8, content_val.string);
                                }
                            }
                            if (msg_obj.get("reasoning_content")) |reasoning_val| {
                                if (reasoning_val == .string) {
                                    response.reasoning_content = try allocator.dupe(u8, reasoning_val.string);
                                }
                            }
                            if (msg_obj.get("tool_calls")) |tool_calls_val| {
                                if (tool_calls_val == .array) {
                                    var tool_calls = std.ArrayList(ToolCall).init(allocator);
                                    defer {
                                        for (tool_calls.items) |*tc| tc.deinit(allocator);
                                        tool_calls.deinit();
                                    }

                                    for (tool_calls_val.array.items) |tc_item| {
                                        if (tc_item == .object) {
                                            const tc = try protocol.parseToolCallOai(allocator, tc_item.object);
                                            try tool_calls.append(tc);
                                        }
                                    }

                                    if (tool_calls.items.len > 0) {
                                        response.tool_calls = try tool_calls.toOwnedSlice();
                                    }
                                }
                            }
                        }
                    }
                    if (choice_obj.get("finish_reason")) |finish_val| {
                        if (finish_val == .string) {
                            response.stop_reason = StopReason.fromString(finish_val.string);
                        }
                    }
                }
            }
        }
    }

    return response;
}

pub const oai_vtable = session.BaseSession.VTable{
    .complete = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const types.ToolDefinition, turn: u32) anyerror!MockResponse {
            const self: *OaiSession = @ptrCast(@alignCast(data));
            return self.complete(messages, tools, turn);
        }
    }.impl,
    .completeStream = struct {
        fn impl(data: *anyopaque, messages: []const Message, tools: ?[]const types.ToolDefinition) anyerror!void {
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
