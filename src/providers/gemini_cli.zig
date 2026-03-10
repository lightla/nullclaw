const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const ChatMessage = root.ChatMessage;
const StreamChunk = root.StreamChunk;
const StreamCallback = root.StreamCallback;
const StreamChatResult = root.StreamChatResult;

const log = std.log.scoped(.gemini_cli);

pub const GeminiCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,

    const InternalResult = struct {
        content: []const u8,
        usage: root.TokenUsage,
    };

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) !GeminiCliProvider {
        return .{ .allocator = allocator, .model = model orelse "gemini-3-flash-preview" };
    }

    pub fn provider(self: *GeminiCliProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl, .chat = chatImpl, .supportsNativeTools = supportsNativeToolsImpl, .getName = getNameImpl, .deinit = deinitImpl, .supports_streaming = supportsStreamingImpl, .supports_vision = supportsVisionImpl, .stream_chat = streamChatImpl,
    };

    fn chatImpl(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, model: []const u8, _: f64) anyerror!ChatResponse {
        const self: *GeminiCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        var m_pure = effective_model;
        var agent_name: []const u8 = "assistant";
        if (std.mem.indexOf(u8, effective_model, "--")) |idx| { m_pure = effective_model[0..idx]; agent_name = effective_model[idx + 2 ..]; }
        const prompt = try constructFullAwarePrompt(allocator, request, agent_name);
        defer allocator.free(prompt);
        const res = try runGeminiGreedy(allocator, prompt, m_pure, agent_name, null, null);
                log.info("Gemini đã trả lời cho {s}: {s}", .{agent_name, res.content});
return ChatResponse{ .content = res.content, .model = try allocator.dupe(u8, effective_model), .usage = res.usage };
    }

    fn streamChatImpl(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, model: []const u8, _: f64, callback: StreamCallback, callback_ctx: *anyopaque) anyerror!StreamChatResult {
        const self: *GeminiCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        var m_pure = effective_model;
        var agent_name: []const u8 = "assistant";
        if (std.mem.indexOf(u8, effective_model, "--")) |idx| { m_pure = effective_model[0..idx]; agent_name = effective_model[idx + 2 ..]; }
        const prompt = try constructFullAwarePrompt(allocator, request, agent_name);
        defer allocator.free(prompt);
        const res = try runGeminiGreedy(allocator, prompt, m_pure, agent_name, callback, callback_ctx);
        callback(callback_ctx, .{ .delta = "", .is_final = true, .token_count = 0 });
        return StreamChatResult{ .content = res.content, .usage = res.usage };
    }

    fn runGeminiGreedy(
        allocator: std.mem.Allocator,
        prompt: []const u8,
        model_name: []const u8,
        agent_name: []const u8,
        stream_cb: ?StreamCallback,
        cb_ctx: ?*anyopaque,
    ) !InternalResult {
        log.info("Gọi Gemini cho {s}", .{agent_name});
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (argv.items) |arg| allocator.free(arg);
            argv.deinit(allocator);
        }
        try argv.append(allocator, try allocator.dupe(u8, "gemini"));
        try argv.append(allocator, try allocator.dupe(u8, "-m"));
        try argv.append(allocator, try allocator.dupe(u8, model_name));
        try argv.append(allocator, try allocator.dupe(u8, "-p"));
        try argv.append(allocator, try allocator.dupe(u8, prompt));
        try argv.append(allocator, try allocator.dupe(u8, "--output-format"));
        try argv.append(allocator, try allocator.dupe(u8, "stream-json"));
        try argv.append(allocator, try allocator.dupe(u8, "--yolo"));

        var child = std.process.Child.init(argv.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        var full_content = std.ArrayListUnmanaged(u8).empty;
        errdefer full_content.deinit(allocator);
        var usage = root.TokenUsage{};
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(allocator);

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = try child.stdout.?.read(&read_buf);
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n') {
                    const line = std.mem.trim(u8, line_buf.items, " \t\r\n");
                    if (line.len > 0 and std.mem.startsWith(u8, line, "{")) {
                        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch { line_buf.clearRetainingCapacity(); continue; };
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            const obj = parsed.value.object;
                            if (obj.get("type")) |t| {
                                if (std.mem.eql(u8, t.string, "message")) {
                                    if (obj.get("role")) |rv| {
                                        if (std.mem.eql(u8, rv.string, "assistant")) {
                                            if (obj.get("content")) |c| {
                                                try full_content.appendSlice(allocator, c.string);
                                                if (stream_cb) |cb| cb(cb_ctx.?, .{ .delta = c.string, .is_final = false, .token_count = 0 });
                                            }
                                        }
                                    }
                                } else if (std.mem.eql(u8, t.string, "result")) {
                                    if (obj.get("stats")) |stats| {
                                        if (stats.object.get("total_tokens")) |tt| { usage.total_tokens = @intCast(tt.integer); }
                                    }
                                }
                            }
                        }
                    }
                    line_buf.clearRetainingCapacity();
                } else try line_buf.append(allocator, byte);
            }
        }
        _ = child.wait() catch {};
        return InternalResult{ .content = try full_content.toOwnedSlice(allocator), .usage = usage };
    }

    fn chatWithSystemImpl(_: *anyopaque, allocator: std.mem.Allocator, _: ?[]const u8, message: []const u8, model: []const u8, _: f64) anyerror![]const u8 {
        const res = try runGeminiGreedy(allocator, message, model, "system", null, null);
        return res.content;
    }
    fn supportsNativeToolsImpl(_: *anyopaque) bool { return false; }
    fn supportsVisionImpl(_: *anyopaque) bool { return false; }
    fn supportsStreamingImpl(_: *anyopaque) bool { return true; }
    fn getNameImpl(_: *anyopaque) []const u8 { return "gemini-cli"; }
    fn deinitImpl(_: *anyopaque) void {}
};

fn constructFullAwarePrompt(allocator: std.mem.Allocator, request: ChatRequest, agent_name: []const u8) ![]const u8 {
    var full_prompt = std.ArrayListUnmanaged(u8).empty;
    errdefer full_prompt.deinit(allocator);
    try std.fmt.format(full_prompt.writer(allocator), "Mày là {s} trên Slack. Trả lời yêu cầu sau:\\n\\n", .{agent_name});
    for (request.messages) |msg| {
        const tag = if (msg.role == .user) "User: " else "Assistant: ";
        try full_prompt.appendSlice(allocator, tag);
        try full_prompt.appendSlice(allocator, msg.content);
        try full_prompt.appendSlice(allocator, "\\n\\n");
    }
    return full_prompt.toOwnedSlice(allocator);
}
