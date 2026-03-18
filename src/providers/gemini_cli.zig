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

/// Sentinel file written after the first successful call to a session directory.
/// Presence signals that gemini has an existing session → use --resume latest.
const SENTINEL = ".initialized";

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
        const actor = if (request.actor_name.len > 0) request.actor_name else "unknown";

        const is_resume = isResumeCall(request.gemini_session_cwd);
        const prompt = if (is_resume)
            try extractLastUserMessage(allocator, request)
        else
            try constructFullAwarePrompt(allocator, request, actor);
        defer allocator.free(prompt);

        log.info("{s}[{s}] calling gemini resume={}", .{ actor, effective_model, is_resume });

        const res = try runGeminiFinal(allocator, prompt, effective_model, actor, request.gemini_session_cwd, is_resume, null, null);
        if (!is_resume) markInitialized(request.gemini_session_cwd);
        return ChatResponse{ .content = res.content, .model = try allocator.dupe(u8, effective_model), .usage = res.usage };
    }

    fn streamChatImpl(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, model: []const u8, _: f64, callback: StreamCallback, callback_ctx: *anyopaque) anyerror!StreamChatResult {
        const self: *GeminiCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        const actor = if (request.actor_name.len > 0) request.actor_name else "unknown";

        const is_resume = isResumeCall(request.gemini_session_cwd);
        const prompt = if (is_resume)
            try extractLastUserMessage(allocator, request)
        else
            try constructFullAwarePrompt(allocator, request, actor);
        defer allocator.free(prompt);

        log.info("{s}[{s}] calling gemini resume={}", .{ actor, effective_model, is_resume });

        const res = try runGeminiFinal(allocator, prompt, effective_model, actor, request.gemini_session_cwd, is_resume, callback, callback_ctx);
        if (!is_resume) markInitialized(request.gemini_session_cwd);
        callback(callback_ctx, .{ .delta = "", .is_final = true, .token_count = 0 });
        return StreamChatResult{ .content = res.content, .usage = res.usage };
    }

    fn runGeminiFinal(
        allocator: std.mem.Allocator,
        prompt: []const u8,
        model_name: []const u8,
        actor_name: []const u8,
        session_cwd: ?[]const u8,
        resume_session: bool,
        stream_cb: ?StreamCallback,
        cb_ctx: ?*anyopaque,
    ) !InternalResult {
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (argv.items) |arg| allocator.free(arg);
            argv.deinit(allocator);
        }
        try argv.append(allocator, try allocator.dupe(u8, "gemini"));
        try argv.append(allocator, try allocator.dupe(u8, "-m"));
        try argv.append(allocator, try allocator.dupe(u8, model_name));
        if (resume_session) {
            try argv.append(allocator, try allocator.dupe(u8, "--resume"));
            try argv.append(allocator, try allocator.dupe(u8, "latest"));
        }
        try argv.append(allocator, try allocator.dupe(u8, "--output-format"));
        try argv.append(allocator, try allocator.dupe(u8, "stream-json"));
        try argv.append(allocator, try allocator.dupe(u8, "--yolo"));

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit; // write directly to terminal, avoids pipe deadlock
        if (session_cwd) |cwd| child.cwd = cwd;
        child.spawn() catch |err| {
            log.err("{s}[gemini] spawn failed (is 'gemini' installed?): {}", .{ actor_name, err });
            return err;
        };
        log.info("{s}[gemini] spawned, writing prompt ({d} bytes)", .{ actor_name, prompt.len });

        try child.stdin.?.writeAll(prompt);
        child.stdin.?.close();
        child.stdin = null;

        var full_content = std.ArrayListUnmanaged(u8).empty;
        errdefer full_content.deinit(allocator);
        var usage = root.TokenUsage{};
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(allocator);
        var lines_received: u32 = 0;

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = child.stdout.?.read(&read_buf) catch |err| {
                log.err("{s}[gemini] stdout read error: {}", .{ actor_name, err });
                break;
            };
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n') {
                    lines_received += 1;
                    const line = std.mem.trim(u8, line_buf.items, " \t\r\n");
                    if (line.len > 0 and std.mem.startsWith(u8, line, "{")) {
                        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
                            log.warn("{s}[gemini] failed to parse json line: {s}", .{ actor_name, if (line.len > 80) line[0..80] else line });
                            line_buf.clearRetainingCapacity();
                            continue;
                        };
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            const obj = parsed.value.object;
                            if (obj.get("type")) |t| {
                                if (std.mem.eql(u8, t.string, "message")) {
                                    if (obj.get("role")) |rv| {
                                        if (std.mem.eql(u8, rv.string, "assistant")) {
                                            if (obj.get("content")) |c| {
                                                if (c == .string) {
                                                    if (std.mem.indexOf(u8, c.string, "Reflect on") == null) {
                                                        try full_content.appendSlice(allocator, c.string);
                                                        if (stream_cb) |cb| cb(cb_ctx.?, .{ .delta = c.string, .is_final = false, .token_count = 0 });
                                                    }
                                                }
                                            }
                                        }
                                    }
                                } else if (std.mem.eql(u8, t.string, "result")) {
                                    if (obj.get("stats")) |stats| {
                                        if (stats.object.get("total_tokens")) |tt| {
                                            usage.total_tokens = @intCast(tt.integer);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    line_buf.clearRetainingCapacity();
                } else {
                    try line_buf.append(allocator, byte);
                }
            }
        }
        const term = child.wait() catch |err| {
            log.err("{s}[{s}] wait() failed: {}", .{ actor_name, model_name, err });
            return InternalResult{ .content = try full_content.toOwnedSlice(allocator), .usage = usage };
        };

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    log.err("{s}[{s}] exit={d} lines={d} bytes={d}", .{ actor_name, model_name, code, lines_received, full_content.items.len });
                } else {
                    log.info("{s}[{s}] done exit=0 lines={d} bytes={d} tokens={d}", .{ actor_name, model_name, lines_received, full_content.items.len, usage.total_tokens });
                }
            },
            else => log.warn("{s}[{s}] terminated abnormally: {}", .{ actor_name, model_name, term }),
        }

        if (full_content.items.len == 0) {
            log.warn("{s}[{s}] empty content (lines_received={d})", .{ actor_name, model_name, lines_received });
        }

        return InternalResult{ .content = try full_content.toOwnedSlice(allocator), .usage = usage };
    }

    fn chatWithSystemImpl(_: *anyopaque, allocator: std.mem.Allocator, system_prompt: ?[]const u8, message: []const u8, model: []const u8, _: f64) anyerror![]const u8 {
        const prompt = if (system_prompt) |s| try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{s, message}) else message;
        defer if (system_prompt != null) allocator.free(prompt);
        const res = try runGeminiFinal(allocator, prompt, model, "system", null, false, null, null);
        return res.content;
    }
    fn supportsNativeToolsImpl(_: *anyopaque) bool { return false; }
    fn supportsVisionImpl(_: *anyopaque) bool { return false; }
    fn supportsStreamingImpl(_: *anyopaque) bool { return true; }
    fn getNameImpl(_: *anyopaque) []const u8 { return "gemini-cli"; }
    fn deinitImpl(_: *anyopaque) void {}
};

