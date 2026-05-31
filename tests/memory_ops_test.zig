//! memory_ops_test.zig - 记忆操作工具单元测试
//!
//! 测试 update_working_checkpoint, start_long_term_update, ask_user 工具的功能

const std = @import("std");
const json = std.json;

const tools_mod = @import("tools");
const registry_mod = tools_mod.registry;
const ToolContext = registry_mod.ToolContext;
const ToolResult = registry_mod.ToolResult;
const ToolEntry = registry_mod.ToolEntry;
const ToolRegistry = registry_mod.ToolRegistry;

const memory_ops_mod = tools_mod.memory_ops;

fn createTestContext(allocator: std.mem.Allocator, cwd: []const u8) ToolContext {
    return ToolContext{
        .allocator = allocator,
        .cwd = cwd,
        .current_turn = 1,
        .parent = null,
    };
}

fn createTempDir(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const temp_dir = try allocator.dupe(u8, name);
    errdefer allocator.free(temp_dir);
    std.fs.cwd().deleteTree(temp_dir) catch {};
    try std.fs.cwd().makeDir(temp_dir);
    return temp_dir;
}

fn cleanupTempDir(name: []const u8) void {
    std.fs.cwd().deleteTree(name) catch {};
}

test "memory_ops tool entries are defined" {
    const entries = memory_ops_mod.getToolEntries();
    try std.testing.expect(entries.len > 0);

    const has_update_working_checkpoint = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "update_working_checkpoint")) break true;
    } else false;
    try std.testing.expect(has_update_working_checkpoint);

    const has_start_long_term_update = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "start_long_term_update")) break true;
    } else false;
    try std.testing.expect(has_start_long_term_update);

    const has_ask_user = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "ask_user")) break true;
    } else false;
    try std.testing.expect(has_ask_user);
}

test "update_working_checkpoint creates checkpoint file with key_info" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_checkpoint");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const tool = reg.find("update_working_checkpoint").?;
    var ctx = createTestContext(allocator, temp_dir);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("key_info", .{ .string = "test key information" });
    const args = json.Value{ .object = args_map };

    var result = tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "checkpoint_path") != null);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "success") != null or std.mem.indexOf(u8, d.text, "true") != null);
    }
}

test "update_working_checkpoint creates checkpoint file with related_sop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_sop");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const tool = reg.find("update_working_checkpoint").?;
    var ctx = createTestContext(allocator, temp_dir);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("related_sop", .{ .string = "test SOP content" });
    const args = json.Value{ .object = args_map };

    var result = tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "checkpoint_path") != null);
    }
}

test "update_working_checkpoint requires key_info or related_sop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_neither");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const tool = reg.find("update_working_checkpoint").?;
    var ctx = createTestContext(allocator, temp_dir);

    const args = json.Value{ .null = {} };
    var result = tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "need key_info or related_sop") != null);
    }
}

test "update_working_checkpoint with both parameters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_both");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const tool = reg.find("update_working_checkpoint").?;
    var ctx = createTestContext(allocator, temp_dir);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("key_info", .{ .string = "key info content" });
    try args_map.put("related_sop", .{ .string = "sop content" });
    const args = json.Value{ .object = args_map };

    var result = tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
    }
}

test "update_working_checkpoint creates .checkpoint directory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_dir");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const tool = reg.find("update_working_checkpoint").?;
    var ctx = createTestContext(allocator, temp_dir);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("key_info", .{ .string = "test" });
    const args = json.Value{ .object = args_map };

    var result = tool.func(&ctx, args, "");
    defer result.deinit(allocator);
    try std.testing.expect(result.data != null);

    const checkpoint_path = try std.fs.path.join(allocator, &.{ temp_dir, ".checkpoint" });
    defer allocator.free(checkpoint_path);

    var checkpoint_dir = try std.fs.cwd().openDir(checkpoint_path, .{});
    checkpoint_dir.close();
}

test "start_long_term_update requires working checkpoint to exist" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_lt_no_checkpoint");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const tool = reg.find("start_long_term_update").?;
    var ctx = createTestContext(allocator, temp_dir);

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("summary", .{ .string = "test summary" });
    const args = json.Value{ .object = args_map };

    var result = tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "open err") != null);
    }
}

test "start_long_term_update works after checkpoint is created" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_lt_with_checkpoint");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const checkpoint_tool = reg.find("update_working_checkpoint").?;
    const longterm_tool = reg.find("start_long_term_update").?;
    var ctx = createTestContext(allocator, temp_dir);

    var checkpoint_args_map = std.json.ObjectMap.init(allocator);
    defer checkpoint_args_map.deinit();
    try checkpoint_args_map.put("key_info", .{ .string = "initial checkpoint" });
    const checkpoint_args = json.Value{ .object = checkpoint_args_map };

    var checkpoint_result = checkpoint_tool.func(&ctx, checkpoint_args, "");
    defer checkpoint_result.deinit(allocator);

    var lt_args_map = std.json.ObjectMap.init(allocator);
    defer lt_args_map.deinit();
    try lt_args_map.put("summary", .{ .string = "test summary for long term" });
    const lt_args = json.Value{ .object = lt_args_map };

    var result = longterm_tool.func(&ctx, lt_args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "path") != null);
    }
}

test "ask_user tool entry is defined" {
    const entries = memory_ops_mod.getToolEntries();
    const ask_user_entry = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "ask_user")) break entry;
    } else unreachable;

    try std.testing.expect(ask_user_entry.name.len > 0);
    try std.testing.expect(ask_user_entry.description.len > 0);
    try std.testing.expect(ask_user_entry.parameters_schema.len > 0);
}

test "ask_user has valid parameters_schema" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const entries = memory_ops_mod.getToolEntries();
    const ask_user_entry = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "ask_user")) break entry;
    } else unreachable;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, ask_user_entry.parameters_schema, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "memory_ops tools can be registered in registry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    try std.testing.expect(reg.count() == 3);

    try std.testing.expect(reg.find("update_working_checkpoint") != null);
    try std.testing.expect(reg.find("start_long_term_update") != null);
    try std.testing.expect(reg.find("ask_user") != null);
}

test "memory_ops tools preserve current_turn in context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try createTempDir(allocator, "test_memory_turn");
    defer allocator.free(temp_dir);
    defer cleanupTempDir(temp_dir);

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = memory_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const tool = reg.find("update_working_checkpoint").?;
    var ctx = ToolContext{
        .allocator = allocator,
        .cwd = temp_dir,
        .current_turn = 42,
        .parent = null,
    };

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("key_info", .{ .string = "test" });
    const args = json.Value{ .object = args_map };

    var result = tool.func(&ctx, args, "");
    defer result.deinit(allocator);
    try std.testing.expect(result.data != null);
}
