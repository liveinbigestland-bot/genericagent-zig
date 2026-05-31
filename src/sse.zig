//! sse.zig - SSE (Server-Sent Events) 流解析器
//!
//! 支持 Claude (Anthropic) 和 OpenAI 的 SSE 流格式。
//! 提供逐行解析接口，维护增量状态，最终产出 ParsedResponse。
//!
//! Claude SSE 事件类型:
//!   message_start, content_block_start, content_block_delta,
//!   content_block_stop, message_delta, message_stop, error
//!
//! OpenAI SSE 事件类型:
//!   choices[0].delta.content, choices[0].delta.tool_calls,
//!   choices[0].delta.reasoning_content, usage

const std = @import("std");
const Allocator = std.mem.Allocator;
const json_mod = @import("zig_json.zig");

// ============================================================================
// 内容块类型
// ============================================================================

/// 内容块类型：文本、思考、工具调用。
pub const ContentBlockType = enum {
    text,
    thinking,
    tool_use,
};

/// 单个内容块。
pub const ContentBlock = struct {
    block_type: ContentBlockType,
    /// 文本内容（text / thinking / tool_use 的 input_json 片段）
    text: []const u8,
    /// 工具调用名称（仅 tool_use 有效）
    tool_name: []const u8,
    /// 工具调用 ID（仅 tool_use 有效）
    tool_id: []const u8,
    /// 工具调用序号（仅 tool_use 有效，用于 OpenAI tool_calls 索引）
    tool_index: i64,

    pub fn deinit(self: *ContentBlock, allocator: Allocator) void {
        if (self.text.len > 0) allocator.free(self.text);
        if (self.tool_name.len > 0) allocator.free(self.tool_name);
        if (self.tool_id.len > 0) allocator.free(self.tool_id);
        self.* = .{
            .block_type = .text,
            .text = "",
            .tool_name = "",
            .tool_id = "",
            .tool_index = -1,
        };
    }
};

// ============================================================================
// 使用量统计
// ============================================================================

/// Token 使用量统计。
pub const Usage = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,

    pub fn zero() Usage {
        return .{
            .input_tokens = 0,
            .output_tokens = 0,
            .cache_read_input_tokens = 0,
            .cache_creation_input_tokens = 0,
        };
    }
};

// ============================================================================
// 停止原因
// ============================================================================

/// 响应停止原因。
pub const StopReason = enum {
    end_turn,
    max_tokens,
    tool_use,
    stop_sequence,
    unknown,
};

// ============================================================================
// 解析后的完整响应
// ============================================================================

/// SSE 流解析完成后产出的完整响应。
pub const ParsedResponse = struct {
    /// 内容块列表，调用方拥有所有权。
    content_blocks: std.ArrayList(ContentBlock),
    /// 停止原因。
    stop_reason: StopReason,
    /// Token 使用量。
    usage: Usage,
    /// 是否遇到错误。
    has_error: bool,
    /// 错误信息（如有）。
    error_message: []const u8,

    pub fn init(allocator: Allocator) ParsedResponse {
        return .{
            .content_blocks = std.ArrayList(ContentBlock).init(allocator),
            .stop_reason = .unknown,
            .usage = Usage.zero(),
            .has_error = false,
            .error_message = "",
        };
    }

    pub fn deinit(self: *ParsedResponse, allocator: Allocator) void {
        for (self.content_blocks.items) |*block| {
            block.deinit(allocator);
        }
        self.content_blocks.deinit(allocator);
        if (self.error_message.len > 0) allocator.free(self.error_message);
    }
};

// ============================================================================
// SSE 流解析器
// ============================================================================

/// SSE 提供商类型。
pub const Provider = enum {
    anthropic,
    openai,
};

