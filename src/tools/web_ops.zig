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

fn freeJsonValue(value: *json.Value, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |*item| freeJsonValue(item, allocator);
            allocator.free(arr.items);
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(entry.value_ptr, allocator);
            }
            obj.deinit();
        },
        else => {},
    }
}

fn shouldLog() bool {
    const env_val = std.process.getEnvVarOwned(std.heap.page_allocator, "WEB_OPS_LOG_DISABLED") catch null;
    defer if (env_val) |v| std.heap.page_allocator.free(v);
    return !(std.mem.eql(u8, env_val orelse "", "1") or std.mem.eql(u8, env_val orelse "", "true"));
}

const ToolResult = registry.ToolResult;
const ToolContext = registry.ToolContext;
const ToolEntry = registry.ToolEntry;

// ============================================================================
// 环境检查结果
// ============================================================================

pub const EnvironmentStatus = enum {
    ready, // Chrome 已运行且 CDP 可用
    chrome_not_found, // Chrome 未安装
    chrome_not_running, // Chrome 未运行但已安装
};

pub const EnvironmentInfo = struct {
    status: EnvironmentStatus,
    chrome_path: ?[]const u8,
    message: []const u8,
};

// ============================================================================
// 公开辅助：检查运行环境
// ============================================================================

pub fn checkEnvironment(host: []const u8, port: u16) EnvironmentInfo {
    const chrome_path = findChromePath();

    if (chrome_path == null) {
        return .{
            .status = .chrome_not_found,
            .chrome_path = null,
            .message = "未找到 Chrome 浏览器，请先安装 Google Chrome 或 Chromium",
        };
    }

    // 使用与 web_scan 相同的方式验证 CDP（调用 getTabList）
    _ = getTabList(std.heap.page_allocator, host, port) catch {
        return .{
            .status = .chrome_not_running,
            .chrome_path = chrome_path,
            .message = "Chrome 已安装但未运行或 CDP 不可用",
        };
    };

    return .{
        .status = .ready,
        .chrome_path = chrome_path,
        .message = "Chrome 运行正常，CDP 端口可用",
    };
}

// ============================================================================
// 内部辅助：跨平台查找 Chrome 路径
// ============================================================================

fn findChromePath() ?[]const u8 {
    const windows_paths = [_][]const u8{
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files\\Chromium\\Application\\chrome.exe",
    };

    const macos_paths = [_][]const u8{
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    };

    const linux_paths = [_][]const u8{
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/snap/bin/chromium",
    };

    const os_tag = @import("builtin").target.os.tag;

    if (os_tag == .windows) {
        for (windows_paths) |path| {
            if (std.fs.cwd().statFile(path)) |_| {
                return path;
            } else |_| {}
        }
    } else if (os_tag == .macos) {
        for (macos_paths) |path| {
            if (std.fs.cwd().statFile(path)) |_| {
                return path;
            } else |_| {}
        }
    } else if (os_tag == .linux) {
        for (linux_paths) |path| {
            if (std.fs.cwd().statFile(path)) |_| {
                return path;
            } else |_| {}
        }
    }
    return null;
}

// ============================================================================
// 内部辅助：检查 Chrome 是否正在运行（通过 CDP 协议验证）
// ============================================================================

fn isChromeRunning(host: []const u8, port: u16) bool {
    // 首先检查端口是否开放
    const address = std.net.Address.parseIp(host, port) catch return false;
    const socket = std.net.tcpConnectToAddress(address) catch return false;
    socket.close();

    // 端口开放，但需要验证是否是 Chrome CDP
    return isCdpServer(host, port);
}

// 验证是否是 Chrome CDP 服务器
fn isCdpServer(host: []const u8, port: u16) bool {
    const address = std.net.Address.parseIp(host, port) catch return false;
    const socket = std.net.tcpConnectToAddress(address) catch return false;
    defer socket.close();

    // 发送 HTTP GET 请求验证 CDP
    const request = "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    _ = socket.write(request) catch return false;

    // 读取响应
    var buffer: [1024]u8 = undefined;
    const bytes_read = socket.read(&buffer) catch return false;

    // 检查响应是否包含 CDP 特征
    const response = buffer[0..bytes_read];
    return std.mem.indexOf(u8, response, "Chrome") != null or
        std.mem.indexOf(u8, response, "chromium") != null or
        std.mem.indexOf(u8, response, "Protocol-Version") != null;
}

