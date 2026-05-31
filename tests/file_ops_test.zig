//! file_ops_test.zig - 文件操作工具单元测试
//!
//! 测试 file_read, file_write, file_patch 工具的功能

const std = @import("std");
const json = std.json;

const tools_mod = @import("tools");
const registry_mod = tools_mod.registry;
const ToolContext = registry_mod.ToolContext;
const ToolResult = registry_mod.ToolResult;
const ToolEntry = registry_mod.ToolEntry;
const ToolRegistry = registry_mod.ToolRegistry;

const file_ops_mod = tools_mod.file_ops;

const TestDir = struct {
    name: []const u8,
    fn create(name: []const u8) !TestDir {
        std.fs.cwd().deleteTree(name) catch {};
        try std.fs.cwd().makeDir(name);
        return TestDir{ .name = name };
    }
    fn cleanup(self: TestDir) void {
        std.fs.cwd().deleteTree(self.name) catch {};
    }
};

fn createTestContext(allocator: std.mem.Allocator, cwd: []const u8) ToolContext {
    return ToolContext{
        .allocator = allocator,
        .cwd = cwd,
        .current_turn = 1,
        .parent = null,
    };
}

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    const file = try dir.createFile(path, .{ .mode = 0o666 });
    defer file.close();
    try file.writeAll(data);
}

test "file_ops tool entries are defined" {
    const entries = file_ops_mod.getToolEntries();
    try std.testing.expect(entries.len > 0);

    const has_file_read = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "file_read")) break true;
    } else false;
    try std.testing.expect(has_file_read);

    const has_file_write = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "file_write")) break true;
    } else false;
    try std.testing.expect(has_file_write);

    const has_file_patch = for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "file_patch")) break true;
    } else false;
    try std.testing.expect(has_file_patch);
}

test "file_read can read existing file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_read");
    defer temp_dir.cleanup();

    try writeFile(std.fs.cwd(), "test_file_read/test.txt", "Hello, World!");

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_read_tool = reg.find("file_read").?;
    var ctx = createTestContext(allocator, "test_file_read");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "test.txt" });
    const args = json.Value{ .object = args_map };

    var result = file_read_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "Hello, World!") != null);
    }
}

test "file_read can read with keyword filter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_read_keyword");
    defer temp_dir.cleanup();

    try writeFile(std.fs.cwd(), "test_file_read_keyword/test.txt", "Line 1: Hello\nLine 2: World\nLine 3: Test");

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_read_tool = reg.find("file_read").?;
    var ctx = createTestContext(allocator, "test_file_read_keyword");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "test.txt" });
    try args_map.put("keyword", .{ .string = "World" });
    const args = json.Value{ .object = args_map };

    var result = file_read_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
    if (result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "World") != null);
    }
}

test "file_read handles nonexistent file gracefully" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_read_nonexistent");
    defer temp_dir.cleanup();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_read_tool = reg.find("file_read").?;
    var ctx = createTestContext(allocator, "test_file_read_nonexistent");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "nonexistent.txt" });
    const args = json.Value{ .object = args_map };

    var result = file_read_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "file_write can create new file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_write_new");
    defer temp_dir.cleanup();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_write_tool = reg.find("file_write").?;
    var ctx = createTestContext(allocator, "test_file_write_new");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "new_file.txt" });
    try args_map.put("content", .{ .string = "New content here" });
    const args = json.Value{ .object = args_map };

    var result = file_write_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);

    const file = try std.fs.cwd().openFile("test_file_write_new/new_file.txt", .{});
    defer file.close();
    const stat = try file.stat();
    const file_content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(file_content);
    try std.testing.expect(std.mem.eql(u8, file_content, "New content here"));
}

test "file_write can overwrite existing file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_write_overwrite");
    defer temp_dir.cleanup();

    try writeFile(std.fs.cwd(), "test_file_write_overwrite/test.txt", "Original content");

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_write_tool = reg.find("file_write").?;
    var ctx = createTestContext(allocator, "test_file_write_overwrite");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "test.txt" });
    try args_map.put("content", .{ .string = "New content" });
    try args_map.put("mode", .{ .string = "overwrite" });
    const args = json.Value{ .object = args_map };

    var result = file_write_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);

    const file = try std.fs.cwd().openFile("test_file_write_overwrite/test.txt", .{});
    defer file.close();
    const stat = try file.stat();
    const file_content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(file_content);
    try std.testing.expect(std.mem.eql(u8, file_content, "New content"));
}

test "file_write supports append mode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_write_append");
    defer temp_dir.cleanup();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_write_tool = reg.find("file_write").?;
    var ctx = createTestContext(allocator, "test_file_write_append");

    {
        var args_map = std.json.ObjectMap.init(allocator);
        defer args_map.deinit();
        try args_map.put("path", .{ .string = "append_test.txt" });
        try args_map.put("content", .{ .string = "First line\n" });
        const args = json.Value{ .object = args_map };

        var result = file_write_tool.func(&ctx, args, "");
        defer result.deinit(allocator);
    }

    {
        var args_map = std.json.ObjectMap.init(allocator);
        defer args_map.deinit();
        try args_map.put("path", .{ .string = "append_test.txt" });
        try args_map.put("content", .{ .string = "Second line\n" });
        try args_map.put("mode", .{ .string = "append" });
        const args = json.Value{ .object = args_map };

        var result = file_write_tool.func(&ctx, args, "");
        defer result.deinit(allocator);
    }

    const file = try std.fs.cwd().openFile("test_file_write_append/append_test.txt", .{});
    defer file.close();
    const stat = try file.stat();
    const file_content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "First line") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Second line") != null);
}