/// SSE 流解析器状态。
pub const SseParser = struct {
    allocator: Allocator,
    provider: Provider,
    /// 当前正在构建的内容块索引（Claude content_block_delta 用）。
    current_block_index: i64,
    /// 当前内容块类型（Claude content_block_start 时设置）。
    current_block_type: ContentBlockType,
    /// 当前工具名称（Claude content_block_start 时设置）。
    current_tool_name: []const u8,
    /// 当前工具 ID（Claude content_block_start 时设置）。
    current_tool_id: []const u8,
    /// OpenAI tool_calls 按 index 映射的 ContentBlock 索引。
    openai_tool_indices: std.AutoHashMap(i64, usize),
    /// 是否已开始处理。
    started: bool,
    /// 累积的解析结果。
    response: ParsedResponse,

    pub fn init(allocator: Allocator, provider: Provider) SseParser {
        return .{
            .allocator = allocator,
            .provider = provider,
            .current_block_index = -1,
            .current_block_type = .text,
            .current_tool_name = "",
            .current_tool_id = "",
            .openai_tool_indices = std.AutoHashMap(i64, usize).init(allocator),
            .started = false,
            .response = ParsedResponse.init(allocator),
        };
    }

    pub fn deinit(self: *SseParser) void {
        if (self.current_tool_name.len > 0) self.allocator.free(self.current_tool_name);
        if (self.current_tool_id.len > 0) self.allocator.free(self.current_tool_id);
        self.openai_tool_indices.deinit();
        self.response.deinit(self.allocator);
    }

    /// 获取解析结果的所有权。调用后 SseParser 不再持有结果。
    pub fn takeResponse(self: *SseParser) ParsedResponse {
        const resp = self.response;
        self.response = ParsedResponse.init(self.allocator);
        return resp;
    }

    /// 处理一行 SSE 数据。
    /// 输入格式为 "data: {...}" 或 "event: xxx" 等。
    /// 空行表示事件结束，会触发内部刷新。
    pub fn parseSSELine(self: *SseParser, line: []const u8) !void {
        // 跳过空行
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;

        // 跳过注释
        if (trimmed[0] == ':') return;

        // 解析 "data: " 前缀
        if (!std.mem.startsWith(u8, trimmed, "data:")) return;

        const data_str = if (trimmed.len > 5)
            std.mem.trim(u8, trimmed[5..], " ")
        else
            return;

        // "[DONE]" 是 OpenAI 的流结束标记
        if (std.mem.eql(u8, data_str, "[DONE]")) return;

        // 解析 JSON
        const parsed = json_mod.parseFromString(self.allocator, data_str) catch |err| {
            std.log.warn("SSE JSON parse error: {}", .{err});
            return;
        };
        defer parsed.deinit(self.allocator);

        switch (self.provider) {
            .anthropic => try self.parseAnthropicEvent(&parsed),
            .openai => try self.parseOpenAIEvent(&parsed),
        }
    }

    // ====================================================================
    // Claude (Anthropic) SSE 解析
    // ====================================================================

    fn parseAnthropicEvent(self: *SseParser, value: *const json_mod.Value) !void {
        const type_str = value.getString("type") orelse return;

        if (std.mem.eql(u8, type_str, "message_start")) {
            // 提取 usage 信息
            if (value.getObject("message")) |msg| {
                if (msg.getObject("usage")) |usage| {
                    if (usage.getInt("input_tokens")) |n| {
                        self.response.usage.input_tokens = @intCast(n);
                    }
                    if (usage.getInt("cache_read_input_tokens")) |n| {
                        self.response.usage.cache_read_input_tokens = @intCast(n);
                    }
                    if (usage.getInt("cache_creation_input_tokens")) |n| {
                        self.response.usage.cache_creation_input_tokens = @intCast(n);
                    }
                }
            }
            self.started = true;
        } else if (std.mem.eql(u8, type_str, "content_block_start")) {
            // 开始新的内容块
            if (value.getObject("content_block")) |block| {
                const block_type_str = block.getString("type") orelse "";
                const index = block.getInt("index") orelse 0;

                self.current_block_index = index;

                if (std.mem.eql(u8, block_type_str, "text")) {
                    self.current_block_type = .text;
                    try self.appendNewBlock(.text, "", "", "", -1);
                } else if (std.mem.eql(u8, block_type_str, "thinking")) {
                    self.current_block_type = .thinking;
                    try self.appendNewBlock(.thinking, "", "", "", -1);
                } else if (std.mem.eql(u8, block_type_str, "tool_use")) {
                    self.current_block_type = .tool_use;
                    const tool_name = block.getString("name") orelse "";
                    const tool_id = block.getString("id") orelse "";
                    // 保存工具信息
                    if (self.current_tool_name.len > 0) self.allocator.free(self.current_tool_name);
                    if (self.current_tool_id.len > 0) self.allocator.free(self.current_tool_id);
                    self.current_tool_name = try self.allocator.dupe(u8, tool_name);
                    self.current_tool_id = try self.allocator.dupe(u8, tool_id);
                    try self.appendNewBlock(.tool_use, "", tool_name, tool_id, -1);
                }
            }
        } else if (std.mem.eql(u8, type_str, "content_block_delta")) {
            // 增量内容
            if (value.getObject("delta")) |delta| {
                const delta_type = delta.getString("type") orelse "";
                const index = value.getInt("index") orelse self.current_block_index;

                if (std.mem.eql(u8, delta_type, "text_delta")) {
                    try self.appendToBlock(index, .text, delta.getString("text") orelse "");
                } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                    try self.appendToBlock(index, .thinking, delta.getString("thinking") orelse "");
                } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                    try self.appendToBlock(index, .tool_use, delta.getString("partial_json") orelse "");
                }
            }
        } else if (std.mem.eql(u8, type_str, "content_block_stop")) {
            // 内容块结束，无需特殊处理

        } else if (std.mem.eql(u8, type_str, "message_delta")) {
            // 提取 stop_reason 和 usage
            if (value.getObject("delta")) |delta| {
                const reason_str = delta.getString("stop_reason") orelse "";
                self.response.stop_reason = parseStopReason(reason_str);
            }
            if (value.getObject("usage")) |usage| {
                if (usage.getInt("output_tokens")) |n| {
                    self.response.usage.output_tokens = @intCast(n);
                }
            }
        } else if (std.mem.eql(u8, type_str, "message_stop")) {
            // 消息结束

        } else if (std.mem.eql(u8, type_str, "error")) {
            self.response.has_error = true;
            if (value.getObject("error")) |err_obj| {
                const msg = err_obj.getString("message") orelse "unknown error";
                if (self.response.error_message.len > 0) self.allocator.free(self.response.error_message);
                self.response.error_message = try self.allocator.dupe(u8, msg);
            } else {
                if (self.response.error_message.len > 0) self.allocator.free(self.response.error_message);
                self.response.error_message = try self.allocator.dupe(u8, "unknown error");
            }
        }
    }

    // ====================================================================
    // OpenAI SSE 解析
    // ====================================================================

    fn parseOpenAIEvent(self: *SseParser, value: *const json_mod.Value) !void {
        // 提取 choices[0].delta
        if (value.getArray("choices")) |choices| {
            if (choices.items.len > 0) {
                if (choices.items[0].getObject("delta")) |delta| {
                    // 文本内容
                    if (delta.getString("content")) |content| {
                        if (content.len > 0) {
                            try self.appendOrMergeTextBlock(content);
                        }
                    }

                    // 推理内容 (reasoning_content)
                    if (delta.getString("reasoning_content")) |reasoning| {
                        if (reasoning.len > 0) {
                            try self.appendOrMergeThinkingBlock(reasoning);
                        }
                    }

                    // 工具调用
                    if (delta.getArray("tool_calls")) |tool_calls| {
                        for (tool_calls.items) |*tc| {
                            const index = tc.getInt("index") orelse -1;
                            const func = tc.getObject("function");

                            // 如果是新工具调用，创建新的 tool_use 块
                            if (!self.openai_tool_indices.contains(index)) {
                                const tool_name = if (func) |f|
                                    f.getString("name") orelse ""
                                else
                                    "";
                                const tool_id = tc.getString("id") orelse "";
                                const block_idx = self.response.content_blocks.items.len;
                                try self.openai_tool_indices.put(index, block_idx);
                                try self.appendNewBlock(.tool_use, "", tool_name, tool_id, index);
                            }

                            // 追加 arguments 片段
                            if (func) |f| {
                                if (f.getString("arguments")) |args| {
                                    if (args.len > 0) {
                                        if (self.openai_tool_indices.get(index)) |block_idx| {
                                            try self.appendToBlockByIndex(block_idx, args);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 检查 finish_reason
                    if (choices.items[0].getString("finish_reason")) |reason| {
                        self.response.stop_reason = parseOpenAIFinishReason(reason);
                    }
                }
            }
        }

        // 提取 usage 信息
        if (value.getObject("usage")) |usage| {
            if (usage.getInt("prompt_tokens")) |n| {
                self.response.usage.input_tokens = @intCast(n);
            }
            if (usage.getInt("completion_tokens")) |n| {
                self.response.usage.output_tokens = @intCast(n);
            }
            if (usage.getInt("prompt_tokens_details")) |n| {
                _ = n;
                // OpenAI 的 cache token 统计在 prompt_tokens_details 对象内
                // 这里简化处理
            }
        }
    }

    // ====================================================================
    // 辅助方法
    // ====================================================================

    /// 追加新的内容块。
    fn appendNewBlock(self: *SseParser, block_type: ContentBlockType, text: []const u8, tool_name: []const u8, tool_id: []const u8, tool_index: i64) !void {
        const owned_text = if (text.len > 0) try self.allocator.dupe(u8, text) else "";
        const owned_name = if (tool_name.len > 0) try self.allocator.dupe(u8, tool_name) else "";
        const owned_id = if (tool_id.len > 0) try self.allocator.dupe(u8, tool_id) else "";

        try self.response.content_blocks.append(.{
            .block_type = block_type,
            .text = owned_text,
            .tool_name = owned_name,
            .tool_id = owned_id,
            .tool_index = tool_index,
        });
    }

    /// 按 Claude 的 block index 追加文本到对应内容块。
    fn appendToBlock(self: *SseParser, block_index: i64, expected_type: ContentBlockType, text: []const u8) !void {
        if (text.len == 0) return;

        const idx = @as(usize, @intCast(block_index));
        if (idx >= self.response.content_blocks.items.len) return;

        const block = &self.response.content_blocks.items[idx];
        // 验证类型匹配
        if (block.block_type != expected_type) return;

        try self.appendToBlockByIndex(idx, text);
    }

    /// 按数组索引追加文本到内容块。
    fn appendToBlockByIndex(self: *SseParser, block_index: usize, text: []const u8) !void {
        if (text.len == 0) return;
        if (block_index >= self.response.content_blocks.items.len) return;

        const block = &self.response.content_blocks.items[block_index];
        const old_text = block.text;
        const new_text = try self.allocator.alloc(u8, old_text.len + text.len);
        @memcpy(new_text[0..old_text.len], old_text);
        @memcpy(new_text[old_text.len..], text);
        block.text = new_text;
        if (old_text.len > 0) self.allocator.free(old_text);
    }

    /// OpenAI: 追加或合并文本块。
    /// 如果最后一个块是 text 类型，追加；否则创建新的 text 块。
    fn appendOrMergeTextBlock(self: *SseParser, content: []const u8) !void {
        const blocks = self.response.content_blocks.items;
        if (blocks.len > 0 and blocks[blocks.len - 1].block_type == .text) {
            try self.appendToBlockByIndex(blocks.len - 1, content);
        } else {
            try self.appendNewBlock(.text, content, "", "", -1);
        }
    }

    /// OpenAI: 追加或合并思考块。
    /// 如果最后一个块是 thinking 类型，追加；否则创建新的 thinking 块。
    fn appendOrMergeThinkingBlock(self: *SseParser, content: []const u8) !void {
        const blocks = self.response.content_blocks.items;
        if (blocks.len > 0 and blocks[blocks.len - 1].block_type == .thinking) {
            try self.appendToBlockByIndex(blocks.len - 1, content);
        } else {
            try self.appendNewBlock(.thinking, content, "", "", -1);
        }
    }
};

// ============================================================================
// 停止原因解析
// ============================================================================

/// 解析 Claude 的 stop_reason 字符串。
fn parseStopReason(reason: []const u8) StopReason {
    if (std.mem.eql(u8, reason, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, reason, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop_sequence;
    return .unknown;
}

/// 解析 OpenAI 的 finish_reason 字符串。
fn parseOpenAIFinishReason(reason: []const u8) StopReason {
    if (std.mem.eql(u8, reason, "stop")) return .end_turn;
    if (std.mem.eql(u8, reason, "length")) return .max_tokens;
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, reason, "content_filter")) return .unknown;
    return .unknown;
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "parseSSELine - Claude message_start" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-3","usage":{"input_tokens":100,"cache_read_input_tokens":50}}}
    );

    try testing.expectEqual(@as(u64, 100), parser.response.usage.input_tokens);
    try testing.expectEqual(@as(u64, 50), parser.response.usage.cache_read_input_tokens);
}

test "parseSSELine - Claude content_block_start text" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    );

    try testing.expectEqual(@as(usize, 1), parser.response.content_blocks.items.len);
    try testing.expectEqual(ContentBlockType.text, parser.response.content_blocks.items[0].block_type);
}

test "parseSSELine - Claude content_block_delta text_delta" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    // 先发送 content_block_start
    try parser.parseSSELine(
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    );
    // 再发送 delta
    try parser.parseSSELine(
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
    );
    try parser.parseSSELine(
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" World"}}
    );

    try testing.expectEqualStrings("Hello World", parser.response.content_blocks.items[0].text);
}

