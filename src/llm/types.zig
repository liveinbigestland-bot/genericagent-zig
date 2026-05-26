//! src/llm/types.zig - LLM 类型定义
//!
//! 定义消息、内容块、工具调用、用量统计等核心数据结构。

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Role
// ---------------------------------------------------------------------------

/// 消息角色
pub const Role = enum {
    system,
    user,
    assistant,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }

    pub fn fromString(s: []const u8) ?Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        return null;
    }
};

// ---------------------------------------------------------------------------
// ContentBlock
// ---------------------------------------------------------------------------

/// 内容块类型标签
pub const ContentBlockTag = enum {
    text,
    thinking,
    tool_use,
    tool_result,
    image,
};

/// 内容块：支持文本、思考、工具调用、工具结果、图片
pub const ContentBlock = struct {
    tag: ContentBlockTag,

    /// text / thinking 共用
    text: ?[]const u8 = null,

    /// tool_use 字段
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?json.Value = null,

    /// tool_result 字段
    tool_use_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
    is_error: bool = false,

    /// image 字段
    source_type: ?[]const u8 = null, // "base64"
    media_type: ?[]const u8 = null, // "image/png"
    data: ?[]const u8 = null,

    pub fn deinit(self: *ContentBlock, allocator: Allocator) void {
        if (self.text) |t| allocator.free(t);
        if (self.id) |v| allocator.free(v);
        if (self.name) |v| allocator.free(v);
        if (self.input) |*v| {
            // std.json.dynamic.Value doesn't have deinit in Zig 0.13.0
            _ = v;
        }
        if (self.tool_use_id) |v| allocator.free(v);
        if (self.content) |v| allocator.free(v);
        if (self.source_type) |v| allocator.free(v);
        if (self.media_type) |v| allocator.free(v);
        if (self.data) |v| allocator.free(v);
    }
};

// ---------------------------------------------------------------------------
// Message
// ---------------------------------------------------------------------------

/// 消息结构体
pub const Message = struct {
    role: Role,
    /// 简单文本内容（与 content_blocks 二选一）
    content: ?[]const u8 = null,
    /// 结构化内容块列表
    content_blocks: ?[]ContentBlock = null,
    /// Claude cache_control: {"type": "ephemeral"}
    cache_control: bool = false,

    pub fn deinit(self: *Message, allocator: Allocator) void {
        if (self.content) |c| allocator.free(c);
        if (self.content_blocks) |blocks| {
            for (blocks) |*b| b.deinit(allocator);
            allocator.free(blocks);
        }
    }

    /// 获取用于显示的文本摘要
    pub fn getTextSummary(self: Message, allocator: Allocator) ![]const u8 {
        if (self.content) |c| return allocator.dupe(u8, c);
        if (self.content_blocks) |blocks| {
            var total: usize = 0;
            for (blocks) |b| {
                if (b.text) |t| total += t.len;
            }
            var buf = try allocator.alloc(u8, total);
            var off: usize = 0;
            for (blocks) |b| {
                if (b.text) |t| {
                    @memcpy(buf[off..][0..t.len], t);
                    off += t.len;
                }
            }
            return buf;
        }
        return "";
    }
};

// ---------------------------------------------------------------------------
// ToolCall / ToolResult
// ---------------------------------------------------------------------------

/// 工具调用
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: json.Value,

    pub fn deinit(self: *ToolCall, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

/// 工具调用结果
pub const ToolResult = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool = false,

    pub fn deinit(self: *ToolResult, allocator: Allocator) void {
        allocator.free(self.tool_use_id);
        allocator.free(self.content);
    }
};

// ---------------------------------------------------------------------------
// StopReason
// ---------------------------------------------------------------------------

/// 停止原因
pub const StopReason = enum {
    end_turn,
    max_tokens,
    tool_use,
    stop_sequence,
    unknown,

    pub fn fromString(s: []const u8) StopReason {
        if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
        if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
        if (std.mem.eql(u8, s, "stop")) return .end_turn;
        return .unknown;
    }
};

// ---------------------------------------------------------------------------
// MockResponse
// ---------------------------------------------------------------------------

/// 模拟/解析后的 LLM 响应
pub const MockResponse = struct {
    thinking: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    stop_reason: StopReason = .end_turn,

    pub fn deinit(self: *MockResponse, allocator: Allocator) void {
        if (self.thinking) |v| allocator.free(v);
        if (self.content) |v| allocator.free(v);
        if (self.tool_calls) |calls| {
            for (calls) |*c| c.deinit(allocator);
            allocator.free(calls);
        }
    }
};

// ---------------------------------------------------------------------------
// Usage
// ---------------------------------------------------------------------------

/// Token 用量统计
pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,

    pub fn totalTokens(self: Usage) u64 {
        return self.input_tokens + self.output_tokens;
    }
};

// ---------------------------------------------------------------------------
// ApiMode
// ---------------------------------------------------------------------------

/// OpenAI 兼容 API 模式
pub const ApiMode = enum {
    /// /v1/chat/completions
    chat_completions,
    /// /v1/responses
    responses,

    pub fn fromString(s: []const u8) ?ApiMode {
        if (std.mem.eql(u8, s, "chat_completions")) return .chat_completions;
        if (std.mem.eql(u8, s, "responses")) return .responses;
        return null;
    }
};

// ---------------------------------------------------------------------------
// ToolDefinition
// ---------------------------------------------------------------------------

/// 工具定义（用于发送给 LLM）
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    /// JSON Schema 字符串
    parameters: []const u8,

    pub fn deinit(self: *ToolDefinition, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.parameters);
    }
};

// ---------------------------------------------------------------------------
// CacheControl
// ---------------------------------------------------------------------------

/// Claude cache_control 标记
pub const CacheControl = struct {
    type: []const u8 = "ephemeral",

    pub const ephemeral: CacheControl = .{ .type = "ephemeral" };
};

// ---------------------------------------------------------------------------
// HistoryStats
// ---------------------------------------------------------------------------

/// 消息历史统计
pub const HistoryStats = struct {
    message_count: usize = 0,
    total_chars: usize = 0,
    estimated_tokens: usize = 0,
};
