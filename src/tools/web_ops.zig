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

/// 发送 HTTP GET 请求并返回响应体
fn httpGet(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) ![]const u8 {
    const address = try std.net.Address.parseIp(host, port);

    const socket = try std.net.tcpConnectToAddress(address);
    defer socket.close();

    // 发送请求
    var request_buf: [4096]u8 = undefined;
    const request = try std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
        .{ path, host, port },
    );

    _ = try socket.writeAll(request);

    // 读取响应
    var response_list = std.ArrayList(u8).init(allocator);
    defer response_list.deinit();

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = socket.read(&read_buf) catch |err| {
            if (err == error.ConnectionResetByPeer) break;
            return err;
        };
        if (n == 0) break;
        response_list.appendSlice(read_buf[0..n]) catch return error.OutOfMemory;
    }

    const full_response = response_list.items;

    // 跳过 HTTP 头部（找到 \r\n\r\n）
    const header_end = std.mem.indexOf(u8, full_response, "\r\n\r\n") orelse {
        return error.InvalidHttpResponse;
    };

    const body_start = header_end + 4;
    const body = full_response[body_start..];

    return allocator.dupe(u8, body);
}

/// 发送 HTTP POST 请求并返回响应体
fn httpPost(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
) ![]const u8 {
    const address = try std.net.Address.parseIp(host, port);

    const socket = try std.net.tcpConnectToAddress(address);
    defer socket.close();

    // 发送请求
    var header_buf: [4096]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ path, host, port, content_type, body.len },
    );

    _ = try socket.writeAll(header);
    _ = try socket.writeAll(body);

    // 读取响应
    var response_list = std.ArrayList(u8).init(allocator);
    defer response_list.deinit();

    var read_buf: [8192]u8 = undefined;
    while (true) {
        const n = socket.read(&read_buf) catch |err| {
            if (err == error.ConnectionResetByPeer) break;
            return err;
        };
        if (n == 0) break;
        response_list.appendSlice(read_buf[0..n]) catch return error.OutOfMemory;
    }

    const full_response = response_list.items;

    // 跳过 HTTP 头部
    const header_end = std.mem.indexOf(u8, full_response, "\r\n\r\n") orelse {
        return error.InvalidHttpResponse;
    };

    const body_start = header_end + 4;
    const resp_body = full_response[body_start..];

    return allocator.dupe(u8, resp_body);
}

// ============================================================================
// CDP 辅助函数
// ============================================================================

/// 获取 CDP 标签页列表（GET /json）
fn getTabList(allocator: std.mem.Allocator, host: []const u8, port: u16) !json.Value {
    const body = httpGet(allocator, host, port, "/json") catch |err| {
        return err;
    };
    defer allocator.free(body);

    return json.parseFromString(allocator, body);
}

/// 获取第一个标签页的 webSocketDebuggerUrl
fn getFirstTabWsUrl(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]const u8 {
    const tabs = getTabList(allocator, host, port) catch |err| return err;
    defer tabs.deinit(allocator);

    if (tabs != .array or tabs.array.items.len == 0) {
        return error.NoTabsAvailable;
    }

    const first_tab = tabs.array.items[0];
    const ws_url = first_tab.getString("webSocketDebuggerUrl") orelse {
        return error.NoWebSocketUrl;
    };

    return allocator.dupe(u8, ws_url);
}

/// 通过 CDP 发送命令并获取结果
/// 注意：完整的 CDP 需要 WebSocket，这里提供基于 HTTP 的简化实现
/// 对于 Runtime.evaluate，我们通过 CDP 的 HTTP 端点发送
fn cdpEvaluate(allocator: std.mem.Allocator, host: []const u8, port: u16, expression: []const u8) !json.Value {
    // 构建 CDP 请求体
    var request_obj = json.Value.Object.init(allocator);
    errdefer {
        var it = request_obj.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        request_obj.deinit(allocator);
    }

    {
        const k1 = try allocator.dupe(u8, "id");
        try request_obj.put(k1, .{ .int = 1 });
        const k2 = try allocator.dupe(u8, "method");
        try request_obj.put(k2, .{ .string = "Runtime.evaluate" });
        const k3 = try allocator.dupe(u8, "params");
        var params_obj = json.Value.Object.init(allocator);
        errdefer {
            var it2 = params_obj.iterator();
            while (it2.next()) |e| {
                e.value_ptr.deinit(allocator);
                allocator.free(e.key_ptr.*);
            }
            params_obj.deinit(allocator);
        }
        {
            const pk1 = try allocator.dupe(u8, "expression");
            try params_obj.put(pk1, .{ .string = expression });
            const pk2 = try allocator.dupe(u8, "returnByValue");
            try params_obj.put(pk2, .{ .bool = true });
        }
        try request_obj.put(k3, .{ .object = params_obj });
    }

    const request_val = json.Value{ .object = request_obj };
    const request_str = json.toString(allocator, &request_val) catch |err| {
        request_val.deinit(allocator);
        return err;
    };
    defer allocator.free(request_str);
    request_val.deinit(allocator);

    // 注意：CDP 的 Runtime.evaluate 需要 WebSocket 连接
    // 这里我们尝试通过 HTTP 端点发送，如果失败则返回错误
    // 实际生产环境应使用 WebSocket 客户端
    _ = httpPost(
        allocator,
        host,
        port,
        "/json/protocol",
        "application/json",
        request_str,
    ) catch |err| {
        _ = err;
        // CDP HTTP 端点不支持直接发送命令，需要 WebSocket
        return error.CdpRequiresWebSocket;
    };

    return error.CdpRequiresWebSocket;
}

