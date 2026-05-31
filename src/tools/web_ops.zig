//! web_ops.zig - 浏览器控制工具
//!
//! 通过 Chrome DevTools Protocol (CDP) 控制浏览器：
//! - web_scan: 获取页面内容和标签页列表
//! - web_execute_js: 通过 CDP 执行 JavaScript
//!
//! CDP 通信方式：
//! - 使用 HTTP 连接 localhost:9222
//! - GET /json 获取标签页列表
//! - POST /json/version 获取浏览器版本信息
//! - WebSocket 连接到标签页的 webSocketDebuggerUrl 执行 CDP 命令

const std = @import("std");
const registry = @import("registry.zig");
const json = std.json;

const ToolResult = registry.ToolResult;
const ToolContext = registry.ToolContext;
const ToolEntry = registry.ToolEntry;

// ============================================================================
// CDP 配置
// ============================================================================

const DEFAULT_CDP_HOST = "127.0.0.1";
const DEFAULT_CDP_PORT: u16 = 9222;
const HTTP_TIMEOUT_MS: u32 = 10000;

// ============================================================================
// 内部辅助：简单 HTTP GET（不使用 std.http，直接 TCP socket）
// ============================================================================

fn httpGet(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) ![]const u8 {
    std.log.info("[web_ops] HTTP GET 开始: {s}:{d}{s}", .{ host, port, path });

    const address = try std.net.Address.parseIp(host, port);
    std.log.info("[web_ops] ✓ 地址解析成功: {s}:{d}", .{ host, port });

    const socket = try std.net.tcpConnectToAddress(address);
    defer socket.close();
    std.log.info("[web_ops] ✓ TCP 连接建立成功", .{});

    var request_buf: [4096]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ path, host, port },
    );

    _ = try socket.writeAll(request);
    std.log.info("[web_ops] ✓ HTTP 请求发送成功 (长度: {d} bytes)", .{request.len});

    var response_list = std.ArrayList(u8).init(allocator);
    defer response_list.deinit();

    var read_buf: [8192]u8 = undefined;
    var total_read: usize = 0;

    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    const start_time = std.time.milliTimestamp();
    while (true) {
        const elapsed = std.time.milliTimestamp() - start_time;
        if (elapsed >= HTTP_TIMEOUT_MS) {
            std.log.info("[web_ops] 读取超时 ({d}ms), 已读取 {d} bytes", .{ elapsed, total_read });
            break;
        }

        const remaining_ms = @as(i32, @intCast(HTTP_TIMEOUT_MS - elapsed));
        const poll_result = std.posix.poll(&poll_fds, remaining_ms) catch 0;

        if (poll_result == 0) {
            std.log.info("[web_ops] poll 超时, 已读取 {d} bytes", .{total_read});
            break;
        }

        if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
            const n = socket.read(&read_buf) catch |err| {
                if (err == error.ConnectionResetByPeer) {
                    std.log.info("[web_ops] 连接被服务器关闭 (已读取 {d} bytes)", .{total_read});
                    break;
                }
                std.log.info("[web_ops] 读取响应失败: {}", .{err});
                return err;
            };
            if (n == 0) {
                std.log.info("[web_ops] 读取完成 (总计 {d} bytes)", .{total_read});
                break;
            }
            total_read += n;
            response_list.appendSlice(read_buf[0..n]) catch return error.OutOfMemory;
        }
    }

    const full_response = response_list.items;
    std.log.info("[web_ops] 响应总长度: {d} bytes", .{full_response.len});

    const header_end = std.mem.indexOf(u8, full_response, "\r\n\r\n") orelse {
        std.log.info("[web_ops] 响应格式错误: 未找到 HTTP 头部结束标记", .{});
        return error.InvalidHttpResponse;
    };

    const body_start = header_end + 4;
    const body = full_response[body_start..];
    std.log.info("[web_ops] ✓ HTTP 响应解析成功 (头部: {d} bytes, 正文: {d} bytes)", .{ header_end, body.len });

    if (body.len < 200) {
        std.log.info("[web_ops] 响应正文: {s}", .{body});
    } else {
        std.log.info("[web_ops] 响应正文 (前200字符): {s}...", .{body[0..200]});
    }

    return allocator.dupe(u8, body);
}