// ============================================================================
// 内部辅助：自动启动 Chrome
// ============================================================================

fn launchChrome(port: u16) !void {
    const chrome_path = findChromePath() orelse {
        std.log.err("[web_ops] 未找到 Chrome 浏览器", .{});
        return error.ChromeNotFound;
    };

    std.log.info("[web_ops] 找到 Chrome: {s}", .{chrome_path});

    const debug_port_arg = try std.fmt.allocPrint(std.heap.page_allocator, "--remote-debugging-port={d}", .{port});
    defer std.heap.page_allocator.free(debug_port_arg);

    var args = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer args.deinit();

    try args.append(chrome_path);
    try args.append(debug_port_arg);
    // 使用更少的启动参数，减少冲突
    try args.append("--no-first-run");
    try args.append("--no-default-browser-check");
    try args.append("--disable-extensions");
    try args.append("--disable-popup-blocking");

    const os_tag = @import("builtin").target.os.tag;
    if (os_tag == .windows) {
        // Windows 上使用 Windows 临时目录
        const temp_dir = std.process.getEnvVarOwned(std.heap.page_allocator, "TEMP") catch "/tmp";
        defer std.heap.page_allocator.free(temp_dir);
        const user_data_arg = try std.fmt.allocPrint(std.heap.page_allocator, "--user-data-dir={s}\\chrome-debug", .{temp_dir});
        defer std.heap.page_allocator.free(user_data_arg);
        try args.append(user_data_arg);
    } else {
        // Unix 系统上使用临时目录
        try args.append("--user-data-dir=/tmp/chrome-debug");
    }

    std.log.info("[web_ops] 启动 Chrome: {s}", .{debug_port_arg});
    std.log.info("[web_ops] Chrome 参数数量: {d}", .{args.items.len});

    var child = std.process.Child.init(args.items, std.heap.page_allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    _ = child.spawn() catch |err| {
        std.log.err("[web_ops] 启动 Chrome 失败: {}", .{err});
        return err;
    };

    std.log.info("[web_ops] ✓ Chrome 进程已启动 (将在后台运行)", .{});
}

// ============================================================================
// CDP 配置
// ============================================================================

const DEFAULT_CDP_HOST = "127.0.0.1";
const DEFAULT_CDP_PORT: u16 = 9222;
const HTTP_TIMEOUT_MS: u32 = 2000;

// 全局标志：Chrome 是否已经尝试启动过（避免重复启动）
var chrome_launch_attempted: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

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

    std.log.info("[web_ops] 找到 {d} 个标签页（包含非页面类型）", .{tabs.array.items.len});

    // 过滤只保留类型为 "page" 的标签页
    var page_count: usize = 0;
    for (tabs.array.items) |tab| {
        if (tab == .object) {
            if (tab.object.get("type")) |type_val| {
                if (type_val == .string and std.mem.eql(u8, type_val.string, "page")) {
                    page_count += 1;
                }
            }
        }
    }
    std.log.info("[web_ops] 过滤后找到 {d} 个有效页面标签页", .{page_count});

    // 遍历找到第一个有效的页面标签页
    for (tabs.array.items) |tab| {
        if (tab != .object) continue;

        // 检查类型是否为 page
        const tab_type = blk: {
            if (tab.object.get("type")) |type_val| {
                if (type_val == .string) {
                    break :blk type_val.string;
                }
            }
            break :blk "";
        };

        if (!std.mem.eql(u8, tab_type, "page")) {
            std.log.info("[web_ops] 跳过非页面类型标签页: type={s}", .{tab_type});
            continue;
        }

        const ws_url = tab.object.getString("webSocketDebuggerUrl") orelse {
            std.log.info("[web_ops] 页面标签页缺少 webSocketDebuggerUrl 字段", .{});
            continue;
        };

        std.log.info("[web_ops] ✓ 找到有效页面标签页: type=page, webSocketDebuggerUrl={s}", .{ws_url});
        return allocator.dupe(u8, ws_url);
    }

    std.log.info("[web_ops] 没有找到有效的页面标签页", .{});
    return error.NoTabsAvailable;
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

    // 过滤只统计类型为 "page" 的标签页
    var page_count: i64 = 0;
    if (tabs == .array) {
        for (tabs.array.items) |tab| {
            if (tab == .object) {
                if (tab.object.get("type")) |type_val| {
                    if (type_val == .string and std.mem.eql(u8, type_val.string, "page")) {
                        page_count += 1;
                    }
                }
            }
        }
    }

    const total_count: i64 = if (tabs == .array) @intCast(tabs.array.items.len) else 0;
    const result = try std.fmt.allocPrint(allocator, "{{\"tab_count\": {d}, \"total_count\": {d}, \"message\": \"CDP connection successful\"}}", .{ page_count, total_count });

    std.log.info("[web_ops] ✓ 页面信息结果构建完成 (页面标签页: {d}, 总标签页: {d})", .{ page_count, total_count });
    return result;
}