test "parseSSELine - Claude tool_use block" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    // content_block_start for tool_use
    try parser.parseSSELine(
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather"}}
    );
    // input_json_delta
    try parser.parseSSELine(
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}
    );
    try parser.parseSSELine(
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"Tokyo\"}"}}
    );

    try testing.expectEqual(@as(usize, 1), parser.response.content_blocks.items.len);
    try testing.expectEqual(ContentBlockType.tool_use, parser.response.content_blocks.items[0].block_type);
    try testing.expectEqualStrings("get_weather", parser.response.content_blocks.items[0].tool_name);
    try testing.expectEqualStrings("toolu_1", parser.response.content_blocks.items[0].tool_id);
    try testing.expectEqualStrings("{\"city\":\"Tokyo\"}", parser.response.content_blocks.items[0].text);
}

test "parseSSELine - Claude thinking block" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
    );
    try parser.parseSSELine(
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think..."}}
    );

    try testing.expectEqual(ContentBlockType.thinking, parser.response.content_blocks.items[0].block_type);
    try testing.expectEqualStrings("Let me think...", parser.response.content_blocks.items[0].text);
}

test "parseSSELine - Claude message_delta stop_reason" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}
    );

    try testing.expectEqual(StopReason.end_turn, parser.response.stop_reason);
    try testing.expectEqual(@as(u64, 50), parser.response.usage.output_tokens);
}