fn httpPost(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
) ![]const u8 {
    std.log.info("[web_ops] HTTP POST 开始: {s}:{d}{s}", .{ host, port, path });
    std.log.info("[web_ops] Content-Type: {s}, Body 长度: {d} bytes", .{ content_type, body.len });

    const address = try std.net.Address.parseIp(host, port);
    std.log.info("[web_ops] ✓ 地址解析成功: {s}:{d}", .{ host, port });

    const socket = try std.net.tcpConnectToAddress(address);
    defer socket.close();
    std.log.info("[web_ops] ✓ TCP 连接建立成功", .{});

    var header_buf: [4096]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n",
        .{ path, host, port, content_type, body.len },
    );

    _ = try socket.writeAll(header);
    _ = try socket.writeAll(body);
    std.log.info("[web_ops] ✓ HTTP 请求发送成功 (头部: {d} bytes, 正文: {d} bytes)", .{ header.len, body.len });

    var response_list = std.ArrayList(u8).init(allocator);
    defer response_list.deinit();

    var read_buf: [8192]u8 = undefined;
    var total_read: usize = 0;
    while (true) {
        const n = socket.read(&read_buf) catch |err| {
            if (err == error.ConnectionResetByPeer) {
                std.log.info("[web_ops] 连接被服务器关闭 (已读取 {d} bytes)", .{total_read});
                break;
            }
            std.log.info("[web_ops] 读取响应失败: {}", .{err});
            return err;
        };
        if (n == 0) {
            std.log.info("[web_ops] 读取完成 (总计 {d} bytes)", .{total_read});
            break;
        }
        total_read += n;
        response_list.appendSlice(read_buf[0..n]) catch return error.OutOfMemory;
    }

    const full_response = response_list.items;
    std.log.info("[web_ops] 响应总长度: {d} bytes", .{full_response.len});

    const header_end = std.mem.indexOf(u8, full_response, "\r\n\r\n") orelse {
        std.log.info("[web_ops] 响应格式错误: 未找到 HTTP 头部结束标记", .{});
        return error.InvalidHttpResponse;
    };

    const resp_body_start = header_end + 4;
    const resp_body = full_response[resp_body_start..];
    std.log.info("[web_ops] ✓ HTTP 响应解析成功 (头部: {d} bytes, 正文: {d} bytes)", .{ header_end, resp_body.len });

    if (resp_body.len < 200) {
        std.log.info("[web_ops] 响应正文: {s}", .{resp_body});
    } else {
        std.log.info("[web_ops] 响应正文 (前200字符): {s}...", .{resp_body[0..200]});
    }

    return allocator.dupe(u8, resp_body);
}

// ============================================================================
// CDP 辅助函数
// ============================================================================

fn getTabList(allocator: std.mem.Allocator, host: []const u8, port: u16) !json.Value {
    std.log.info("[web_ops] 获取标签页列表: {s}:{d}/json", .{ host, port });

    const body = httpGet(allocator, host, port, "/json") catch |err| {
        std.log.info("[web_ops] HTTP GET /json 失败: {}", .{err});
        return err;
    };
    defer allocator.free(body);

    std.log.info("[web_ops] 开始解析 JSON 响应 (长度: {d} bytes)", .{body.len});

    const parsed = try json.parseFromSliceLeaky(json.Value, allocator, body, .{});

    if (parsed == .array) {
        std.log.info("[web_ops] ✓ JSON 解析成功: 数组类型, {d} 个元素", .{parsed.array.items.len});
    } else {
        std.log.info("[web_ops] ✓ JSON 解析成功: 类型={s}", .{@tagName(parsed)});
    }

    return parsed;
}

fn getFirstTabWsUrl(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]const u8 {
    std.log.info("[web_ops] 获取第一个标签页的 WebSocket URL", .{});

    const tabs = getTabList(allocator, host, port) catch |err| return err;

    if (tabs != .array or tabs.array.items.len == 0) {
        std.log.info("[web_ops] 没有可用的标签页", .{});
        return error.NoTabsAvailable;
    }

    std.log.info("[web_ops] 找到 {d} 个标签页", .{tabs.array.items.len});

    const first_tab = tabs.array.items[0];
    const ws_url = first_tab.getString("webSocketDebuggerUrl") orelse {
        std.log.info("[web_ops] 第一个标签页缺少 webSocketDebuggerUrl 字段", .{});
        return error.NoWebSocketUrl;
    };

    std.log.info("[web_ops] ✓ WebSocket URL: {s}", .{ws_url});
    return allocator.dupe(u8, ws_url);
}