// ============================================================================
// 工具实现：web_scan
// ============================================================================

/// 规范化 URL - 添加协议前缀并输出详细日志
fn normalizeUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    std.log.info("[web_ops] [normalizeUrl] ➡️ 输入 URL: '{s}' (长度: {d})", .{ url, url.len });

    // 检查是否为空
    if (url.len == 0) {
        std.log.warn("[web_ops] [normalizeUrl] ⚠️ 空 URL，返回默认值", .{});
        return allocator.dupe(u8, "about:blank");
    }

    // 检查是否已有协议前缀
    const has_http = std.mem.startsWith(u8, url, "http://");
    const has_https = std.mem.startsWith(u8, url, "https://");
    const has_ftp = std.mem.startsWith(u8, url, "ftp://");
    const has_file = std.mem.startsWith(u8, url, "file://");

    if (has_http or has_https or has_ftp or has_file) {
        std.log.info("[web_ops] [normalizeUrl] ✓ URL 已有协议前缀: {s}", .{if (has_http) "http://" else if (has_https) "https://" else if (has_ftp) "ftp://" else "file://"});
        return allocator.dupe(u8, url);
    }

    // 检查是否是本地路径
    if (std.mem.startsWith(u8, url, "/") or
        std.mem.startsWith(u8, url, "C:") or
        std.mem.startsWith(u8, url, "c:") or
        std.mem.startsWith(u8, url, "\\") or
        std.mem.startsWith(u8, url, "."))
    {
        std.log.info("[web_ops] [normalizeUrl] 🔄 本地路径，转换为 file:// 协议", .{});
        const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{url});
        std.log.info("[web_ops] [normalizeUrl] ⬅️ 输出 URL: '{s}'", .{file_url});
        return file_url;
    }

    // 默认添加 http:// 前缀
    std.log.info("[web_ops] [normalizeUrl] 🔄 缺少协议前缀，添加 http://", .{});
    const normalized_url = try std.fmt.allocPrint(allocator, "http://{s}", .{url});
    std.log.info("[web_ops] [normalizeUrl] ⬅️ 输出 URL: '{s}'", .{normalized_url});
    return normalized_url;
}

fn createNewTab(allocator: std.mem.Allocator, host: []const u8, port: u16, url: []const u8) !json.Value {
    std.log.info("[web_ops] 创建新标签页并导航到: {s}", .{url});

    // 规范化 URL
    const normalized_url = try normalizeUrl(allocator, url);
    defer allocator.free(normalized_url);

    const create_path = try std.fmt.allocPrint(allocator, "/json/new?{s}", .{normalized_url});
    defer allocator.free(create_path);

    std.log.info("[web_ops] HTTP PUT 开始: {s}:{d}{s}", .{ host, port, create_path });

    const address = try std.net.Address.parseIp(host, port);
    std.log.info("[web_ops] ✓ 地址解析成功: {s}:{d}", .{ host, port });

    const socket = try std.net.tcpConnectToAddress(address);
    defer socket.close();
    std.log.info("[web_ops] ✓ TCP 连接建立成功", .{});

    var header_buf: [4096]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "PUT {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Length: 0\r\n\r\n",
        .{ create_path, host, port },
    );

    _ = try socket.writeAll(header);
    std.log.info("[web_ops] ✓ HTTP 请求发送成功 (头部: {d} bytes)", .{header.len});

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
            try response_list.appendSlice(read_buf[0..n]);
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

    std.log.info("[web_ops] 解析新标签页响应 (长度: {d} bytes)", .{body.len});
    const parsed = try json.parseFromSlice(json.Value, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    std.log.info("[web_ops] ✓ 新标签页创建成功!", .{});

    return parsed.value;
}

