//! src/llm/protocol.zig - 协议转换
//!
//! 提供 Claude 和 OpenAI 消息格式之间的双向转换，以及消息修复和
//! 历史压缩功能。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const types = @import("types.zig");

const Message = types.Message;
const ContentBlock = types.ContentBlock;
const ContentBlockTag = types.ContentBlockTag;
const Role = types.Role;
const ToolDefinition = types.ToolDefinition;

// ---------------------------------------------------------------------------
// Claude -> OpenAI 消息格式转换
// ---------------------------------------------------------------------------

/// ClaudeContentBlock: Claude API 的内容块格式
const ClaudeContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    input: ?json.Value = null,
    tool_use_id: ?[]const u8 = null,
    content: ?[]const u8 = null,
    is_error: ?bool = null,
    source: ?ClaudeImageSource = null,
    cache_control: ?ClaudeCacheControl = null,
};

const ClaudeImageSource = struct {
    type: []const u8 = "base64",
    media_type: []const u8 = "image/png",
    data: []const u8 = "",
};

const ClaudeCacheControl = struct {
    type: []const u8 = "ephemeral",
};

/// OaiMessage: OpenAI 格式的消息
const OaiMessage = struct {
    role: []const u8,
    content: ?json.Value = null,
    tool_calls: ?[]OaiToolCall = null,
    tool_call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

const OaiToolCall = struct {
    id: []const u8,
    type: []const u8 = "function",
    function: OaiFunction,
};

const OaiFunction = struct {
    name: []const u8,
    arguments: []const u8,
};

/// 将 Claude 格式的消息列表转换为 OpenAI 格式
///
/// Claude 消息格式：
///   {"role": "user", "content": [{"type": "text", "text": "..."}]}
///   {"role": "assistant", "content": [{"type": "thinking", "thinking": "..."}, {"type": "text", "text": "..."}, {"type": "tool_use", "id": "...", "name": "...", "input": {...}}]}
///   {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "...", "content": "..."}]}
///
/// OpenAI 消息格式：
///   {"role": "user", "content": "..."}
///   {"role": "assistant", "content": "...", "tool_calls": [{"id": "...", "type": "function", "function": {"name": "...", "arguments": "..."}}]}
///   {"role": "tool", "tool_call_id": "...", "content": "..."}
pub fn claudeMessagesToOai(
    allocator: Allocator,
    claude_messages: []const json.Value,
) !std.ArrayList(json.Value) {
    var result = std.ArrayList(json.Value).init(allocator);
    errdefer {
        for (result.items) |*v| v.deinit(allocator);
        result.deinit();
    }

    for (claude_messages) |claude_msg| {
        if (claude_msg != .object) continue;

        const role_val = claude_msg.objectGet("role") orelse continue;
        if (role_val != .string) continue;
        const role = role_val.string;

        const content_val = claude_msg.objectGet("content");

        // 处理 tool_result 消息（Claude 的 user 角色包含 tool_result）
        if (std.mem.eql(u8, role, "user") and content_val != null and content_val.?.* == .array) {
            var tool_results = std.ArrayList(json.Value).init(allocator);
            var text_parts = std.ArrayList(u8).init(allocator);
            defer text_parts.deinit();

            for (content_val.?.array.items) |block| {
                if (block != .object) continue;
                const block_type = block.objectGet("type") orelse continue;
                if (block_type != .string) continue;

                if (std.mem.eql(u8, block_type.string, "tool_result")) {
                    // 转换为 OpenAI tool 消息
                    const tool_use_id = block.objectGet("tool_use_id");
                    const result_content = block.objectGet("content");

                    var tool_msg = std.StringHashMap(json.Value).init(allocator);
                    try tool_msg.put("role", json.Value.string("tool"));
                    if (tool_use_id != null and tool_use_id.?.* == .string) {
                        try tool_msg.put("tool_call_id", json.Value.string(tool_use_id.?.string));
                    }
                    if (result_content != null) {
                        if (result_content.?.* == .string) {
                            try tool_msg.put("content", json.Value.string(result_content.?.string));
                        } else {
                            try tool_msg.put("content", try result_content.?.deepClone(allocator));
                        }
                    }

                    const tool_obj = json.Value.object(tool_msg);
                    try tool_results.append(tool_obj);
                } else if (std.mem.eql(u8, block_type.string, "text")) {
                    const text_val = block.objectGet("text");
                    if (text_val != null and text_val.?.* == .string) {
                        if (text_parts.items.len > 0) {
                            try text_parts.append('\n');
                        }
                        try text_parts.appendSlice(text_val.?.string);
                    }
                }
            }

            // 先添加文本消息
            if (text_parts.items.len > 0) {
                var user_msg = std.StringHashMap(json.Value).init(allocator);
                try user_msg.put("role", json.Value.string("user"));
                try user_msg.put("content", json.Value.string(try allocator.dupe(u8, text_parts.items)));
                try result.append(json.Value.object(user_msg));
            }

            // 再添加 tool 消息
            for (tool_results.items) |tr| {
                try result.append(tr);
            }
            tool_results.deinit();
            continue;
        }

        // 处理 assistant 消息
        if (std.mem.eql(u8, role, "assistant") and content_val != null and content_val.?.* == .array) {
            var text_parts = std.ArrayList(u8).init(allocator);
            defer text_parts.deinit();
            var tool_calls = std.ArrayList(json.Value).init(allocator);
            defer {
                for (tool_calls.items) |*tc| tc.deinit(allocator);
                tool_calls.deinit();
            }

            for (content_val.?.array.items) |block| {
                if (block != .object) continue;
                const block_type = block.objectGet("type") orelse continue;
                if (block_type != .string) continue;

                if (std.mem.eql(u8, block_type.string, "text")) {
                    const text_val = block.objectGet("text");
                    if (text_val != null and text_val.?.* == .string) {
                        if (text_parts.items.len > 0) {
                            try text_parts.append('\n');
                        }
                        try text_parts.appendSlice(text_val.?.string);
                    }
                } else if (std.mem.eql(u8, block_type.string, "thinking")) {
                    // thinking 块在 OpenAI 格式中通常忽略或放入 content 前缀
                    // 某些模型支持 reasoning_content 字段
                } else if (std.mem.eql(u8, block_type.string, "tool_use")) {
                    const id_val = block.objectGet("id");
                    const name_val = block.objectGet("name");
                    const input_val = block.objectGet("input");

                    const id_str = if (id_val != null and id_val.?.* == .string)
                        id_val.?.string
                    else
                        "";

                    const name_str = if (name_val != null and name_val.?.* == .string)
                        name_val.?.string
                    else
                        "";

                    // 将 input 对象序列化为 JSON 字符串
                    var args_str = "{}";
                    if (input_val != null) {
                        args_str = std.json.stringifyAlloc(allocator, input_val.?, .{}) catch "{}";
                    }

                    var func_obj = std.StringHashMap(json.Value).init(allocator);
                    try func_obj.put("name", json.Value.string(try allocator.dupe(u8, name_str)));
                    try func_obj.put("arguments", json.Value.string(try allocator.dupe(u8, args_str)));

                    var tc_obj = std.StringHashMap(json.Value).init(allocator);
                    try tc_obj.put("id", json.Value.string(try allocator.dupe(u8, id_str)));
                    try tc_obj.put("type", json.Value.string("function"));
                    try tc_obj.put("function", json.Value.object(func_obj));

                    try tool_calls.append(json.Value.object(tc_obj));
                }
            }

            var oai_msg = std.StringHashMap(json.Value).init(allocator);
            try oai_msg.put("role", json.Value.string("assistant"));

            if (text_parts.items.len > 0) {
                try oai_msg.put("content", json.Value.string(try allocator.dupe(u8, text_parts.items)));
            } else {
                try oai_msg.put("content", json.Value.null);
            }

            if (tool_calls.items.len > 0) {
                try oai_msg.put("tool_calls", json.Value.array(tool_calls));
            }

            try result.append(json.Value.object(oai_msg));
            continue;
        }

        // 其他消息直接复制
        try result.append(try claude_msg.deepClone(allocator));
    }

    return result;
}

// ---------------------------------------------------------------------------
// OpenAI 工具定义 -> Claude 工具定义
// ---------------------------------------------------------------------------

/// 将 OpenAI 格式的工具定义转换为 Claude 格式
///
/// OpenAI 格式：
///   {"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}
///
/// Claude 格式：
///   {"name": "...", "description": "...", "input_schema": {...}}
pub fn oaiToolsToClaude(
    allocator: Allocator,
    oai_tools: []const json.Value,
) !std.ArrayList(json.Value) {
    var result = std.ArrayList(json.Value).init(allocator);
    errdefer {
        for (result.items) |*v| v.deinit(allocator);
        result.deinit();
    }

    for (oai_tools) |tool| {
        if (tool != .object) continue;

        const tool_type = tool.objectGet("type");
        if (tool_type != null and tool_type.?.* == .string) {
            if (!std.mem.eql(u8, tool_type.?.string, "function")) continue;
        }

        const func = tool.objectGet("function");
        if (func == null or func.?.* != .object) continue;

        const name = func.?.objectGet("name");
        const desc = func.?.objectGet("description");
        const params = func.?.objectGet("parameters");

        var claude_tool = std.StringHashMap(json.Value).init(allocator);

        if (name != null and name.?.* == .string) {
            try claude_tool.put("name", json.Value.string(try allocator.dupe(u8, name.?.string)));
        }
        if (desc != null and desc.?.* == .string) {
            try claude_tool.put("description", json.Value.string(try allocator.dupe(u8, desc.?.string)));
        }
        if (params != null) {
            try claude_tool.put("input_schema", try params.?.deepClone(allocator));
        } else {
            // 默认空 schema
            var empty_schema = std.StringHashMap(json.Value).init(allocator);
            try empty_schema.put("type", json.Value.string("object"));
            try empty_schema.put("properties", json.Value.object(std.StringHashMap(json.Value).init(allocator)));
            try claude_tool.put("input_schema", json.Value.object(empty_schema));
        }

        try result.append(json.Value.object(claude_tool));
    }

    return result;
}

// ---------------------------------------------------------------------------
// Claude 工具定义 -> OpenAI 工具定义
// ---------------------------------------------------------------------------

/// 将 Claude 格式的工具定义转换为 OpenAI 格式
pub fn claudeToolsToOai(
    allocator: Allocator,
    claude_tools: []const json.Value,
) !std.ArrayList(json.Value) {
    var result = std.ArrayList(json.Value).init(allocator);
    errdefer {
        for (result.items) |*v| v.deinit(allocator);
        result.deinit();
    }

    for (claude_tools) |tool| {
        if (tool != .object) continue;

        const name = tool.objectGet("name");
        const desc = tool.objectGet("description");
        const schema = tool.objectGet("input_schema");

        var func_obj = std.StringHashMap(json.Value).init(allocator);

        if (name != null and name.?.* == .string) {
            try func_obj.put("name", json.Value.string(try allocator.dupe(u8, name.?.string)));
        }
        if (desc != null and desc.?.* == .string) {
            try func_obj.put("description", json.Value.string(try allocator.dupe(u8, desc.?.string)));
        }
        if (schema != null) {
            try func_obj.put("parameters", try schema.?.deepClone(allocator));
        }

        var oai_tool = std.StringHashMap(json.Value).init(allocator);
        try oai_tool.put("type", json.Value.string("function"));
        try oai_tool.put("function", json.Value.object(func_obj));

        try result.append(json.Value.object(oai_tool));
    }

    return result;
}

// ---------------------------------------------------------------------------
// fixMessages - 消息修复
// ---------------------------------------------------------------------------

/// 修复消息列表中的常见问题：
/// 1. 确保角色交替（连续相同角色合并）
/// 2. 确保 tool_use 和 tool_result 配对
/// 3. 移除空的 content 消息
pub fn fixMessages(
    allocator: Allocator,
    messages: []const json.Value,
) !std.ArrayList(json.Value) {
    var result = std.ArrayList(json.Value).init(allocator);
    errdefer {
        for (result.items) |*v| v.deinit(allocator);
        result.deinit();
    }

    var last_role: ?[]const u8 = null;
    var pending_tool_use_ids = std.ArrayList([]const u8).init(allocator);
    defer pending_tool_use_ids.deinit();

    for (messages) |msg| {
        if (msg != .object) continue;

        const role_val = msg.objectGet("role");
        if (role_val == null or role_val.?.* != .string) continue;
        const role = role_val.?.string;

        // 检查空 content
        const content_val = msg.objectGet("content");
        const has_tool_calls = msg.objectGet("tool_calls") != null;
        const is_tool = std.mem.eql(u8, role, "tool");

        if (!is_tool and !has_tool_calls) {
            if (content_val) |cv| {
                if (cv.* == .string and cv.string.len == 0) {
                    // 空文本消息，跳过
                    continue;
                }
                if (cv.* == .array and cv.array.items.len == 0) {
                    // 空数组消息，跳过
                    continue;
                }
            }
        }

        // 处理连续相同角色
        if (last_role != null and std.mem.eql(u8, last_role.?, role)) {
            // 尝试合并到前一条消息
            if (result.items.len > 0) {
                const prev = &result.items[result.items.len - 1];
                if (prev.* == .object) {
                    _ = mergeMessages(allocator, prev, msg) catch null;
                    continue;
                }
            }
        }

        // 跟踪 tool_use / tool_result 配对
        if (has_tool_calls) {
            if (msg.objectGet("tool_calls")) |tc| {
                if (tc.* == .array) {
                    for (tc.array.items) |tc_item| {
                        if (tc_item.* == .object) {
                            if (tc_item.objectGet("id")) |id_val| {
                                if (id_val.* == .string) {
                                    try pending_tool_use_ids.append(id_val.string);
                                }
                            }
                        }
                    }
                }
            }
        }

        if (is_tool) {
            if (msg.objectGet("tool_call_id")) |tcid| {
                if (tcid.* == .string) {
                    // 移除匹配的 pending id
                    for (pending_tool_use_ids.items, 0..) |pid, i| {
                        if (std.mem.eql(u8, pid, tcid.string)) {
                            _ = pending_tool_use_ids.orderedRemove(i);
                            break;
                        }
                    }
                }
            }
        }

        try result.append(try msg.deepClone(allocator));
        last_role = role;
    }

    return result;
}

/// 合并两条相同角色的消息
fn mergeMessages(
    allocator: Allocator,
    prev: *json.Value,
    current: json.Value,
) !void {
    if (prev.* != .object or current != .object) return;

    const prev_content = prev.object.get("content");
    const curr_content = current.object.get("content");

    // 简单合并文本内容
    if (prev_content != null and curr_content != null) {
        if (prev_content.?.* == .string and curr_content.?.* == .string) {
            const merged = try std.fmt.allocPrint(
                allocator,
                "{s}\n{s}",
                .{ prev_content.?.string, curr_content.?.string },
            );
            try prev.object.put("content", json.Value.string(merged));
        }
    }
}

// ---------------------------------------------------------------------------
// compressHistoryTags - 压缩历史标签
// ---------------------------------------------------------------------------

/// 压缩历史消息中的 thinking / tool_use / tool_result 标签
///
/// 将旧消息中的 thinking 块替换为摘要，将已完成的 tool_use/tool_result
/// 对替换为简短描述，以减少上下文窗口占用。
pub fn compressHistoryTags(
    allocator: Allocator,
    messages: []const json.Value,
    max_keep_recent: usize,
) !std.ArrayList(json.Value) {
    if (messages.len <= max_keep_recent) {
        // 无需压缩，直接复制
        var result = std.ArrayList(json.Value).init(allocator);
        errdefer {
            for (result.items) |*v| v.deinit(allocator);
            result.deinit();
        }
        for (messages) |msg| {
            try result.append(try msg.deepClone(allocator));
        }
        return result;
    }

    var result = std.ArrayList(json.Value).init(allocator);
    errdefer {
        for (result.items) |*v| v.deinit(allocator);
        result.deinit();
    }

    const compress_end = messages.len - max_keep_recent;

    // 压缩旧消息
    for (messages[0..compress_end]) |msg| {
        if (msg != .object) {
            try result.append(try msg.deepClone(allocator));
            continue;
        }

        const role_val = msg.objectGet("role");
        if (role_val == null or role_val.?.* != .string) {
            try result.append(try msg.deepClone(allocator));
            continue;
        }

        const role = role_val.?.string;
        const content_val = msg.objectGet("content");

        // 压缩 assistant 消息中的 thinking 块
        if (std.mem.eql(u8, role, "assistant") and content_val != null and content_val.?.* == .array) {
            var compressed_blocks = std.ArrayList(json.Value).init(allocator);
            defer {
                for (compressed_blocks.items) |*b| b.deinit(allocator);
                compressed_blocks.deinit();
            }

            for (content_val.?.array.items) |block| {
                if (block != .object) {
                    try compressed_blocks.append(try block.deepClone(allocator));
                    continue;
                }
                const block_type = block.objectGet("type");
                if (block_type == null or block_type.?.* != .string) {
                    try compressed_blocks.append(try block.deepClone(allocator));
                    continue;
                }

                if (std.mem.eql(u8, block_type.?.string, "thinking")) {
                    // 将 thinking 块替换为摘要
                    var summary_block = std.StringHashMap(json.Value).init(allocator);
                    try summary_block.put("type", json.Value.string("text"));
                    try summary_block.put("text", json.Value.string("[thinking compressed]"));
                    try compressed_blocks.append(json.Value.object(summary_block));
                } else if (std.mem.eql(u8, block_type.?.string, "tool_use")) {
                    // 保留 tool_use 但移除 input 详情
                    var compressed_block = std.StringHashMap(json.Value).init(allocator);
                    try compressed_block.put("type", json.Value.string("tool_use"));
                    if (block.objectGet("id")) |id| {
                        try compressed_block.put("id", try id.deepClone(allocator));
                    }
                    if (block.objectGet("name")) |name| {
                        try compressed_block.put("name", try name.deepClone(allocator));
                    }
                    // input 替换为空对象
                    const empty = std.StringHashMap(json.Value).init(allocator);
                    try compressed_block.put("input", json.Value.object(empty));
                    try compressed_blocks.append(json.Value.object(compressed_block));
                } else {
                    try compressed_blocks.append(try block.deepClone(allocator));
                }
            }

            var compressed_msg = std.StringHashMap(json.Value).init(allocator);
            try compressed_msg.put("role", json.Value.string("assistant"));
            try compressed_msg.put("content", json.Value.array(compressed_blocks));
            try result.append(json.Value.object(compressed_msg));
        } else if (std.mem.eql(u8, role, "user") and content_val != null and content_val.?.* == .array) {
            // 压缩 user 消息中的 tool_result
            var compressed_blocks = std.ArrayList(json.Value).init(allocator);
            defer {
                for (compressed_blocks.items) |*b| b.deinit(allocator);
                compressed_blocks.deinit();
            }

            for (content_val.?.array.items) |block| {
                if (block != .object) {
                    try compressed_blocks.append(try block.deepClone(allocator));
                    continue;
                }
                const block_type = block.objectGet("type");
                if (block_type == null or block_type.?.* != .string) {
                    try compressed_blocks.append(try block.deepClone(allocator));
                    continue;
                }

                if (std.mem.eql(u8, block_type.?.string, "tool_result")) {
                    // 将 tool_result 内容截断
                    var compressed_block = std.StringHashMap(json.Value).init(allocator);
                    try compressed_block.put("type", json.Value.string("tool_result"));
                    if (block.objectGet("tool_use_id")) |id| {
                        try compressed_block.put("tool_use_id", try id.deepClone(allocator));
                    }
                    try compressed_block.put("content", json.Value.string("[result compressed]"));
                    try compressed_blocks.append(json.Value.object(compressed_block));
                } else {
                    try compressed_blocks.append(try block.deepClone(allocator));
                }
            }

            var compressed_msg = std.StringHashMap(json.Value).init(allocator);
            try compressed_msg.put("role", json.Value.string("user"));
            try compressed_msg.put("content", json.Value.array(compressed_blocks));
            try result.append(json.Value.object(compressed_msg));
        } else {
            // 其他消息保持不变
            try result.append(try msg.deepClone(allocator));
        }
    }

    // 保留最近的消息不变
    for (messages[compress_end..]) |msg| {
        try result.append(try msg.deepClone(allocator));
    }

    return result;
}

// ---------------------------------------------------------------------------
// buildProtocolPrompt - 构建 ToolClient 协议提示词
// ---------------------------------------------------------------------------

/// 构建 ToolClient 的协议提示词
///
/// 该提示词指导 LLM 如何使用工具、如何返回结果等。
pub fn buildProtocolPrompt(allocator: Allocator, options: ProtocolPromptOptions) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll(
        \\You are a helpful assistant with access to tools.
        \\
        \\## Tool Usage Protocol
        \\
        \\When you need to use a tool:
        \\1. Respond with a tool_use content block containing the tool name and input parameters.
        \\2. Wait for the tool result before continuing.
        \\3. You may use multiple tools in a single response if they are independent.
        \\
    );

    if (options.include_thinking_instructions) {
        try writer.writeAll(
            \\## Thinking Protocol
            \\
            \\Before using tools, show your reasoning in a thinking block:
            \\- Analyze the user's request
            \\- Plan which tools to use and in what order
            \\- Consider edge cases
            \\
        );
    }

    if (options.max_tool_calls_per_turn > 0) {
        try writer.print(
            \\## Limits
            \\- Maximum {} tool calls per turn
            \\
        , .{options.max_tool_calls_per_turn});
    }

    if (options.tool_names) |names| {
        try writer.writeAll("## Available Tools\n\n");
        for (names) |name| {
            try writer.print("- {s}\n", .{name});
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll(
        \\## Response Format
        \\
        \\After receiving tool results:
        \\1. Analyze the results
        \\2. Provide a clear response to the user
        \\3. If further tool calls are needed, make them
        \\4. When done, provide a final answer without additional tool calls
        \\
    );

    return buf.toOwnedSlice();
}

/// 协议提示词选项
pub const ProtocolPromptOptions = struct {
    /// 是否包含 thinking 指导
    include_thinking_instructions: bool = true,
    /// 每轮最大工具调用数（0 = 不限制）
    max_tool_calls_per_turn: u32 = 0,
    /// 可用工具名称列表
    tool_names: ?[][]const u8 = null,
};

// ---------------------------------------------------------------------------
// 辅助：消息格式转换（Message struct -> JSON）
// ---------------------------------------------------------------------------

/// 将 Message 结构体列表序列化为 JSON 数组（Claude 格式）
pub fn messagesToClaudeJson(
    allocator: Allocator,
    messages: []const Message,
) !json.Value {
    var arr = std.ArrayList(json.Value).init(allocator);
    errdefer {
        for (arr.items) |*v| v.deinit(allocator);
        arr.deinit();
    }

    for (messages) |msg| {
        var obj = std.StringHashMap(json.Value).init(allocator);
        try obj.put("role", json.Value.string(msg.role.toString()));

        if (msg.content_blocks) |blocks| {
            var blocks_arr = std.ArrayList(json.Value).init(allocator);
            for (blocks) |block| {
                const block_val = try contentBlockToClaudeJson(allocator, block);
                try blocks_arr.append(block_val);
            }
            try obj.put("content", json.Value.array(blocks_arr));
        } else if (msg.content) |text| {
            try obj.put("content", json.Value.string(text));
        }

        if (msg.cache_control) {
            try obj.put("cache_control", json.Value.object(brk: {
                var cc = std.StringHashMap(json.Value).init(allocator);
                try cc.put("type", json.Value.string("ephemeral"));
                break :brk cc;
            }));
        }

        try arr.append(json.Value.object(obj));
    }

    return json.Value.array(arr);
}

/// 将 ContentBlock 转换为 Claude JSON 格式
fn contentBlockToClaudeJson(allocator: Allocator, block: ContentBlock) !json.Value {
    var obj = std.StringHashMap(json.Value).init(allocator);

    switch (block.tag) {
        .text => {
            try obj.put("type", json.Value.string("text"));
            if (block.text) |t| {
                try obj.put("text", json.Value.string(t));
            }
        },
        .thinking => {
            try obj.put("type", json.Value.string("thinking"));
            if (block.text) |t| {
                try obj.put("thinking", json.Value.string(t));
            }
        },
        .tool_use => {
            try obj.put("type", json.Value.string("tool_use"));
            if (block.id) |id| {
                try obj.put("id", json.Value.string(id));
            }
            if (block.name) |name| {
                try obj.put("name", json.Value.string(name));
            }
            if (block.input) |input| {
                try obj.put("input", try input.deepClone(allocator));
            }
        },
        .tool_result => {
            try obj.put("type", json.Value.string("tool_result"));
            if (block.tool_use_id) |id| {
                try obj.put("tool_use_id", json.Value.string(id));
            }
            if (block.content) |c| {
                try obj.put("content", json.Value.string(c));
            }
            if (block.is_error) {
                try obj.put("is_error", json.Value.bool_true);
            }
        },
        .image => {
            try obj.put("type", json.Value.string("image"));
            var source = std.StringHashMap(json.Value).init(allocator);
            try source.put("type", json.Value.string(block.source_type orelse "base64"));
            try source.put("media_type", json.Value.string(block.media_type orelse "image/png"));
            try source.put("data", json.Value.string(block.data orelse ""));
            try obj.put("source", json.Value.object(source));
        },
    }

    return json.Value.object(obj);
}

/// 将 Message 结构体列表序列化为 JSON 数组（OpenAI 格式）
pub fn messagesToOaiJson(
    allocator: Allocator,
    messages: []const Message,
) !json.Value {
    var arr = std.ArrayList(json.Value).init(allocator);
    errdefer {
        for (arr.items) |*v| v.deinit(allocator);
        arr.deinit();
    }

    for (messages) |msg| {
        var obj = std.StringHashMap(json.Value).init(allocator);
        try obj.put("role", json.Value.string(msg.role.toString()));

        if (msg.content) |text| {
            try obj.put("content", json.Value.string(text));
        } else if (msg.content_blocks) |blocks| {
            // 提取文本内容
            var text_buf = std.ArrayList(u8).init(allocator);
            defer text_buf.deinit();
            var tool_calls_arr = std.ArrayList(json.Value).init(allocator);
            defer {
                for (tool_calls_arr.items) |*v| v.deinit(allocator);
                tool_calls_arr.deinit();
            }

            for (blocks) |block| {
                switch (block.tag) {
                    .text => {
                        if (block.text) |t| {
                            if (text_buf.items.len > 0) try text_buf.append('\n');
                            try text_buf.appendSlice(t);
                        }
                    },
                    .thinking => {
                        // OpenAI 格式中忽略 thinking，或放入 content
                        if (block.text) |t| {
                            if (text_buf.items.len > 0) try text_buf.append('\n');
                            try text_buf.appendSlice(t);
                        }
                    },
                    .tool_use => {
                        var func_obj = std.StringHashMap(json.Value).init(allocator);
                        if (block.name) |name| {
                            try func_obj.put("name", json.Value.string(name));
                        }
                        if (block.input) |input| {
                            const args_str = std.json.stringifyAlloc(allocator, input, .{}) catch "{}";
                            try func_obj.put("arguments", json.Value.string(args_str));
                        }

                        var tc_obj = std.StringHashMap(json.Value).init(allocator);
                        if (block.id) |id| {
                            try tc_obj.put("id", json.Value.string(id));
                        }
                        try tc_obj.put("type", json.Value.string("function"));
                        try tc_obj.put("function", json.Value.object(func_obj));
                        try tool_calls_arr.append(json.Value.object(tc_obj));
                    },
                    .tool_result => {
                        // tool_result 在 OpenAI 中是单独的 tool 消息
                    },
                    .image => {
                        // 图片暂不处理
                    },
                }
            }

            if (text_buf.items.len > 0) {
                try obj.put("content", json.Value.string(try text_buf.toOwnedSlice()));
            }
            if (tool_calls_arr.items.len > 0) {
                try obj.put("tool_calls", json.Value.array(tool_calls_arr));
            }
        }

        try arr.append(json.Value.object(obj));
    }

    return json.Value.array(arr);
}
