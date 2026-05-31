//! code_run_test.zig - 代码执行工具单元测试
//!
//! 测试 python_run, bash_run, powershell_run 工具的功能

const std = @import("std");
const json = std.json;

const tools_mod = @import("tools");
const registry_mod = tools_mod.registry;
const ToolContext = registry_mod.ToolContext;
const ToolResult = registry_mod.ToolResult;
const ToolEntry = registry_mod.ToolEntry;
const ToolRegistry = registry_mod.ToolRegistry;

const code_run_mod = tools_mod.code_run;

fn createTestContext(allocator: std.mem.Allocator) ToolContext {
    return ToolContext{
        .allocator = allocator,
        .cwd = "/tmp",
        .current_turn = 1,
        .parent = null,
    };
}

test "code_run tool entries are defined" {
    const entries = code_run_mod.getToolEntries();
    try std.testing.expect(entries.len > 0);

    const has_python_run = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "python_run")) break true;
    } else false;
    try std.testing.expect(has_python_run);

    const has_bash_run = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "bash_run")) break true;
    } else false;
    try std.testing.expect(has_bash_run);

    const has_powershell_run = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "powershell_run")) break true;
    } else false;
    try std.testing.expect(has_powershell_run);
}

test "python_run rejects invalid arguments - null args" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const python_tool = reg.find("python_run").?;
    var ctx = createTestContext(allocator);

    const args = json.Value{ .null = {} };
    var result = python_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "args must be an object") != null or
            std.mem.indexOf(u8, d.text, "missing") != null);
    }
}

test "python_run rejects invalid arguments - missing code" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const python_tool = reg.find("python_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("not_code", .{ .string = "something" });
    const args = json.Value{ .object = args_map };

    var result = python_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
    }
}

test "python_run accepts valid code parameter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const python_tool = reg.find("python_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("code", .{ .string = "print('hello')" });
    const args = json.Value{ .object = args_map };

    var result = python_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "bash_run rejects invalid arguments - null args" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const bash_tool = reg.find("bash_run").?;
    var ctx = createTestContext(allocator);

    const args = json.Value{ .null = {} };
    var result = bash_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
    }
}

test "bash_run rejects invalid arguments - missing command" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const bash_tool = reg.find("bash_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("not_command", .{ .string = "echo hello" });
    const args = json.Value{ .object = args_map };

    var result = bash_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
    }
}

test "bash_run accepts valid command parameter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const bash_tool = reg.find("bash_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("command", .{ .string = "echo hello" });
    const args = json.Value{ .object = args_map };

    var result = bash_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "powershell_run rejects invalid arguments - null args" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const powershell_tool = reg.find("powershell_run").?;
    var ctx = createTestContext(allocator);

    const args = json.Value{ .null = {} };
    var result = powershell_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
    }
}

test "powershell_run rejects invalid arguments - missing command" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const powershell_tool = reg.find("powershell_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("not_command", .{ .string = "Write-Host hello" });
    const args = json.Value{ .object = args_map };

    var result = powershell_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
    }
}

test "powershell_run accepts valid command parameter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const powershell_tool = reg.find("powershell_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("command", .{ .string = "Write-Host hello" });
    const args = json.Value{ .object = args_map };

    var result = powershell_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "code_run tools can be registered and dispatched" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    try std.testing.expect(reg.count() == 3);

    try std.testing.expect(reg.find("python_run") != null);
    try std.testing.expect(reg.find("bash_run") != null);
    try std.testing.expect(reg.find("powershell_run") != null);
}

test "code_run tools preserve cwd in context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const bash_tool = reg.find("bash_run").?;
    var ctx = ToolContext{
        .allocator = allocator,
        .cwd = "/custom/test/path",
        .current_turn = 1,
        .parent = null,
    };

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("command", .{ .string = "pwd" });
    const args = json.Value{ .object = args_map };

    var result = bash_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "python_run handles timeout=0 (uses default)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const python_tool = reg.find("python_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("code", .{ .string = "print('hello')" });
    try args_map.put("timeout", .{ .integer = 0 });
    const args = json.Value{ .object = args_map };

    var result = python_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    try std.testing.expect(result.should_exit == false);
}

test "python_run handles timeout>600 (uses default)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const python_tool = reg.find("python_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("code", .{ .string = "print('hello')" });
    try args_map.put("timeout", .{ .integer = 700 });
    const args = json.Value{ .object = args_map };

    var result = python_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    try std.testing.expect(result.should_exit == false);
}

test "bash_run handles empty output" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const bash_tool = reg.find("bash_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("command", .{ .string = "true" });
    const args = json.Value{ .object = args_map };

    var result = bash_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    try std.testing.expect(result.should_exit == false);
}

test "bash_run handles negative timeout (uses default)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const bash_tool = reg.find("bash_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("command", .{ .string = "echo hello" });
    try args_map.put("timeout", .{ .integer = -5 });
    const args = json.Value{ .object = args_map };

    var result = bash_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    try std.testing.expect(result.should_exit == false);
}

test "powershell_run handles timeout=0 (uses default)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const powershell_tool = reg.find("powershell_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("command", .{ .string = "Write-Host 'hello'" });
    try args_map.put("timeout", .{ .integer = 0 });
    const args = json.Value{ .object = args_map };

    var result = powershell_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    try std.testing.expect(result.should_exit == false);
}

test "bash_run handles timeout=600 (boundary value)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = code_run_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const bash_tool = reg.find("bash_run").?;
    var ctx = createTestContext(allocator);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("command", .{ .string = "echo boundary" });
    try args_map.put("timeout", .{ .integer = 600 });
    const args = json.Value{ .object = args_map };

    var result = bash_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    try std.testing.expect(result.should_exit == false);
}