test "file_write supports prepend mode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_write_prepend");
    defer temp_dir.cleanup();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_write_tool = reg.find("file_write").?;
    var ctx = createTestContext(allocator, "test_file_write_prepend");

    {
        var args_map = std.json.ObjectMap.init(allocator);
        defer args_map.deinit();
        try args_map.put("path", .{ .string = "prepend_test.txt" });
        try args_map.put("content", .{ .string = "Original content" });
        const args = json.Value{ .object = args_map };

        var result = file_write_tool.func(&ctx, args, "");
        defer result.deinit(allocator);
    }

    {
        var args_map = std.json.ObjectMap.init(allocator);
        defer args_map.deinit();
        try args_map.put("path", .{ .string = "prepend_test.txt" });
        try args_map.put("content", .{ .string = "PREFIX: " });
        try args_map.put("mode", .{ .string = "prepend" });
        const args = json.Value{ .object = args_map };

        var result = file_write_tool.func(&ctx, args, "");
        defer result.deinit(allocator);
    }

    const file = try std.fs.cwd().openFile("test_file_write_prepend/prepend_test.txt", .{});
    defer file.close();
    const stat = try file.stat();
    const file_content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(file_content);

    try std.testing.expect(std.mem.startsWith(u8, file_content, "PREFIX: Original content"));
}

test "file_patch can replace content in file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_patch");
    defer temp_dir.cleanup();

    try writeFile(std.fs.cwd(), "test_file_patch/test.txt", "Hello OLD-World!");

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_patch_tool = reg.find("file_patch").?;
    var ctx = createTestContext(allocator, "test_file_patch");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "test.txt" });
    try args_map.put("old_content", .{ .string = "OLD-World" });
    try args_map.put("new_content", .{ .string = "NEW-World" });
    const args = json.Value{ .object = args_map };

    var result = file_patch_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);

    const file = try std.fs.cwd().openFile("test_file_patch/test.txt", .{});
    defer file.close();
    const stat = try file.stat();
    const file_content = try file.readToEndAlloc(allocator, stat.size);
    defer allocator.free(file_content);

    try std.testing.expect(std.mem.eql(u8, file_content, "Hello NEW-World!"));
}

test "file_patch handles when old_content not found" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_patch_not_found");
    defer temp_dir.cleanup();

    try writeFile(std.fs.cwd(), "test_file_patch_not_found/test.txt", "Hello World!");

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_patch_tool = reg.find("file_patch").?;
    var ctx = createTestContext(allocator, "test_file_patch_not_found");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "test.txt" });
    try args_map.put("old_content", .{ .string = "NONEXISTENT" });
    try args_map.put("new_content", .{ .string = "REPLACEMENT" });
    const args = json.Value{ .object = args_map };

    var result = file_patch_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "file_ops tools reject invalid path in nonexistent cwd" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_read_tool = reg.find("file_read").?;
    var ctx = ToolContext{
        .allocator = allocator,
        .cwd = "/nonexistent/path/that/should/never/exist",
        .current_turn = 1,
        .parent = null,
    };

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "test.txt" });
    const args = json.Value{ .object = args_map };

    var result = file_read_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "file_read supports start and count parameters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_read_range");
    defer temp_dir.cleanup();

    try writeFile(std.fs.cwd(), "test_file_read_range/test.txt", "0123456789ABCDEF");

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_read_tool = reg.find("file_read").?;
    var ctx = createTestContext(allocator, "test_file_read_range");

    var args_map = std.json.ObjectMap.init(allocator);
    defer args_map.deinit();
    try args_map.put("path", .{ .string = "test.txt" });
    try args_map.put("start", .{ .integer = 0 });
    try args_map.put("count", .{ .integer = 5 });
    const args = json.Value{ .object = args_map };

    var result = file_read_tool.func(&ctx, args, "");
    defer result.deinit(allocator);

    try std.testing.expect(result.data != null);
}

test "file_write and file_read integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const temp_dir = try TestDir.create("test_file_ops_integration");
    defer temp_dir.cleanup();

    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const entries = file_ops_mod.getToolEntries();
    for (entries) |entry| {
        try reg.register(entry);
    }

    const file_write_tool = reg.find("file_write").?;
    const file_read_tool = reg.find("file_read").?;
    var ctx = createTestContext(allocator, "test_file_ops_integration");

    var write_args_map = std.json.ObjectMap.init(allocator);
    defer write_args_map.deinit();
    try write_args_map.put("path", .{ .string = "integration_test.txt" });
    try write_args_map.put("content", .{ .string = "Integration test content!" });
    const write_args = json.Value{ .object = write_args_map };

    var write_result = file_write_tool.func(&ctx, write_args, "");
    defer write_result.deinit(allocator);
    try std.testing.expect(write_result.data != null);

    var read_args_map = std.json.ObjectMap.init(allocator);
    defer read_args_map.deinit();
    try read_args_map.put("path", .{ .string = "integration_test.txt" });
    const read_args = json.Value{ .object = read_args_map };

    var read_result = file_read_tool.func(&ctx, read_args, "");
    defer read_result.deinit(allocator);

    try std.testing.expect(read_result.data != null);
    if (read_result.data) |d| {
        try std.testing.expect(d == .text);
        try std.testing.expect(std.mem.indexOf(u8, d.text, "Integration test content!") != null);
    }
}