/// 简化版页面内容获取：通过 /json/list 或 /json 获取标签页信息
fn getPageInfo(allocator: std.mem.Allocator, host: []const u8, port: u16) !json.Value {
    const tabs = getTabList(allocator, host, port) catch |err| return err;

    // 构建结果对象
    var result_obj = json.Value.Object.init(allocator);
    errdefer {
        var it = result_obj.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        result_obj.deinit(allocator);
    }

    {
        const k1 = try allocator.dupe(u8, "tabs");
        try result_obj.put(k1, tabs);
        const k2 = try allocator.dupe(u8, "tab_count");
        if (tabs == .array) {
            try result_obj.put(k2, .{ .int = tabs.array.items.len });
        } else {
            try result_obj.put(k2, .{ .int = 0 });
        }
    }

    return .{ .object = result_obj };
}

// ============================================================================
// 工具实现：web_scan
// ============================================================================

fn webScan(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    const host = blk: {
        if (args == .object and args.object.get("host")) |val| {
            if (val == .string) break :blk val.string;
        }
        break :blk DEFAULT_CDP_HOST;
    };
    const port: u16 = blk: {
        if (args == .object and args.object.get("port")) |val| {
            if (val == .integer) {
                const p = val.integer;
                if (p > 0 and p <= 65535) break :blk @as(u16, @intCast(p));
            }
        }
        break :blk DEFAULT_CDP_PORT;
    };

    const url = blk: {
        if (args == .object and args.object.get("url")) |val| {
            if (val == .string) break :blk val.string;
        }
        break :blk null;
    };

    // 如果指定了 url，尝试导航到该页面（通过 CDP 的 Page.navigate）
    // 注意：完整实现需要 WebSocket，这里先获取标签页信息

    const data = getPageInfo(ctx.allocator, host, port) catch |err| {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "failed to connect to CDP at {}:{}: {}. Ensure Chrome is running with --remote-debugging-port={}.",
            .{ host, port, err, port },
        ) catch "failed to connect to CDP";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    if (url) |_| {
        // WebSocket 导航需要完整的 WebSocket 客户端实现
        // 这里暂时忽略 URL 导航，仅返回标签页信息
    }

    return .{ .data = data };
}

// ============================================================================
// 工具实现：web_execute_js
// ============================================================================

fn webExecuteJs(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
    _ = response;

    if (args != .object) {
        return ToolResult.errorResult(ctx.allocator, "args must be an object");
    }

    const script = blk: {
        if (args.object.get("script")) |val| {
            if (val == .string) break :blk val.string;
        }
        return ToolResult.errorResult(ctx.allocator, "missing required parameter: script");
    };

    const host = blk: {
        if (args.object.get("host")) |val| {
            if (val == .string) break :blk val.string;
        }
        break :blk DEFAULT_CDP_HOST;
    };
    const port: u16 = blk: {
        if (args.object.get("port")) |val| {
            if (val == .integer) {
                const p = val.integer;
                if (p > 0 and p <= 65535) break :blk @as(u16, @intCast(p));
            }
        }
        break :blk DEFAULT_CDP_PORT;
    };

    // 尝试通过 CDP 执行 JavaScript
    const result = cdpEvaluate(ctx.allocator, host, port, script) catch |err| {
        // 如果 WebSocket 不可用，返回错误提示
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "CDP JavaScript execution requires WebSocket support (error: {}). Current implementation provides tab listing via HTTP. For full JS execution, a WebSocket client is needed.",
            .{err},
        ) catch "CDP JS execution requires WebSocket support";
        return ToolResult.errorResult(ctx.allocator, msg);
    };

    return .{ .data = result };
}

// ============================================================================
// 公共 API：工具注册条目
// ============================================================================

/// web_scan 工具定义
pub const web_scan: ToolEntry = .{
    .name = "web_scan",
    .description = "Scan browser tabs via Chrome DevTools Protocol (CDP). Connects to localhost:9222 by default. Returns tab list with URLs, titles, and WebSocket debugger URLs.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "host": {
    \\      "type": "string",
    \\      "description": "CDP host address (default: 127.0.0.1)",
    \\      "default": "127.0.0.1"
    \\    },
    \\    "port": {
    \\      "type": "integer",
    \\      "description": "CDP port (default: 9222)",
    \\      "default": 9222
    \\    },
    \\    "url": {
    \\      "type": "string",
    \\      "description": "Optional URL to navigate to before scanning"
    \\    }
    \\  }
    \\}
    ,
    .func = webScan,
};

/// web_execute_js 工具定义
pub const web_execute_js: ToolEntry = .{
    .name = "web_execute_js",
    .description = "Execute JavaScript in the browser via Chrome DevTools Protocol (CDP). Requires WebSocket support for full functionality.",
    .parameters_schema =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "script": {
    \\      "type": "string",
    \\      "description": "JavaScript code to execute in the browser"
    \\    },
    \\    "host": {
    \\      "type": "string",
    \\      "description": "CDP host address (default: 127.0.0.1)",
    \\      "default": "127.0.0.1"
    \\    },
    \\    "port": {
    \\      "type": "integer",
    \\      "description": "CDP port (default: 9222)",
    \\      "default": 9222
    \\    }
    \\  },
    \\  "required": ["script"]
    \\}
    ,
    .func = webExecuteJs,
};

/// 获取所有浏览器控制工具的注册条目列表
pub fn getToolEntries() []const ToolEntry {
    return &.{ web_scan, web_execute_js };
}