test "parseSSELine - Claude error" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"type":"error","error":{"type":"api_error","message":"Rate limit exceeded"}}
    );

    try testing.expect(parser.response.has_error);
    try testing.expectEqualStrings("Rate limit exceeded", parser.response.error_message);
}

test "parseSSELine - OpenAI delta content" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .openai);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
    );
    try parser.parseSSELine(
        \\data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" World"},"finish_reason":null}]}
    );

    try testing.expectEqual(@as(usize, 1), parser.response.content_blocks.items.len);
    try testing.expectEqualStrings("Hello World", parser.response.content_blocks.items[0].text);
}

test "parseSSELine - OpenAI reasoning_content" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .openai);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"choices":[{"delta":{"reasoning_content":"thinking..."}}]}
    );

    try testing.expectEqual(@as(usize, 1), parser.response.content_blocks.items.len);
    try testing.expectEqual(ContentBlockType.thinking, parser.response.content_blocks.items[0].block_type);
    try testing.expectEqualStrings("thinking...", parser.response.content_blocks.items[0].text);
}

test "parseSSELine - OpenAI tool_calls" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .openai);
    defer parser.deinit();

    // 第一个 tool_call chunk（包含 name 和 id）
    try parser.parseSSELine(
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}
    );
    // 第二个 chunk（追加 arguments）
    try parser.parseSSELine(
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":\"Paris\"}"}}]}}]}
    );

    try testing.expectEqual(@as(usize, 1), parser.response.content_blocks.items.len);
    const block = parser.response.content_blocks.items[0];
    try testing.expectEqual(ContentBlockType.tool_use, block.block_type);
    try testing.expectEqualStrings("get_weather", block.tool_name);
    try testing.expectEqualStrings("call_1", block.tool_id);
    try testing.expectEqualStrings("{\"city\":\"Paris\"}", block.text);
}

