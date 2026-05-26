//! src/llm/client.zig - LLM HTTP 客户端
//!
//! 基于 std.http 的 HTTP POST 客户端，支持：
//! - SSE 流式响应解析
//! - 自动重试（指数退避）
//! - 超时控制
//! - 自定义请求头

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = std.http;
const json = std.json;

// ---------------------------------------------------------------------------
// ClientConfig
// ---------------------------------------------------------------------------

/// HTTP 客户端配置
pub const ClientConfig = struct {
    /// 最大重试次数（默认 3）
    max_retries: u32 = 3,
    /// 基础延迟（毫秒，默认 1000）
    base_delay_ms: u32 = 1000,
    /// 连接超时（毫秒，默认 30000）
    connect_timeout_ms: u32 = 30000,
    /// 读取超时（毫秒，默认 120000）
    read_timeout_ms: u32 = 120000,
    /// 代理地址（可选）
    proxy: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// RequestHeader
// ---------------------------------------------------------------------------

/// 请求头构建器
pub const RequestHeaders = struct {
    authorization: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    accept: []const u8 = "application/json",
    /// 额外自定义头
    extra: ?[]const HeaderEntry = null,

    pub const HeaderEntry = struct {
        name: []const u8,
        value: []const u8,
    };
};

// ---------------------------------------------------------------------------
// SSE event
// ---------------------------------------------------------------------------

/// SSE 事件
pub const SseEvent = struct {
    event: []const u8 = "",
    data: []const u8 = "",
    done: bool = false,
};

// ---------------------------------------------------------------------------
// ResponseResult
// ---------------------------------------------------------------------------

/// HTTP 响应结果
pub const ResponseResult = struct {
    status_code: u16,
    body: []const u8,
    /// 是否为流式响应
    streaming: bool = false,

    pub fn isSuccess(self: ResponseResult) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }
};

// ---------------------------------------------------------------------------
// LlmError
// ---------------------------------------------------------------------------

/// LLM 客户端错误
pub const LlmError = error{
    ConnectionFailed,
    Timeout,
    HttpError,
    InvalidResponse,
    RateLimited,
    ServerError,
    AuthFailed,
    StreamError,
    JsonParseError,
    RetryExhausted,
    RequestBodyTooLarge,
    AllocationFailed,
};

// ---------------------------------------------------------------------------
// LlmClient
// ---------------------------------------------------------------------------

