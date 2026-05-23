//! json.zig - JSON 解析/序列化模块
//!
//! 基于 Zig 标准库 std.json，提供 Value 类型及便捷的解析、序列化、访问接口。
//! 支持 null, bool, int, float, string, array, object 类型。
//! 处理 Unicode 转义（由 std.json 内部处理）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

// ============================================================================
// Value 类型定义
// ============================================================================

/// JSON Value 联合类型，支持所有标准 JSON 值。
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    array: Array,
    object: Object,

    /// JSON 数组，拥有堆内存。
    pub const Array = std.ArrayList(Value);

    /// JSON 对象，拥有堆内存。
    pub const Object = std.StringHashMap(Value);

    /// 释放 Value 及其所有子值占用的堆内存。
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .null, .bool, .int, .float => {},
            .string => |s| {
                // string 指向的内存由 parseFromString 管理，这里不单独释放。
                // 如果是用户自行创建的 string slice，由调用方管理。
                _ = s;
            },
            .array => |*arr| {
                for (arr.items) |*item| {
                    item.deinit(allocator);
                }
                arr.deinit(allocator);
            },
            .object => |*obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                    allocator.free(entry.key_ptr.*);
                }
                obj.deinit(allocator);
            },
        }
        self.* = .null;
    }

    // ========================================================================
    // 便捷访问器
    // ========================================================================

    /// 获取对象中指定 key 对应的 Value，不存在则返回 null。
    /// 仅在 self 为 .object 时有效。
    pub fn get(self: *const Value, key: []const u8) ?*const Value {
        if (self != .object) return null;
        return self.object.get(key);
    }

    /// 获取对象中指定 key 的字符串值，不存在或类型不匹配则返回 null。
    pub fn getString(self: *const Value, key: []const u8) ?[]const u8 {
        if (self.get(key)) |v| {
            if (v == .string) return v.string;
        }
        return null;
    }

    /// 获取对象中指定 key 的整数值，不存在或类型不匹配则返回 null。
    pub fn getInt(self: *const Value, key: []const u8) ?i64 {
        if (self.get(key)) |v| {
            return switch (v.*) {
                .int => |n| n,
                .float => |f| @intFromFloat(f),
                else => null,
            };
        }
        return null;
    }

    /// 获取对象中指定 key 的浮点数值，不存在或类型不匹配则返回 null。
    pub fn getFloat(self: *const Value, key: []const u8) ?f64 {
        if (self.get(key)) |v| {
            return switch (v.*) {
                .float => |f| f,
                .int => |n| @floatFromInt(n),
                else => null,
            };
        }
        return null;
    }

    /// 获取对象中指定 key 的布尔值，不存在或类型不匹配则返回 null。
    pub fn getBool(self: *const Value, key: []const u8) ?bool {
        if (self.get(key)) |v| {
            if (v == .bool) return v.bool;
        }
        return null;
    }

    /// 获取对象中指定 key 的数组引用，不存在或类型不匹配则返回 null。
    pub fn getArray(self: *const Value, key: []const u8) ?*const Array {
        if (self.get(key)) |v| {
            if (v == .array) return &v.array;
        }
        return null;
    }

    /// 获取对象中指定 key 的对象引用，不存在或类型不匹配则返回 null。
    pub fn getObject(self: *const Value, key: []const u8) ?*const Object {
        if (self.get(key)) |v| {
            if (v == .object) return &v.object;
        }
        return null;
    }

    /// 获取数组中指定索引的 Value，越界则返回 null。
    pub fn atIndex(self: *const Value, index: usize) ?*const Value {
        if (self != .array) return null;
        if (index >= self.array.items.len) return null;
        return &self.array.items[index];
    }
};

// ============================================================================
// 解析：从 std.json 动态树转换为 Value
// ============================================================================

/// 将 std.json.DynamicTree.Node 转换为自定义 Value。
/// 递归地复制所有字符串到 allocator 管理的堆内存。
fn convertFromDynamic(allocator: Allocator, tree: *const json.DynamicTree, node: json.DynamicTree.Node.Index) !Value {
    const data = tree.nodes.items(.data)[@intFromEnum(node)];
    const token = tree.nodes.items(.token)[@intFromEnum(node)];

    switch (data) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .number => |_| {
            // 尝试解析为整数，失败则用浮点数
            const slice = tree.tokens.items(.slice)[@intFromEnum(token)];
            const str = slice orelse "";
            return if (std.fmt.parseInt(i64, str, 10)) |int_val|
                .{ .int = int_val }
            else |_|
                .{ .float = std.fmt.parseFloat(f64, str) catch 0.0 };
        },
        .string => {
            const slice = tree.tokens.items(.slice)[@intFromEnum(token)];
            const raw = slice orelse "";
            // std.json 已处理 Unicode 转义，直接复制
            const owned = try allocator.dupe(u8, raw);
            return .{ .string = owned };
        },
        .array => {
            var arr = Value.Array.init(allocator);
            errdefer {
                for (arr.items) |*item| item.deinit(allocator);
                arr.deinit(allocator);
            }
            const child_idx = tree.firstChild(node);
            while (child_idx != .none) : (child_idx = tree.nextSibling(child_idx)) {
                const child_val = try convertFromDynamic(allocator, tree, child_idx);
                try arr.append(child_val);
            }
            return .{ .array = arr };
        },
        .object => {
            var obj = Value.Object.init(allocator);
            errdefer {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.deinit(allocator);
                    allocator.free(entry.key_ptr.*);
                }
                obj.deinit(allocator);
            }
            var child_idx = tree.firstChild(node);
            while (child_idx != .none) : (child_idx = tree.nextSibling(child_idx)) {
                // object 的子节点是 key-value 对
                const key_node = child_idx;
                const val_node = tree.firstChild(key_node) orelse continue;

                const key_token = tree.nodes.items(.token)[@intFromEnum(key_node)];
                const key_slice = tree.tokens.items(.slice)[@intFromEnum(key_token)];
                const key_str = key_slice orelse "";
                const owned_key = try allocator.dupe(u8, key_str);

                const val = try convertFromDynamic(allocator, tree, val_node);
                try obj.put(owned_key, val);
            }
            return .{ .object = obj };
        },
    }
}