test "parseSSELine - OpenAI finish_reason and usage" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .openai);
    defer parser.deinit();

    try parser.parseSSELine(
        \\data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}
    );

    try testing.expectEqual(StopReason.end_turn, parser.response.stop_reason);
    try testing.expectEqual(@as(u64, 10), parser.response.usage.input_tokens);
    try testing.expectEqual(@as(u64, 20), parser.response.usage.output_tokens);
}

test "parseSSELine - OpenAI [DONE]" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .openai);
    defer parser.deinit();

    // [DONE] 应被忽略，不产生错误
    try parser.parseSSELine("data: [DONE]");
    try testing.expectEqual(@as(usize, 0), parser.response.content_blocks.items.len);
}

test "parseSSELine - skip non-data lines" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    try parser.parseSSELine("event: message_start");
    try parser.parseSSELine("id: msg_123");
    try parser.parseSSELine(": this is a comment");
    try parser.parseSSELine("");

    try testing.expectEqual(@as(usize, 0), parser.response.content_blocks.items.len);
}

test "parseSSELine - Claude full conversation flow" {
    const allocator = testing.allocator;
    var parser = SseParser.init(allocator, .anthropic);
    defer parser.deinit();

    // message_start
    try parser.parseSSELine(
        \\data: {"type":"message_start","message":{"usage":{"input_tokens":25}}}
    );
    // thinking block
    try parser.parseSSELine(
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
    );
    try parser.parseSSELine(
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Hmm"}}
    );
    try parser.parseSSELine(
        \\data: {"type":"content_block_stop","index":0}
    );
    // text block
    try parser.parseSSELine(
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
    );
    try parser.parseSSELine(
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}
    );
    try parser.parseSSELine(
        \\data: {"type":"content_block_stop","index":1}
    );
    // message_delta
    try parser.parseSSELine(
        \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}
    );
    // message_stop
    try parser.parseSSELine(
        \\data: {"type":"message_stop"}
    );

    try testing.expectEqual(@as(usize, 2), parser.response.content_blocks.items.len);
    try testing.expectEqual(ContentBlockType.thinking, parser.response.content_blocks.items[0].block_type);
    try testing.expectEqualStrings("Hmm", parser.response.content_blocks.items[0].text);
    try testing.expectEqual(ContentBlockType.text, parser.response.content_blocks.items[1].block_type);
    try testing.expectEqualStrings("Answer", parser.response.content_blocks.items[1].text);
    try testing.expectEqual(StopReason.end_turn, parser.response.stop_reason);
    try testing.expectEqual(@as(u64, 25), parser.response.usage.input_tokens);
    try testing.expectEqual(@as(u64, 10), parser.response.usage.output_tokens);
}
