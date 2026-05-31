//! tools_test.zig - 工具注册表核心单元测试
//!
//! 测试 ToolRegistry, ToolResult, ToolEntry, ToolContext 等核心组件
//! 以及跨工具的综合集成测试
//!
//! 各工具的独立测试请参考:
//! - tests/file_ops_test.zig - file_read/file_write/file_patch
//! - tests/code_run_test.zig - python_run/bash_run/powershell_run
//! - tests/memory_ops_test.zig - update_working_checkpoint/ask_user
//! - tests/web_ops_test.zig - web_scan/web_execute_js

const std = @import("std");
const json = std.json;

const tools_mod = @import("tools");
const registry_mod = tools_mod.registry;
const ToolContext = registry_mod.ToolContext;
const ToolResult = registry_mod.ToolResult;
const ToolEntry = registry_mod.ToolEntry;
const ToolRegistry = registry_mod.ToolRegistry;

test "ToolResult.textResult creates valid result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ToolResult.textResult(allocator, "hello world");

    try std.testing.expect(result.should_exit == false);
    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.eql(u8, d.text, "hello world"));
    }

    result.deinit(allocator);
}

test "ToolResult.errorResult creates error result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ToolResult.errorResult(allocator, "error message");

    try std.testing.expect(result.should_exit == false);
    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.eql(u8, d.text, "error message"));
    }

    result.deinit(allocator);
}

test "ToolResult.exitResult creates exit result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ToolResult.exitResult(allocator, "goodbye");

    try std.testing.expect(result.should_exit == true);
    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.eql(u8, d.text, "goodbye"));
    }

    result.deinit(allocator);
}

test "ToolResult data can be text" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ToolResult.textResult(allocator, "hello");

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.eql(u8, d.text, "hello"));
    }
    try std.testing.expect(result.next_prompt == null);
    try std.testing.expect(result.should_exit == false);

    result.deinit(allocator);
}

test "ToolResult data can be json value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const json_val = json.Value{ .integer = 42 };
    var result = ToolResult.jsonResult(json_val);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .value);
        try std.testing.expect(d.value == .integer);
        try std.testing.expect(d.value.integer == 42);
    }

    result.deinit(allocator);
}

test "ToolEntry has valid structure" {
    const entry: ToolEntry = .{
        .name = "test",
        .description = "Test description",
        .parameters_schema = "{\"type\": \"object\"}",
        .func = struct {
            fn call(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
                _ = args;
                _ = response;
                return ToolResult.textResult(ctx.allocator, "ok");
            }
        }.call,
    };

    try std.testing.expect(std.mem.eql(u8, entry.name, "test"));
    try std.testing.expect(std.mem.eql(u8, entry.description, "Test description"));
    try std.testing.expect(std.mem.eql(u8, entry.parameters_schema, "{\"type\": \"object\"}"));
}

test "ToolContext can be created" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = ToolContext{
        .allocator = allocator,
        .cwd = try allocator.dupe(u8, "/test/path"),
        .current_turn = 5,
        .parent = null,
    };
    defer allocator.free(ctx.cwd);

    try std.testing.expect(ctx.cwd.len == 10);
    try std.testing.expect(ctx.current_turn == 5);
    try std.testing.expect(ctx.parent == null);
}

test "ToolContext with parent reference" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parent_ctx = ToolContext{
        .allocator = allocator,
        .cwd = try allocator.dupe(u8, "/parent/path"),
        .current_turn = 1,
        .parent = null,
    };
    defer allocator.free(parent_ctx.cwd);

    const child_ctx = ToolContext{
        .allocator = allocator,
        .cwd = try allocator.dupe(u8, "/child/path"),
        .current_turn = 2,
        .parent = &parent_ctx,
    };
    defer allocator.free(child_ctx.cwd);

    try std.testing.expect(child_ctx.parent != null);
}

test "ToolRegistry can register and find tools" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const test_tool: ToolEntry = .{
        .name = "test_tool",
        .description = "A test tool",
        .parameters_schema = "{}",
        .func = struct {
            fn call(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
                _ = args;
                _ = response;
                return ToolResult.textResult(ctx.allocator, "test");
            }
        }.call,
    };

    try reg.register(test_tool);

    const found = reg.find("test_tool");
    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.eql(u8, found.?.name, "test_tool"));
}

test "ToolRegistry returns null for non-existent tool" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const found = reg.find("non_existent_tool");
    try std.testing.expect(found == null);
}