// ============================================================================
// 公共 API
// ============================================================================

/// 从字符串解析 JSON。
/// 调用方负责在不再需要时调用 value.deinit(allocator)。
pub fn parseFromString(allocator: Allocator, input: []const u8) !Value {
    var tree = try json.DynamicTree.init(allocator, .{});
    defer tree.deinit(allocator);

    try tree.parseFromString(input);
    if (tree.root == .none) return error.InvalidJson;

    return convertFromDynamic(allocator, &tree, tree.root);
}

/// 从文件解析 JSON。
/// 调用方负责在不再需要时调用 value.deinit(allocator)。
pub fn parseFromFile(allocator: Allocator, path: []const u8) !Value {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = @as(usize, @intCast(stat.size));
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);

    const bytes_read = try file.readAll(buf);
    const content = buf[0..bytes_read];

    return parseFromString(allocator, content);
}

/// 将 Value 序列化为紧凑 JSON 字符串。
/// 返回的 slice 由 allocator 管理，调用方负责释放。
pub fn toString(allocator: Allocator, value: *const Value) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    errdefer string.deinit(allocator);

    try writeValue(&string, value, .compact);
    return string.toOwnedSlice();
}

/// 将 Value 序列化为美化的 JSON 字符串（带缩进）。
/// 返回的 slice 由 allocator 管理，调用方负责释放。
pub fn toStringPretty(allocator: Allocator, value: *const Value) ![]u8 {
    var string = std.ArrayList(u8).init(allocator);
    errdefer string.deinit(allocator);

    try writeValue(&string, value, .pretty);
    return string.toOwnedSlice();
}

// ============================================================================
// 内部序列化实现
// ============================================================================

const Format = enum { compact, pretty };

fn writeValue(writer: anytype, value: *const Value, format: Format) !void {
    switch (value.*) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |n| try std.fmt.format(writer, "{}", .{n}),
        .float => |f| {
            // 处理特殊浮点值
            if (std.math.isNan(f)) {
                try writer.writeAll("null");
            } else if (std.math.isInf(f)) {
                try writer.writeAll("null");
            } else {
                // 使用科学计数法以保持精度
                try std.fmt.format(writer, "{e}", .{f});
            }
        },
        .string => |s| {
            try writer.writeByte('"');
            try writeEscapedString(writer, s);
            try writer.writeByte('"');
        },
        .array => |*arr| {
            try writer.writeByte('[');
            if (arr.items.len > 0) {
                if (format == .pretty) {
                    try writer.writeAll("\n");
                }
                for (arr.items, 0..) |*item, i| {
                    if (format == .pretty) {
                        try writer.writeAll("  ");
                    }
                    try writeValue(writer, item, format);
                    if (i < arr.items.len - 1) {
                        try writer.writeByte(',');
                    }
                    if (format == .pretty) {
                        try writer.writeAll("\n");
                    }
                }
                if (format == .pretty) {
                    try writer.writeAll("  ");
                }
            }
            try writer.writeByte(']');
        },
        .object => |*obj| {
            try writer.writeByte('{');
            if (obj.count() > 0) {
                if (format == .pretty) {
                    try writer.writeAll("\n");
                }
                var it = obj.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) {
                        try writer.writeByte(',');
                    }
                    first = false;
                    if (format == .pretty) {
                        try writer.writeAll("  ");
                    }
                    // key
                    try writer.writeByte('"');
                    try writeEscapedString(writer, entry.key_ptr.*);
                    try writer.writeAll("\":");
                    if (format == .pretty) {
                        try writer.writeByte(' ');
                    }
                    // value
                    try writeValue(writer, entry.value_ptr, format);
                    if (format == .pretty) {
                        try writer.writeAll("\n");
                    }
                }
            }
            try writer.writeByte('}');
        },
    }
}