/// Returns true if the session has been initialized before (sentinel file exists).
fn isResumeCall(session_cwd: ?[]const u8) bool {
    const cwd = session_cwd orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const sentinel = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, SENTINEL }) catch return false;
    std.fs.accessAbsolute(sentinel, .{}) catch return false;
    return true;
}

/// Creates the sentinel file after the first successful gemini call.
fn markInitialized(session_cwd: ?[]const u8) void {
    const cwd = session_cwd orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const sentinel = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, SENTINEL }) catch return;
    const f = std.fs.createFileAbsolute(sentinel, .{}) catch return;
    f.close();
}

/// Extracts only the last user message for resume calls.
/// gemini already has full context in its session — only new message needed.
fn extractLastUserMessage(allocator: std.mem.Allocator, request: ChatRequest) ![]const u8 {
    var i = request.messages.len;
    while (i > 0) {
        i -= 1;
        if (request.messages[i].role == .user) {
            return allocator.dupe(u8, request.messages[i].content);
        }
    }
    return allocator.dupe(u8, "");
}

fn constructFullAwarePrompt(allocator: std.mem.Allocator, request: ChatRequest, agent_name: []const u8) ![]const u8 {
    var full_prompt = std.ArrayListUnmanaged(u8).empty;
    errdefer full_prompt.deinit(allocator);

    try std.fmt.format(full_prompt.writer(allocator), "CHỈ THỊ HỆ THỐNG: Mày là {s} trên Slack. Hãy trả lời câu hỏi cuối cùng của người dùng. Tuyệt đối không lặp lại lịch sử, không in rác hệ thống.\n\n", .{agent_name});

    // Build conversation history, skipping system messages
    var has_history = false;
    for (request.messages) |msg| {
        if (msg.role == .system) continue; // Skip system prompt — don't include in conversation
        if (!has_history) {
            try full_prompt.appendSlice(allocator, "[LỊCH SỬ HỘI THOẠI]\n");
            has_history = true;
        }
        const role = if (msg.role == .user) "Người dùng" else "Bạn";
        try std.fmt.format(full_prompt.writer(allocator), "- {s}: {s}\n", .{role, msg.content});
    }

    // Find the last user message for [CÂU HỎI CUỐI CÙNG]
    var last_user_msg: ?[]const u8 = null;
    var i = request.messages.len;
    while (i > 0) {
        i -= 1;
        if (request.messages[i].role == .user) {
            last_user_msg = request.messages[i].content;
            break;
        }
    }

    if (last_user_msg) |user_msg| {
        try full_prompt.appendSlice(allocator, "\n[CÂU HỎI CUỐI CÙNG]: ");
        try full_prompt.appendSlice(allocator, user_msg);
    }

    try full_prompt.appendSlice(allocator, "\n\nTRẢ LỜI NGAY: ");
    return full_prompt.toOwnedSlice(allocator);
}