test "ToolRegistry.getToolNames returns registered names" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const test_tool1: ToolEntry = .{
        .name = "tool1",
        .description = "Tool 1",
        .parameters_schema = "{}",
        .func = struct {
            fn call(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
                _ = args;
                _ = response;
                return ToolResult.textResult(ctx.allocator, "");
            }
        }.call,
    };

    const test_tool2: ToolEntry = .{
        .name = "tool2",
        .description = "Tool 2",
        .parameters_schema = "{}",
        .func = struct {
            fn call(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
                _ = args;
                _ = response;
                return ToolResult.textResult(ctx.allocator, "");
            }
        }.call,
    };

    try reg.register(test_tool1);
    try reg.register(test_tool2);

    const names = reg.getToolNames();
    try std.testing.expect(names.len == 2);
}

test "ToolRegistry dispatch calls correct function" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const test_tool: ToolEntry = .{
        .name = "dispatch_test",
        .description = "Test dispatch",
        .parameters_schema = "{}",
        .func = struct {
            fn call(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
                _ = args;
                _ = response;
                return ToolResult.textResult(ctx.allocator, "dispatched");
            }
        }.call,
    };

    try reg.register(test_tool);

    var ctx = ToolContext{
        .allocator = allocator,
        .cwd = "/tmp",
        .current_turn = 1,
    };

    const args = json.Value{ .null = {} };
    var result = reg.dispatch(&ctx, "dispatch_test", args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.eql(u8, d.text, "dispatched"));
    }
}

test "ToolRegistry dispatch - tool not found returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var ctx = ToolContext{
        .allocator = allocator,
        .cwd = "/tmp",
        .current_turn = 1,
    };

    const args = json.Value{ .null = {} };
    var result = reg.dispatch(&ctx, "nonexistent", args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "tool not found") != null);
    }
}

test "ToolRegistry count returns correct value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try std.testing.expect(reg.count() == 0);

    const test_tool_func = struct {
        fn call(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
            _ = args;
            _ = response;
            return ToolResult.textResult(ctx.allocator, "");
        }
    }.call;

    const test_tool: ToolEntry = .{
        .name = "count_test",
        .description = "Test count",
        .parameters_schema = "{}",
        .func = test_tool_func,
    };

    try reg.register(test_tool);
    try std.testing.expect(reg.count() == 1);

    try reg.register(.{
        .name = "count_test2",
        .description = "Test count 2",
        .parameters_schema = "{}",
        .func = test_tool_func,
    });
    try std.testing.expect(reg.count() == 2);
}

test "createDefaultRegistry registers all tools" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = try tools_mod.createDefaultRegistry(allocator);
    defer reg.deinit();

    const tool_names = reg.getToolNames();

    const has_file_read = for (tool_names) |name| {
        if (std.mem.eql(u8, name, "file_read")) break true;
    } else false;
    try std.testing.expect(has_file_read);

    const has_file_write = for (tool_names) |name| {
        if (std.mem.eql(u8, name, "file_write")) break true;
    } else false;
    try std.testing.expect(has_file_write);

    const has_python_run = for (tool_names) |name| {
        if (std.mem.eql(u8, name, "python_run")) break true;
    } else false;
    try std.testing.expect(has_python_run);

    const has_update_working_checkpoint = for (tool_names) |name| {
        if (std.mem.eql(u8, name, "update_working_checkpoint")) break true;
    } else false;
    try std.testing.expect(has_update_working_checkpoint);

    const has_web_scan = for (tool_names) |name| {
        if (std.mem.eql(u8, name, "web_scan")) break true;
    } else false;
    try std.testing.expect(has_web_scan);
}

test "createDefaultRegistry has correct tool count" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = try tools_mod.createDefaultRegistry(allocator);
    defer reg.deinit();

    try std.testing.expect(reg.count() > 0);
    try std.testing.expect(reg.count() == 11);
}

test "ToolRegistry deinit can be called multiple times safely" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    try reg.register(.{
        .name = "test",
        .description = "Test",
        .parameters_schema = "{}",
        .func = struct {
            fn call(ctx: *ToolContext, args: json.Value, response: []const u8) ToolResult {
                _ = args;
                _ = response;
                return ToolResult.textResult(ctx.allocator, "");
            }
        }.call,
    });

    reg.deinit();
    reg.deinit();
}

test "ToolResult can be created with empty string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = ToolResult.textResult(allocator, "");

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(d.text.len == 0);
    }

    result.deinit(allocator);
}

test "ToolResult jsonResult with different value types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const bool_val = json.Value{ .bool = true };
    var bool_result = ToolResult.jsonResult(bool_val);
    try std.testing.expect(bool_result.data != null);
    bool_result.deinit(allocator);

    var array_list = std.ArrayList(json.Value).init(allocator);
    defer array_list.deinit();
    const array_val = json.Value{ .array = array_list };
    var array_result = ToolResult.jsonResult(array_val);
    try std.testing.expect(array_result.data != null);
    array_result.deinit(allocator);
}