/// LLM HTTP 客户端
pub const LlmClient = struct {
    allocator: Allocator,
    config: ClientConfig,

    pub fn init(allocator: Allocator, config: ClientConfig) LlmClient {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *LlmClient) void {
        _ = self;
    }

    // -----------------------------------------------------------------------
    // POST 请求（非流式）
    // -----------------------------------------------------------------------

    /// 发送 HTTP POST 请求并返回完整响应体
    pub fn post(
        self: *LlmClient,
        url: []const u8,
        headers: RequestHeaders,
        body: []const u8,
    ) LlmError!ResponseResult {
        var attempt: u32 = 0;
        var last_error: ?LlmError = null;

        while (attempt <= self.config.max_retries) : (attempt += 1) {
            if (attempt > 0) {
                const delay = self.calculateBackoff(attempt);
                std.time.sleep(@as(u64, delay) * std.time.ns_per_ms);
            }

            const result = self.doPost(url, headers, body) catch |err| {
                last_error = err;
                // 不可重试的错误直接返回
                if (!self.isRetryable(err)) return err;
                continue;
            };

            // 429 / 5xx 可重试
            if (result.status_code == 429) {
                last_error = LlmError.RateLimited;
                continue;
            }
            if (result.status_code >= 500) {
                last_error = LlmError.ServerError;
                continue;
            }
            // 401/403 不可重试
            if (result.status_code == 401 or result.status_code == 403) {
                return LlmError.AuthFailed;
            }

            return result;
        }

        return last_error orelse LlmError.RetryExhausted;
    }

    // -----------------------------------------------------------------------
    // POST 请求（SSE 流式）
    // -----------------------------------------------------------------------

    /// 发送 HTTP POST 请求，通过回调逐块返回 SSE 事件
    pub fn postStream(
        self: *LlmClient,
        url: []const u8,
        headers: RequestHeaders,
        body: []const u8,
        ctx: *anyopaque,
        onEventFn: *const fn (*anyopaque, SseEvent) anyerror!void,
    ) LlmError!void {
        var stream_headers = headers;
        stream_headers.accept = "text/event-stream";

        var attempt: u32 = 0;
        var last_error: ?LlmError = null;

        while (attempt <= self.config.max_retries) : (attempt += 1) {
            if (attempt > 0) {
                const delay = self.calculateBackoff(attempt);
                std.time.sleep(@as(u64, delay) * std.time.ns_per_ms);
            }

            self.doPostStream(url, stream_headers, body, ctx, onEventFn) catch |err| {
                last_error = err;
                if (!self.isRetryable(err)) return err;
                continue;
            };

            return;
        }

        return last_error orelse LlmError.RetryExhausted;
    }

    // -----------------------------------------------------------------------
    // 内部实现
    // -----------------------------------------------------------------------

    fn doPost(
        self: *LlmClient,
        url: []const u8,
        headers: RequestHeaders,
        body: []const u8,
    ) LlmError!ResponseResult {
        // 解析 URL
        const parsed = std.Uri.parse(url) catch return LlmError.ConnectionFailed;

        // 构建 HTTP 请求
        var req_buf: [16 * 1024]u8 = undefined;
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // 构建 extra_headers 列表
        var extra_headers_list = std.ArrayList(http.Header).init(self.allocator);
        defer extra_headers_list.deinit();

        extra_headers_list.append(.{ .name = "Content-Type", .value = headers.content_type }) catch
            return LlmError.AllocationFailed;
        extra_headers_list.append(.{ .name = "Accept", .value = headers.accept }) catch
            return LlmError.AllocationFailed;

        if (headers.authorization) |auth| {
            extra_headers_list.append(.{ .name = "Authorization", .value = auth }) catch
                return LlmError.AllocationFailed;
        }

        if (headers.extra) |extras| {
            for (extras) |entry| {
                extra_headers_list.append(.{ .name = entry.name, .value = entry.value }) catch
                    return LlmError.AllocationFailed;
            }
        }

        var result = client.open(.POST, parsed, .{
            .server_header_buffer = &req_buf,
            .extra_headers = extra_headers_list.items,
            .redirect_behavior = .not_allowed,
        }) catch return LlmError.ConnectionFailed;
        defer result.deinit();

        result.transfer_encoding = .{ .content_length = body.len };

        // 发送请求头
        result.send() catch return LlmError.ConnectionFailed;

        // 发送请求体
        result.finish() catch return LlmError.ConnectionFailed;
        _ = result.writeAll(body) catch return LlmError.ConnectionFailed;

        // 等待响应
        result.wait() catch return LlmError.ConnectionFailed;

        const status = @intFromEnum(result.response.status);
        if (status == 401 or status == 403) return LlmError.AuthFailed;
        if (status == 429) return LlmError.RateLimited;
        if (status >= 500) return LlmError.ServerError;
        if (status < 200 or status >= 300) return LlmError.HttpError;

        // 读取响应体
        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = result.read(&read_buf) catch return LlmError.InvalidResponse;
            if (n == 0) break;
            response_body.appendSlice(read_buf[0..n]) catch
                return LlmError.AllocationFailed;
        }

        return .{
            .status_code = @intCast(status),
            .body = response_body.items,
            .streaming = false,
        };
    }

    fn doPostStream(
        self: *LlmClient,
        url: []const u8,
        headers: RequestHeaders,
        body: []const u8,
        ctx: *anyopaque,
        onEventFn: *const fn (*anyopaque, SseEvent) anyerror!void,
    ) LlmError!void {
        const parsed = std.Uri.parse(url) catch return LlmError.ConnectionFailed;

        var req_buf: [16 * 1024]u8 = undefined;
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // 构建 extra_headers 列表
        var extra_headers_list = std.ArrayList(http.Header).init(self.allocator);
        defer extra_headers_list.deinit();

        extra_headers_list.append(.{ .name = "Content-Type", .value = headers.content_type }) catch
            return LlmError.AllocationFailed;
        extra_headers_list.append(.{ .name = "Accept", .value = headers.accept }) catch
            return LlmError.AllocationFailed;

        if (headers.authorization) |auth| {
            extra_headers_list.append(.{ .name = "Authorization", .value = auth }) catch
                return LlmError.AllocationFailed;
        }

        if (headers.extra) |extras| {
            for (extras) |entry| {
                extra_headers_list.append(.{ .name = entry.name, .value = entry.value }) catch
                    return LlmError.AllocationFailed;
            }
        }

        var result = client.open(.POST, parsed, .{
            .server_header_buffer = &req_buf,
            .extra_headers = extra_headers_list.items,
            .redirect_behavior = .not_allowed,
        }) catch return LlmError.ConnectionFailed;
        defer result.deinit();

        result.transfer_encoding = .{ .content_length = body.len };
        result.send() catch return LlmError.ConnectionFailed;
        result.finish() catch return LlmError.ConnectionFailed;
        _ = result.writeAll(body) catch return LlmError.ConnectionFailed;

        result.wait() catch return LlmError.ConnectionFailed;

        const status = @intFromEnum(result.response.status);
        if (status == 401 or status == 403) return LlmError.AuthFailed;
        if (status == 429) return LlmError.RateLimited;
        if (status >= 500) return LlmError.ServerError;
        if (status < 200 or status >= 300) return LlmError.HttpError;

        // 逐块读取并解析 SSE
        var sse_parser = SseParser.init(self.allocator);
        defer sse_parser.deinit();

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = result.read(&read_buf) catch return LlmError.StreamError;
            if (n == 0) break;

            sse_parser.feed(read_buf[0..n]);
            while (sse_parser.next()) |event| {
                onEventFn(ctx, event) catch return LlmError.StreamError;
                if (event.done) return;
            }
        }

        // 处理剩余缓冲区
        sse_parser.finish();
        while (sse_parser.next()) |event| {
            onEventFn(ctx, event) catch return LlmError.StreamError;
            if (event.done) return;
        }
    }

    // -----------------------------------------------------------------------
    // 工具方法
    // -----------------------------------------------------------------------

    fn calculateBackoff(self: *LlmClient, attempt: u32) u32 {
        // 指数退避 + 抖动
        const base: u32 = self.config.base_delay_ms;
        const multiplier = std.math.pow(u32, 2, attempt - 1);
        const delay = base * multiplier;
        // 添加 +/- 25% 的随机抖动
        const jitter = delay / 4;
        const rand_jitter = if (jitter > 0)
            std.crypto.random.intRangeAtMost(u32, 0, jitter)
        else
            0;
        return delay +| rand_jitter;
    }

    fn isRetryable(self: *LlmClient, err: LlmError) bool {
        _ = self;
        return switch (err) {
            error.ConnectionFailed, error.Timeout, error.RateLimited, error.ServerError => true,
            else => false,
        };
    }
};

