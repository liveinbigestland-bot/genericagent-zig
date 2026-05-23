//! llm 模块 —— 大语言模型接口
//!
//! 提供与 LLM 服务交互的能力，包括：
//! - HTTP 请求发送与响应解析
//! - 提示词（prompt）构建与管理
//! - 流式输出支持
//! - 多模型适配（OpenAI / Anthropic / 本地模型等）

const std = @import("std");

// 重导出子模块
pub const types = @import("types.zig");
pub const session = @import("session.zig");
pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");

// 重导出常用类型
pub const Message = types.Message;
pub const ContentBlock = types.ContentBlock;
pub const ContentBlockTag = types.ContentBlockTag;
pub const ToolCall = types.ToolCall;
pub const ToolResult = types.ToolResult;
pub const ToolDefinition = types.ToolDefinition;
pub const MockResponse = types.MockResponse;
pub const StopReason = types.StopReason;
pub const Role = types.Role;
pub const Usage = types.Usage;
pub const ApiMode = types.ApiMode;
pub const HistoryStats = types.HistoryStats;

// 重导出 session 类型
pub const SessionConfig = session.SessionConfig;
pub const BaseSession = session.BaseSession;
pub const ClaudeSession = session.ClaudeSession;
pub const OaiSession = session.OaiSession;
pub const resolveSession = session.resolveSession;

// 重导出 client 类型
pub const LlmClient = client.LlmClient;
pub const ClientConfig = client.ClientConfig;
pub const LlmError = client.LlmError;
pub const RequestHeaders = client.RequestHeaders;
pub const ResponseResult = client.ResponseResult;
pub const SseEvent = client.SseEvent;

pub const LlmErrorAlias = error{
    ApiKeyMissing,
    RequestFailed,
    ResponseParseError,
    RateLimited,
    ModelNotFound,
    Timeout,
    InvalidRequest,
};

/// LLM 配置
pub const Config = struct {
    api_key: []const u8 = "",
    base_url: []const u8 = "https://api.openai.com/v1",
    model: []const u8 = "gpt-4",
    temperature: f32 = 0.7,
    max_tokens: u32 = 4096,
};

/// LLM 客户端
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) Client {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    /// 发送聊天请求并返回响应文本
    pub fn chat(self: *Client, messages: []const Message) LlmErrorAlias![]const u8 {
        _ = self;
        _ = messages;
        return LlmErrorAlias.ApiKeyMissing; // TODO: 实际实现
    }
};
