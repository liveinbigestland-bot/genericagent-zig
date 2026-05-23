//! tools 模块 —— 工具注册、调度与执行
//!
//! 提供 Agent 可调用的外部工具能力，包括：
//! - 工具定义与注册（ToolRegistry）
//! - 参数校验与解析
//! - 工具执行调度（dispatch）
//! - 执行结果格式化（ToolResult）
//!
//! 子模块：
//! - registry: 核心注册与调度框架
//! - code_run: Python/Bash/PowerShell 代码执行
//! - file_ops: 文件读写与局部修改
//! - web_ops: 浏览器控制（CDP）
//! - memory_ops: 记忆管理与人机交互

const std = @import("std");
const json = @import("json");

// ============================================================================
// 子模块导出
// ============================================================================

pub const registry = @import("registry.zig");
pub const code_run = @import("code_run.zig");
pub const file_ops = @import("file_ops.zig");
pub const web_ops = @import("web_ops.zig");
pub const memory_ops = @import("memory_ops.zig");

// ============================================================================
// 重新导出核心类型
// ============================================================================

pub const ToolResult = registry.ToolResult;
pub const ToolContext = registry.ToolContext;
pub const ToolFn = registry.ToolFn;
pub const ToolEntry = registry.ToolEntry;
pub const ToolRegistry = registry.ToolRegistry;

// ============================================================================
// 错误类型（保持向后兼容）
// ============================================================================

pub const ToolError = error{
    ToolNotFound,
    InvalidParams,
    ExecutionFailed,
    Timeout,
};

// ============================================================================
// 向后兼容的旧接口
// ============================================================================

/// 旧版工具定义（保持与 agent/root.zig 的兼容性）
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8,
    execute: *const fn ([]const u8, std.mem.Allocator) ToolError![]const u8,
};

/// 旧版注册表（保持向后兼容）
pub const Registry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(ToolDef),
    /// 内部的新版注册表（如果通过 createDefaultRegistry 创建）
    inner: ?ToolRegistry = null,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(ToolDef).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        if (self.inner) |*inner| {
            inner.deinit();
        }
        self.tools.deinit();
    }

    pub fn register(self: *Registry, tool: ToolDef) !void {
        try self.tools.put(tool.name, tool);
    }

    pub fn find(self: *const Registry, name: []const u8) ?ToolDef {
        return self.tools.get(name);
    }
};

// ============================================================================
// createDefaultRegistry —— 创建预注册所有 9 个工具的注册表
// ============================================================================

/// 创建默认的工具注册表，预注册所有 9 个工具：
/// 1. python_run    - Python 脚本执行
/// 2. bash_run      - Bash 命令执行
/// 3. powershell_run - PowerShell 命令执行
/// 4. file_read     - 文件读取
/// 5. file_write    - 文件写入
/// 6. file_patch    - 文件局部修改
/// 7. web_scan      - 浏览器标签页扫描
/// 8. web_execute_js - 浏览器 JS 执行
/// 9. update_working_checkpoint - 更新工作检查点
/// 10. start_long_term_update    - 长期记忆蒸馏
/// 11. ask_user      - 人机交互
pub fn createDefaultRegistry(allocator: std.mem.Allocator) !ToolRegistry {
    var reg = ToolRegistry.init(allocator);
    errdefer reg.deinit();

    // 注册代码执行工具（3 个）
    const code_entries = code_run.getToolEntries();
    for (code_entries) |entry| {
        try reg.register(entry);
    }

    // 注册文件操作工具（3 个）
    const file_entries = file_ops.getToolEntries();
    for (file_entries) |entry| {
        try reg.register(entry);
    }

    // 注册浏览器控制工具（2 个）
    const web_entries = web_ops.getToolEntries();
    for (web_entries) |entry| {
        try reg.register(entry);
    }

    // 注册记忆操作工具（3 个）
    const memory_entries = memory_ops.getToolEntries();
    for (memory_entries) |entry| {
        try reg.register(entry);
    }

    return reg;
}

// ============================================================================
// tools_schema —— 所有工具的 JSON Schema 定义
// ============================================================================

/// 获取所有工具定义的 JSON Schema 字符串。
/// 可直接发送给 LLM API 的 tools 参数。
pub fn getToolsSchemaJson(allocator: std.mem.Allocator) ![]const u8 {
    var reg = try createDefaultRegistry(allocator);
    defer reg.deinit();

    const schema = try reg.buildToolsSchema();
    defer schema.deinit(allocator);

    return json.toString(allocator, &schema);
}
