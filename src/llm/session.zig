//! src/llm/session.zig - 会话管理基础模块
//!
//! 定义 SessionConfig、BaseSession 接口、SessionImpl 基类、
//! 以及 resolveSession 工厂函数。具体实现见 claude_session.zig 和 oai_session.zig。

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const protocol = @import("protocol.zig");

const Message = types.Message;
const ApiMode = types.ApiMode;

// ---------------------------------------------------------------------------
// 交互日志工具函数
// ---------------------------------------------------------------------------

fn getTimestamp(allocator: Allocator) ![]const u8 {
    const now = @divFloor(std.time.nanoTimestamp(), 1_000_000_000);
    return std.fmt.allocPrint(allocator, "{}", .{now});
}

pub fn saveInteractionLog(allocator: Allocator, log_dir: []const u8, turn: u32, request: []const u8, response: []const u8, status_code: u32) void {
    std.fs.cwd().makePath(log_dir) catch |err| {
        std.log.err("failed to create log directory '{s}': {}", .{ log_dir, err });
        return;
    };

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

    // 解析 request 和 response 为 JSON 值
    const request_parsed = std.json.parseFromSlice(std.json.Value, allocator, request, .{}) catch |err| {
        std.log.err("failed to parse request JSON: {}", .{err});
        return;
    };
    defer request_parsed.deinit();

    const response_parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch |err| {
        std.log.err("failed to parse response JSON: {}", .{err});
        return;
    };
    defer response_parsed.deinit();

    // 构造日志对象
    var log_object = std.json.ObjectMap.init(allocator);
    defer log_object.deinit();

    log_object.put("timestamp", .{ .string = timestamp }) catch return;
    log_object.put("turn", .{ .integer = @intCast(turn) }) catch return;
    log_object.put("status_code", .{ .integer = @intCast(status_code) }) catch return;
    log_object.put("request", request_parsed.value) catch return;
    log_object.put("response", response_parsed.value) catch return;

    const log_value = std.json.Value{ .object = log_object };

    // 序列化为 JSON 字符串
    var log_content = std.ArrayList(u8).init(allocator);
    defer log_content.deinit();

    std.json.stringify(log_value, .{ .whitespace = .indent_2 }, log_content.writer()) catch |err| {
        std.log.err("failed to stringify log JSON: {}", .{err});
        return;
    };

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
// JSON 序列化辅助函数（从 protocol 导入）
// ---------------------------------------------------------------------------

pub const appendJsonString = protocol.appendJsonStringArray;

pub fn appendJsonNumber(array: *std.ArrayList(u8), value: u32) !void {
    const num_str = try std.fmt.allocPrint(array.allocator, "{}", .{value});
    defer array.allocator.free(num_str);
    try array.appendSlice(num_str);
}

pub fn appendJsonFloat(array: *std.ArrayList(u8), value: f32) !void {
    const num_str = try std.fmt.allocPrint(array.allocator, "{d}", .{@as(f64, @floatCast(value))});
    defer array.allocator.free(num_str);
    try array.appendSlice(num_str);
}

// ---------------------------------------------------------------------------
// SessionConfig
// ---------------------------------------------------------------------------

pub const SessionConfig = struct {
    api_key: []const u8 = "",
    base_url: []const u8 = "",
    model: []const u8 = "",
    max_tokens: u32 = 4096,
    temperature: f32 = 0.7,
    api_mode: ApiMode = .chat_completions,
    timeout_ms: u32 = 60000,
    enable_logging: bool = false,
    log_dir: []const u8 = "logs",
    /// DeepSeek 思考模式开关
    enable_thinking: bool = false,
    /// DeepSeek 思考强度："high"/"max"
    reasoning_effort: []const u8 = "high",
};

// ---------------------------------------------------------------------------
// BaseSession Interface
// ---------------------------------------------------------------------------

pub const BaseSession = struct {
    vtable: *const VTable,
    data: *anyopaque,
    allocator: Allocator,

    pub const VTable = struct {
        complete: *const fn (*anyopaque, []const Message, ?[]const types.ToolDefinition, u32) anyerror!types.MockResponse,
        completeStream: *const fn (*anyopaque, []const Message, ?[]const types.ToolDefinition) anyerror!void,
        deinit: *const fn (*anyopaque, Allocator) void,
    };

    pub fn complete(self: *BaseSession, messages: []const Message, tools: ?[]const types.ToolDefinition, turn: u32) !types.MockResponse {
        return self.vtable.complete(self.data, messages, tools, turn);
    }

    pub fn completeStream(self: *BaseSession, messages: []const Message, tools: ?[]const types.ToolDefinition) !void {
        return self.vtable.completeStream(self.data, messages, tools);
    }

    pub fn deinit(self: *BaseSession) void {
        self.vtable.deinit(self.data, self.allocator);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Session 实现基类
// ---------------------------------------------------------------------------

const client_mod = @import("client.zig");
const LlmClient = client_mod.LlmClient;

pub const SessionImpl = struct {
    allocator: Allocator,
    client: LlmClient,
    config: SessionConfig,
};

pub fn createSessionImpl(allocator: Allocator, config: SessionConfig) SessionImpl {
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

pub fn destroySessionImpl(impl: *SessionImpl) void {
    impl.client.deinit();
}

// ---------------------------------------------------------------------------
// 具体会话实现导入
// ---------------------------------------------------------------------------

pub const ClaudeSession = @import("claude_session.zig").ClaudeSession;
pub const claude_vtable = @import("claude_session.zig").claude_vtable;

pub const OaiSession = @import("oai_session.zig").OaiSession;
pub const oai_vtable = @import("oai_session.zig").oai_vtable;

// ---------------------------------------------------------------------------
// Factory Function
// ---------------------------------------------------------------------------

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