/// 写入转义后的 JSON 字符串内容（不含外层引号）。
fn writeEscapedString(writer: anytype, input: []const u8) !void {
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                // 处理需要转义的控制字符 (0x00-0x1F)
                if (ch < 0x20) {
                    try std.fmt.format(writer, "\\u{04x}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
        i += 1;
    }
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "parseFromString - basic types" {
    const allocator = testing.allocator;

    // null
    {
        const val = try parseFromString(allocator, "null");
        defer val.deinit(allocator);
        try testing.expect(val == .null);
    }

    // bool
    {
        const val = try parseFromString(allocator, "true");
        defer val.deinit(allocator);
        try testing.expect(val == .bool);
        try testing.expectEqual(true, val.bool);
    }

    // int
    {
        const val = try parseFromString(allocator, "42");
        defer val.deinit(allocator);
        try testing.expect(val == .int);
        try testing.expectEqual(@as(i64, 42), val.int);
    }

    // float
    {
        const val = try parseFromString(allocator, "3.14");
        defer val.deinit(allocator);
        try testing.expect(val == .float);
        try testing.expectApproxEqAbs(@as(f64, 3.14), val.float, 0.001);
    }

    // string
    {
        const val = try parseFromString(allocator, "\"hello world\"");
        defer val.deinit(allocator);
        try testing.expect(val == .string);
        try testing.expectEqualStrings("hello world", val.string);
    }
}

test "parseFromString - unicode escape" {
    const allocator = testing.allocator;

    const val = try parseFromString(allocator, "\"\\u00e9\\u4f60\\u597d\"");
    defer val.deinit(allocator);
    try testing.expect(val == .string);
    // std.json 处理 \u00e9 -> \xc3\xa9 (UTF-8 for e with acute)
    // \u4f60\u597d -> 你好
    try testing.expectEqualStrings("\xc3\xa9\xe4\xbd\xa0\xe5\xa5\xbd", val.string);
}

test "parseFromString - array" {
    const allocator = testing.allocator;

    const val = try parseFromString(allocator, "[1, \"two\", true, null]");
    defer val.deinit(allocator);
    try testing.expect(val == .array);
    try testing.expectEqual(@as(usize, 4), val.array.items.len);
    try testing.expectEqual(@as(i64, 1), val.array.items[0].int);
    try testing.expectEqualStrings("two", val.array.items[1].string);
    try testing.expectEqual(true, val.array.items[2].bool);
    try testing.expect(val.array.items[3] == .null);
}

test "parseFromString - object with accessors" {
    const allocator = testing.allocator;

    const input =
        \\{
        \\  "name": "test",
        \\  "age": 25,
        \\  "score": 98.5,
        \\  "active": true,
        \\  "tags": ["a", "b"],
        \\  "meta": {"key": "value"}
        \\}
    ;
    const val = try parseFromString(allocator, input);
    defer val.deinit(allocator);

    try testing.expect(val == .object);

    // getString
    try testing.expectEqualStrings("test", val.getString("name").?);

    // getInt
    try testing.expectEqual(@as(i64, 25), val.getInt("age").?);

    // getFloat
    try testing.expectApproxEqAbs(@as(f64, 98.5), val.getFloat("score").?, 0.01);

    // getBool
    try testing.expectEqual(true, val.getBool("active").?);

    // getArray
    const tags = val.getArray("tags").?;
    try testing.expectEqual(@as(usize, 2), tags.items.len);

    // getObject
    const meta = val.getObject("meta").?;
    try testing.expectEqualStrings("value", meta.get("key").?.string);

    // non-existent key
    try testing.expect(val.getString("nonexistent") == null);
}

test "toString - compact" {
    const allocator = testing.allocator;

    var obj = Value.Object.init(allocator);
    defer {
        var it = obj.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        obj.deinit(allocator);
    }

    const key = try allocator.dupe(u8, "x");
    try obj.put(key, .{ .int = 1 });

    const val = Value{ .object = obj };
    const result = try toString(allocator, &val);
    defer allocator.free(result);

    try testing.expectEqualStrings("{\"x\":1}", result);
}

test "toStringPretty - formatted" {
    const allocator = testing.allocator;

    var obj = Value.Object.init(allocator);
    defer {
        var it = obj.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        obj.deinit(allocator);
    }

    const key = try allocator.dupe(u8, "a");
    try obj.put(key, .{ .int = 1 });

    const val = Value{ .object = obj };
    const result = try toStringPretty(allocator, &val);
    defer allocator.free(result);

    try testing.expectEqualStrings("{\n  \"a\": 1\n}", result);
}

test "atIndex accessor" {
    const allocator = testing.allocator;

    const val = try parseFromString(allocator, "[10, 20, 30]");
    defer val.deinit(allocator);

    try testing.expectEqual(@as(i64, 10), val.atIndex(0).?.int);
    try testing.expectEqual(@as(i64, 20), val.atIndex(1).?.int);
    try testing.expectEqual(@as(i64, 30), val.atIndex(2).?.int);
    try testing.expect(val.atIndex(3) == null);
}