// ---------------------------------------------------------------------------
// SseParser
// ---------------------------------------------------------------------------

/// SSE (Server-Sent Events) 流解析器
pub const SseParser = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    event_type: std.ArrayList(u8),
    data_buf: std.ArrayList(u8),
    /// 已解析完成的事件队列
    events: std.ArrayList(SseEvent),

    pub fn init(allocator: Allocator) SseParser {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .event_type = std.ArrayList(u8).init(allocator),
            .data_buf = std.ArrayList(u8).init(allocator),
            .events = std.ArrayList(SseEvent).init(allocator),
        };
    }

    pub fn deinit(self: *SseParser) void {
        self.buffer.deinit();
        self.event_type.deinit();
        self.data_buf.deinit();
        for (self.events.items) |*e| {
            if (e.data.len > 0 and !std.mem.eql(u8, e.data, "[DONE]")) {
                // data 指向 buffer，不需要单独释放
            }
        }
        self.events.deinit();
    }

    /// 喂入新数据
    pub fn feed(self: *SseParser, chunk: []const u8) void {
        self.buffer.appendSlice(chunk) catch {};
        self.processBuffer();
    }

    /// 标记流结束，处理剩余数据
    pub fn finish(self: *SseParser) void {
        self.processBuffer();
        // 如果还有未处理的数据，作为最后一个事件
        if (self.data_buf.items.len > 0) {
            self.emitEvent();
        }
    }

    /// 取下一个已解析的事件
    pub fn next(self: *SseParser) ?SseEvent {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn processBuffer(self: *SseParser) void {
        while (true) {
            const idx = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse break;
            const line = self.buffer.items[0..idx];
            // 移除 \r
            const trimmed = std.mem.trimRight(u8, line, "\r");

            // 移除已处理的行
            self.buffer.replaceRangeAssumeCapacity(0, idx + 1, &.{});

            if (trimmed.len == 0) {
                // 空行 = 事件分隔符
                if (self.data_buf.items.len > 0) {
                    self.emitEvent();
                }
                continue;
            }

            // 解析 SSE 字段
            if (std.mem.startsWith(u8, trimmed, "event:")) {
                const val = std.mem.trim(u8, trimmed["event:".len..], " ");
                self.event_type.clearRetainingCapacity();
                self.event_type.appendSlice(val) catch {};
            } else if (std.mem.startsWith(u8, trimmed, "data:")) {
                const val = std.mem.trim(u8, trimmed["data:".len..], " ");
                if (self.data_buf.items.len > 0) {
                    self.data_buf.append('\n') catch {};
                }
                self.data_buf.appendSlice(val) catch {};
            } else if (std.mem.startsWith(u8, trimmed, ":")) {
                // 注释行，忽略
            } else if (std.mem.startsWith(u8, trimmed, "id:") or
                std.mem.startsWith(u8, trimmed, "retry:"))
            {
                // id 和 retry 暂不处理
            }
        }
    }

    fn emitEvent(self: *SseParser) void {
        const data = self.allocator.dupe(u8, self.data_buf.items) catch "";
        const event_type = self.allocator.dupe(u8, self.event_type.items) catch "";

        const done = std.mem.eql(u8, data, "[DONE]");

        self.events.append(.{
            .event = event_type,
            .data = data,
            .done = done,
        }) catch {};

        self.data_buf.clearRetainingCapacity();
        self.event_type.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// 辅助函数
// ---------------------------------------------------------------------------

/// 构建 Authorization 头值
pub fn buildAuthorization(api_key: []const u8, allocator: Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
}

/// 构建 Anthropic x-api-key 头值（Anthropic 使用不同格式）
pub fn buildAnthropicAuth(api_key: []const u8, allocator: Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
}

/// 构建 Anthropic 版本头
pub fn anthropicVersionHeader(allocator: Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "anthropic-version: 2023-06-01", .{});
}