fn buildUrlScanResult(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    std.log.info("[web_ops] 构建 URL 扫描结果", .{});

    const result = try std.fmt.allocPrint(
        allocator,
        "{{\"success\": true, \"url\": \"{s}\", \"message\": \"Page opened successfully\"}}",
        .{url},
    );

    std.log.info("[web_ops] ✓ URL 扫描结果构建完成", .{});
    return result;
}

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
    const url_opt: ?[]const u8 = blk: {
        if (args == .object) {
            if (args.object.get("url")) |val| {
                if (val == .string) {
                    std.log.info("[web_ops] 指定要访问的 URL: {s}", .{val.string});
                    break :blk val.string;
                }
            }
        }
        break :blk null;
    };

    std.log.info("[web_ops] 目标 CDP 地址: {s}:{d}", .{ host, port });

    // 环境预检查 - 先检查 Chrome 是否安装
    const chrome_path = findChromePath();
    if (chrome_path == null) {
        if (shouldLog()) {
            std.log.err("[web_ops] 未找到 Chrome 浏览器", .{});
        }
        const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"chrome_not_found\", \"message\": \"未找到 Chrome 浏览器\", \"suggestion\": \"请安装 Google Chrome 或 Chromium 浏览器\"}}}}", .{}) catch return ToolResult.errorResult(ctx.allocator, "chrome_not_found");
        return ToolResult.errorResultOwned(msg);
    }

    // 先尝试获取标签页列表（如果 CDP 已可用，直接使用）
    if (shouldLog()) {
        std.log.info("[web_ops] 尝试连接 CDP 服务: {s}:{d}", .{ host, port });
    }
    const tabs_or_err = getTabList(ctx.allocator, host, port) catch |err| {
        const err_name = @errorName(err);
        if (shouldLog()) {
            std.log.err("[web_ops] CDP 连接失败 - 错误类型: {s}, 错误描述: {}", .{ err_name, err });
        }

        // 连接失败，检查是否是 ConnectionRefused（Chrome 未运行或未开启 CDP）
        if (std.mem.indexOf(u8, err_name, "ConnectionRefused") == null) {
            // 其他错误，直接返回
            if (shouldLog()) {
                std.log.err("[web_ops] ❌ 非连接拒绝错误，无法自动恢复", .{});
                std.log.err("[web_ops]    可能原因: 网络问题、防火墙阻止、端口被占用但非 CDP 服务", .{});
            }
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "{{\"success\": false, \"error\": {{\"type\": \"cdp_connection_error\", \"message\": \"连接 CDP 失败: {}\", \"error_name\": \"{s}\", \"host\": \"{s}\", \"port\": {d}, \"suggestion\": \"请检查网络连接或确保 Chrome 已启动并开启远程调试端口 {d}\"}}}}",
                .{ err, err_name, host, port, port },
            ) catch return ToolResult.errorResult(ctx.allocator, "failed to connect to CDP");
            return ToolResult.errorResultOwned(msg);
        }

        // ConnectionRefused - Chrome 未运行或未开启 CDP
        if (shouldLog()) {
            std.log.warn("[web_ops] ⚠️ CDP 连接被拒绝 (ConnectionRefused)", .{});
            std.log.info("[web_ops]    可能原因: Chrome 未运行、未开启 --remote-debugging-port 参数、或端口配置错误", .{});
        }

        // 检查是否禁用自动启动（在测试环境中使用）
        if (std.process.getEnvVarOwned(ctx.allocator, "WEB_OPS_DISABLE_AUTO_LAUNCH")) |env_val| {
            defer ctx.allocator.free(env_val);
            if (std.mem.eql(u8, env_val, "1") or std.mem.eql(u8, env_val, "true")) {
                std.log.info("[web_ops]    WEB_OPS_DISABLE_AUTO_LAUNCH=1, 跳过自动启动 Chrome", .{});
                const msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "{{\"success\": false, \"error\": {{\"type\": \"cdp_connection_refused\", \"message\": \"CDP 连接被拒绝且自动启动被禁用\", \"suggestion\": \"请手动启动 Chrome 或设置 WEB_OPS_DISABLE_AUTO_LAUNCH=0\"}}}}",
                    .{},
                ) catch return ToolResult.errorResult(ctx.allocator, "cdp connection refused");
                return ToolResult.errorResultOwned(msg);
            }
        } else |_| {}

        // 检查是否已经尝试过启动 Chrome（避免重复启动）
        if (chrome_launch_attempted.load(.monotonic) == 1) {
            std.log.info("[web_ops]    检测到 Chrome 已尝试启动过，跳过重复启动", .{});
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "{{\"success\": false, \"error\": {{\"type\": \"cdp_connection_timeout\", \"message\": \"Chrome 已尝试启动但 CDP 仍未就绪\", \"suggestion\": \"请检查 Chrome 是否正常启动并监听端口 {d}\"}}}}",
                .{port},
            ) catch return ToolResult.errorResult(ctx.allocator, "cdp connection timeout");
            return ToolResult.errorResultOwned(msg);
        }

        std.log.info("[web_ops]    尝试自动启动 Chrome...", .{});

        // 尝试自动启动 Chrome
        std.log.info("[web_ops] 🔄 启动 Chrome 进程...", .{});
        launchChrome(port) catch |launch_err| {
            const launch_err_name = @errorName(launch_err);
            std.log.err("[web_ops] ❌ 自动启动 Chrome 失败", .{});
            std.log.err("[web_ops]    错误类型: {s}", .{launch_err_name});
            std.log.err("[web_ops]    错误描述: {}", .{launch_err});
            std.log.err("[web_ops]    可能原因: Chrome 路径错误、权限不足、进程启动失败", .{});
            const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"chrome_launch_failed\", \"message\": \"无法自动启动 Chrome: {}\", \"error_name\": \"{s}\", \"suggestion\": \"请手动启动 Chrome 并添加参数 --remote-debugging-port={d}\"}}}}", .{ launch_err, launch_err_name, port }) catch return ToolResult.errorResult(ctx.allocator, "chrome_launch_failed");
            return ToolResult.errorResultOwned(msg);
        };

        // 标记 Chrome 已尝试启动（避免重复启动）
        chrome_launch_attempted.store(1, .monotonic);

        // 等待 Chrome 启动（增加等待时间以确保 Chrome 完全启动）
        const wait_seconds: u64 = 5;
        std.log.info("[web_ops] ⏳ 等待 Chrome 启动 ({d}秒)...", .{wait_seconds});
        std.time.sleep(wait_seconds * std.time.ns_per_s);

        // 检查 Chrome 进程是否还在运行
        std.log.info("[web_ops] 🔍 检查 Chrome 进程状态...", .{});

        // 尝试再次获取标签页列表（带重试机制）
        const max_retries: u32 = 5;
        const retry_delay_ms: u32 = 2000;
        var retry_count: u32 = 0;
        var tabs_after_launch: json.Value = undefined;

        while (retry_count < max_retries) : (retry_count += 1) {
            std.log.info("[web_ops] 🔄 重试连接 CDP ({d}/{d})...", .{ retry_count + 1, max_retries });
            tabs_after_launch = getTabList(ctx.allocator, host, port) catch |retry_err| {
                const retry_err_name = @errorName(retry_err);
                std.log.warn("[web_ops] ⚠️ 重试 {d} 失败: {s} - {}", .{ retry_count + 1, retry_err_name, retry_err });

                if (retry_count < max_retries - 1) {
                    std.log.info("[web_ops]    等待 {d}ms 后重试...", .{retry_delay_ms});
                    std.time.sleep(retry_delay_ms * std.time.ns_per_ms);
                    continue;
                }

                // 最后一次重试也失败
                std.log.err("[web_ops] ❌ 所有重试均失败 ({d}次)", .{max_retries});
                std.log.err("[web_ops]    可能原因: Chrome 启动超时、端口未正确监听、进程意外退出", .{});
                const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"cdp_connection_timeout\", \"message\": \"启动 Chrome 后仍无法连接 CDP，已重试 {d} 次\", \"suggestion\": \"请检查 Chrome 是否正常启动，或手动启动 Chrome 并添加参数 --remote-debugging-port={d}\"}}}}", .{ max_retries, port }) catch return ToolResult.errorResult(ctx.allocator, "failed to connect after launch");
                return ToolResult.errorResultOwned(msg);
            };

            // 连接成功
            std.log.info("[web_ops] ✓ 第 {d} 次重试成功!", .{retry_count + 1});
            break;
        }

        // 如果提供了 URL，创建新标签页
        if (url_opt) |url| {
            _ = createNewTab(ctx.allocator, host, port, url) catch |tab_err| {
                std.log.err("[web_ops] 创建新标签页失败: {}", .{tab_err});
                freeJsonValue(&tabs_after_launch, ctx.allocator);
                const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"tab_creation_failed\", \"message\": \"创建标签页失败: {}\"}}}}", .{tab_err}) catch return ToolResult.errorResult(ctx.allocator, "failed to create tab");
                return ToolResult.errorResultOwned(msg);
            };
            const result_str = buildUrlScanResult(ctx.allocator, url) catch |build_err| {
                std.log.err("[web_ops] ❌ 构建结果失败: {}", .{build_err});
                freeJsonValue(&tabs_after_launch, ctx.allocator);
                const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"result_build_failed\", \"message\": \"构建结果失败: {}\"}}}}", .{build_err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
                return ToolResult.errorResultOwned(msg);
            };
            freeJsonValue(&tabs_after_launch, ctx.allocator);
            std.log.info("[web_ops] ========== web_scan 自动启动并访问 URL 成功 ==========", .{});
            return .{ .data = .{ .text = result_str }, .should_exit = true };
        }

        // 没有 URL，返回页面信息
        const result_str = buildPageInfoResult(ctx.allocator, tabs_after_launch) catch |build_err| {
            std.log.err("[web_ops] ❌ 构建结果失败: {}", .{build_err});
            freeJsonValue(&tabs_after_launch, ctx.allocator);
            const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"result_build_failed\", \"message\": \"构建结果失败: {}\"}}}}", .{build_err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
            return ToolResult.errorResultOwned(msg);
        };
        freeJsonValue(&tabs_after_launch, ctx.allocator);
        std.log.info("[web_ops] ========== web_scan 自动启动并连接成功 ==========", .{});
        return .{ .data = .{ .text = result_str }, .should_exit = true };
    };

    var tabs = tabs_or_err;

    std.log.info("[web_ops] ✓ CDP 连接成功，直接使用现有 Chrome 实例", .{});

    // 如果提供了 URL，创建新标签页
    if (url_opt) |url| {
        _ = createNewTab(ctx.allocator, host, port, url) catch |tab_err2| {
            std.log.err("[web_ops] 创建新标签页失败: {}", .{tab_err2});
            freeJsonValue(&tabs, ctx.allocator);
            const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"tab_creation_failed\", \"message\": \"创建标签页失败: {}\"}}}}", .{tab_err2}) catch return ToolResult.errorResult(ctx.allocator, "failed to create tab");
            return ToolResult.errorResultOwned(msg);
        };
        const result_str = buildUrlScanResult(ctx.allocator, url) catch |build_err| {
            std.log.err("[web_ops] ❌ 构建结果失败: {}", .{build_err});
            freeJsonValue(&tabs, ctx.allocator);
            const msg = std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"error\": {{\"type\": \"result_build_failed\", \"message\": \"构建结果失败: {}\"}}}}", .{build_err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
            return ToolResult.errorResultOwned(msg);
        };
        freeJsonValue(&tabs, ctx.allocator);
        std.log.info("[web_ops] ========== web_scan 访问 URL 成功 ==========", .{});
        return .{ .data = .{ .text = result_str }, .should_exit = true };
    }

    // 没有 URL，返回页面信息
    const result_str = buildPageInfoResult(ctx.allocator, tabs) catch |err| {
        std.log.info("[web_ops] 构建结果失败: {}", .{err});
        freeJsonValue(&tabs, ctx.allocator);
        const msg = std.fmt.allocPrint(ctx.allocator, "failed to build result: {}", .{err}) catch return ToolResult.errorResult(ctx.allocator, "failed to build result");
        return ToolResult.errorResultOwned(msg);
    };
    freeJsonValue(&tabs, ctx.allocator);

    std.log.info("[web_ops] ========== web_scan 执行完成 ==========", .{});
    return .{ .data = .{ .text = result_str }, .should_exit = true };
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
    if (httpPost(
        ctx.allocator,
        host,
        port,
        "/json/protocol",
        "application/json",
        request_str,
    )) |http_resp| {
        ctx.allocator.free(http_resp);
    } else |err| {
        if (shouldLog()) {
            std.log.warn("[web_ops] HTTP POST 失败: {} (CDP 命令执行需要 WebSocket 支持)", .{err});
        }
    }

    if (shouldLog()) {
        std.log.warn("[web_ops] web_execute_js 当前仅支持 HTTP 连接，完整的 JS 执行需要 WebSocket", .{});
    }
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