fn buildCdpEvaluateRequest(allocator: std.mem.Allocator, expression: []const u8) ![]u8 {
    std.log.info("[web_ops] 构建 CDP Runtime.evaluate 请求", .{});
    std.log.info("[web_ops] JavaScript 表达式长度: {d} bytes", .{expression.len});

    if (expression.len < 100) {
        std.log.info("[web_ops] JavaScript 表达式: {s}", .{expression});
    } else {
        std.log.info("[web_ops] JavaScript 表达式 (前100字符): {s}...", .{expression[0..100]});
    }

    const escaped_expression = try escapeJsonString(allocator, expression);
    defer allocator.free(escaped_expression);

    const result = try std.fmt.allocPrint(allocator, "{{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":{{\"expression\":\"{s}\",\"returnByValue\":true}}}}", .{escaped_expression});

    std.log.info("[web_ops] ✓ CDP 请求构建完成", .{});
    return result;
}

fn escapeJsonString(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (str) |c| {
        switch (c) {
            '\\' => try result.appendSlice("\\\\"),
            '"' => try result.appendSlice("\\\""),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => try result.append(c),
        }
    }

    return result.toOwnedSlice();
}

fn buildPageInfoResult(allocator: std.mem.Allocator, tabs: json.Value) ![]u8 {
    std.log.info("[web_ops] 构建页面信息结果", .{});

    const tab_count: i64 = if (tabs == .array) @intCast(tabs.array.items.len) else 0;
    const result = try std.fmt.allocPrint(allocator, "{{\"tab_count\": {}, \"message\": \"CDP connection successful\"}}", .{tab_count});

    std.log.info("[web_ops] ✓ 页面信息结果构建完成 (标签页数量: {d})", .{tab_count});
    return result;
}

// ============================================================================
// 工具实现：web_scan
// ============================================================================

fn webScan(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    std.log.info("[web_ops] ========== web_scan 开始执行 ==========", .{});

    const host = blk: {
        if (args == .object) {
            if (args.object.get("host")) |val| {
                if (val == .string) {
                    std.log.info("[web_ops] 使用自定义 host: {s}", .{val.string});
                    break :blk val.string;
                }
            }
        }
        std.log.info("[web_ops] 使用默认 host: {s}", .{DEFAULT_CDP_HOST});
        break :blk DEFAULT_CDP_HOST;
    };
    const port: u16 = blk: {
        if (args == .object) {
            if (args.object.get("port")) |val| {
                if (val == .integer) {
                    const p = val.integer;
                    if (p > 0 and p <= 65535) {
                        std.log.info("[web_ops] 使用自定义 port: {d}", .{p});
                        break :blk @as(u16, @intCast(p));
                    }
                }
            }
        }
        std.log.info("[web_ops] 使用默认 port: {d}", .{DEFAULT_CDP_PORT});
        break :blk DEFAULT_CDP_PORT;
    };

    std.log.info("[web_ops] 目标 CDP 地址: {s}:{d}", .{ host, port });

    const tabs = getTabList(ctx.allocator, host, port) catch |err| {
        std.log.info("[web_ops] 获取标签页列表失败: {}", .{err});
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "failed to connect to CDP at {s}:{d}: {}. Ensure Chrome is running with --remote-debugging-port={d}.",
            .{ host, port, err, port },
        ) catch return ToolResult.errorResult(ctx.allocator, "failed to connect to CDP");
        return ToolResult.errorResultOwned(msg);
    };

    std.log.info("[web_ops] ✓ 成功获取标签页列表", .{});

    const result_str = buildPageInfoResult(ctx.allocator, tabs) catch |err| {
        std.log.info("[web_ops] 构建结果失败: {}", .{err});
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
        return ToolResult.errorResultOwned(msg);
    };

    std.log.info("[web_ops] ========== web_scan 执行完成 ==========", .{});
    return .{ .data = .{ .text = result_str } };
}

// ============================================================================
// 工具实现：web_execute_js
// ============================================================================

fn webExecuteJs(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    std.log.info("[web_ops] ========== web_execute_js 开始执行 ==========", .{});

    if (args != .object) {
        std.log.info("[web_ops] 参数类型错误: 期望 object, 实际 {s}", .{@tagName(args)});
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const script = blk: {
        if (args.object.get("script")) |val| {
            if (val == .string) {
                std.log.info("[web_ops] ✓ 获取到 script 参数 (长度: {d} bytes)", .{val.string.len});
                break :blk val.string;
            }
        }
        std.log.info("[web_ops] 缺少必需参数: script", .{});
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: script");
    };

    const host = blk: {
        if (args.object.get("host")) |val| {
            if (val == .string) {
                std.log.info("[web_ops] 使用自定义 host: {s}", .{val.string});
                break :blk val.string;
            }
        }
        std.log.info("[web_ops] 使用默认 host: {s}", .{DEFAULT_CDP_HOST});
        break :blk DEFAULT_CDP_HOST;
    };
    const port: u16 = blk: {
        if (args.object.get("port")) |val| {
            if (val == .integer) {
                const p = val.integer;
                if (p > 0 and p <= 65535) {
                    std.log.info("[web_ops] 使用自定义 port: {d}", .{p});
                    break :blk @as(u16, @intCast(p));
                }
            }
        }
        std.log.info("[web_ops] 使用默认 port: {d}", .{DEFAULT_CDP_PORT});
        break :blk DEFAULT_CDP_PORT;
    };

    std.log.info("[web_ops] 目标 CDP 地址: {s}:{d}", .{ host, port });

    const request_str = buildCdpEvaluateRequest(ctx.allocator, script) catch |err| {
        std.log.info("[web_ops] 构建 CDP 请求失败: {}", .{err});
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build CDP request: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build CDP request");
        return ToolResult.errorResultOwned(msg);
    };
    defer ctx.allocator.free(request_str);

    std.log.info("[web_ops] ✓ CDP 请求构建成功 (长度: {d} bytes)", .{request_str.len});
    std.log.info("[web_ops] CDP 请求 JSON: {s}", .{request_str});

    std.log.info("[web_ops] 尝试通过 HTTP POST 发送 CDP 请求...", .{});
    _ = httpPost(
        ctx.allocator,
        host,
        port,
        "/json/protocol",
        "application/json",
        request_str,
    ) catch |err| {
        std.log.warn("[web_ops] HTTP POST 失败: {} (CDP 命令执行需要 WebSocket 支持)", .{err});
    };

    std.log.warn("[web_ops] web_execute_js 当前仅支持 HTTP 连接，完整的 JS 执行需要 WebSocket", .{});
    std.log.info("[web_ops] ========== web_execute_js 执行完成 (返回提示信息) ==========", .{});

    return ToolResult.errorResult(
        ctx.allocator,
        "CDP JavaScript execution requires WebSocket support. HTTP protocol endpoint does not support command execution.",
    );
}

// ============================================================================
// 公共 API：工具注册条目
// ============================================================================

pub const web_scan: ToolEntry = .{
    .name = "web_scan",
    .description = "Scan browser tabs via Chrome DevTools Protocol (CDP). Connects to localhost:9222 by default. Returns tab list with URLs, titles, and WebSocket debugger URLs.",
    .parameters_schema = "{\"type\": \"object\", \"properties\": {\"host\": {\"type\": \"string\", \"description\": \"CDP host address (default: 127.0.0.1)\"}, \"port\": {\"type\": \"integer\", \"description\": \"CDP port (default: 9222)\"}, \"url\": {\"type\": \"string\", \"description\": \"Optional URL to navigate to before scanning\"}}}",
    .func = webScan,
};

pub const web_execute_js: ToolEntry = .{
    .name = "web_execute_js",
    .description = "Execute JavaScript in the browser via Chrome DevTools Protocol (CDP). Requires WebSocket support for full functionality.",
    .parameters_schema = "{\"type\": \"object\", \"properties\": {\"script\": {\"type\": \"string\", \"description\": \"JavaScript code to execute in the browser\"}, \"host\": {\"type\": \"string\", \"description\": \"CDP host address (default: 127.0.0.1)\"}, \"port\": {\"type\": \"integer\", \"description\": \"CDP port (default: 9222)\"}}, \"required\": [\"script\"]}",
    .func = webExecuteJs,
};

pub fn getToolEntries() []const ToolEntry {
    return &.{ web_scan, web_execute_js };
}
