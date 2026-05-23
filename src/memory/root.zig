//! memory 模块 —— 对话历史与上下文窗口管理
//!
//! 提供 Agent 的记忆能力，包括：
//! - 对话历史存储（消息列表）
//! - 上下文窗口大小管理
//! - 历史消息裁剪策略
//! - 持久化存储接口

const std = @import("std");

pub const Message = struct {
    role: enum { system, user, assistant, tool },
    content: []const u8,
};

/// 对话记忆管理器
pub const Memory = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    system_prompt: []const u8,
    /// 上下文窗口中允许的最大消息数（不含 system）
    max_messages: usize = 50,

    pub fn init(allocator: std.mem.Allocator, system_prompt: []const u8) Memory {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message).init(allocator),
            .system_prompt = system_prompt,
        };
    }

    pub fn deinit(self: *Memory) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit();
    }

    /// 添加一条消息到历史
    pub fn addMessage(self: *Memory, role: Message.Role, content: []const u8) !void {
        const owned = try self.allocator.dupe(u8, content);
        try self.messages.append(.{ .role = role, .content = owned });
    }

    /// 获取用于发送给 LLM 的消息切片（含 system prompt + 最近 N 条）
    pub fn getContext(self: *const Memory) ![]const Message {
        // TODO: 实现裁剪逻辑
        return self.messages.items;
    }

    /// 清空对话历史（保留 system prompt）
    pub fn clear(self: *Memory) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.clearRetainingCapacity();
    }
};
