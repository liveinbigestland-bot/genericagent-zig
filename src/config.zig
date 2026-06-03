const std = @import("std");

pub const Config = struct {
    api_key: []const u8,
    api_base: []const u8,
    model: []const u8,
    session_type: []const u8,
    language: []const u8,
    enable_logging: bool = false,
    log_dir: []const u8 = "logs",
    log_level: []const u8 = "info",

    // DeepSeek 思考模式配置
    enable_thinking: bool = false,
    reasoning_effort: []const u8 = "high",

    // Agent 循环配置
    max_turns: u32 = 40,
    verbose: bool = true,

    // Token 优化配置
    enable_sliding_window: bool = true,
    max_history_messages: u32 = 20,
    max_tool_result_length: u32 = 2000,

    // 动态工具选择配置
    enable_dynamic_tools: bool = true,
    max_dynamic_tools: u32 = 10,

    // 代理配置
    proxy_host: ?[]const u8 = null,
    proxy_port: ?u16 = null,
    proxy_type: []const u8 = "http",

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);

        const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        return .{
            .api_key = try allocator.dupe(u8, parsed.value.api_key),
            .api_base = try allocator.dupe(u8, parsed.value.api_base),
            .model = try allocator.dupe(u8, parsed.value.model),
            .session_type = try allocator.dupe(u8, parsed.value.session_type),
            .language = try allocator.dupe(u8, parsed.value.language),
            .enable_logging = parsed.value.enable_logging,
            .log_dir = try allocator.dupe(u8, parsed.value.log_dir),
            .log_level = try allocator.dupe(u8, parsed.value.log_level),
            .enable_thinking = parsed.value.enable_thinking,
            .reasoning_effort = try allocator.dupe(u8, parsed.value.reasoning_effort),
            .max_turns = parsed.value.max_turns,
            .verbose = parsed.value.verbose,
            .enable_sliding_window = parsed.value.enable_sliding_window,
            .max_history_messages = parsed.value.max_history_messages,
            .max_tool_result_length = parsed.value.max_tool_result_length,
            .enable_dynamic_tools = parsed.value.enable_dynamic_tools,
            .max_dynamic_tools = parsed.value.max_dynamic_tools,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.api_base);
        allocator.free(self.model);
        allocator.free(self.session_type);
        allocator.free(self.language);
        allocator.free(self.log_dir);
        allocator.free(self.log_level);
        allocator.free(self.reasoning_effort);
    }
};

pub fn getLanguage(config_lang: []const u8) Language {
    if (std.mem.eql(u8, config_lang, "auto")) {
        return detectSystemLanguage();
    }
    return Language.fromString(config_lang);
}

fn detectSystemLanguage() Language {
    const env = std.process.getEnvVarOwned(std.heap.page_allocator, "LANG") catch return .zh;
    defer std.heap.page_allocator.free(env);

    if (env.len >= 2) {
        return Language.fromString(env[0..2]);
    }
    return .zh;
}

pub const Language = enum {
    zh,
    en,

    pub fn fromString(s: []const u8) Language {
        if (std.ascii.startsWithIgnoreCase(s, "en")) {
            return .en;
        }
        return .zh;
    }
};

pub const Strings = struct {
    welcome_banner: []const u8,
    welcome_subtitle: []const u8,
    welcome_hint: []const u8,
    prompt_you: []const u8,
    goodbye: []const u8,
    agent_error: []const u8,
    input_hint: []const u8,

    pub fn get(lang: Language) Strings {
        return switch (lang) {
            .zh => Strings{
                .welcome_banner = "GenericAgent  v0.2.0",
                .welcome_subtitle = "通用 AI Agent 交互式命令行工具",
                .welcome_hint = "输入消息后按回车发送，输入 exit 或 quit 退出。",
                .prompt_you = "you> ",
                .goodbye = "再见！",
                .agent_error = "Agent 错误: ",
                .input_hint = "请输入内容",
            },
            .en => Strings{
                .welcome_banner = "GenericAgent  v0.2.0",
                .welcome_subtitle = "Universal AI Agent Interactive CLI",
                .welcome_hint = "Enter your message and press Enter to send. Type 'exit' or 'quit' to leave.",
                .prompt_you = "you> ",
                .goodbye = "Goodbye!",
                .agent_error = "Agent error: ",
                .input_hint = "Please enter some text",
            },
        };
    }
};
