const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const ChatMessage = root.ChatMessage;
const StreamChunk = root.StreamChunk;
const StreamCallback = root.StreamCallback;
const StreamChatResult = root.StreamChatResult;

const log = std.log.scoped(.claude_cli);

/// File in the session directory that stores the claude session ID.
/// Presence + non-empty content → use --resume <id> for subsequent calls.
const SESSION_ID_FILE = ".claude_session_id";

/// Provider that delegates to the `claude` CLI (Claude Code).
///
/// Runs `claude --output-format stream-json --model <model> -p` with prompt on stdin.
/// On first call: creates a new session, stores session ID in SESSION_ID_FILE.
/// On resume: runs `claude --resume <session_id> ...` for session continuity.
pub const ClaudeCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,

    const DEFAULT_MODEL = "claude-opus-4-6";
    const CLI_NAME = "claude";

    const InternalResult = struct {
        content: []const u8,
        usage: root.TokenUsage,
        /// true if stderr contained a capacity/rate-limit error
        capacity_error: bool = false,
        /// Session ID returned by claude CLI (owned, may be null)
        session_id: ?[]const u8 = null,

        fn deinit(self: InternalResult, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
            if (self.session_id) |id| allocator.free(id);
        }
    };

    /// Reads all bytes from a file into a buffer. Runs in a background thread.
    const StderrReader = struct {
        file: std.fs.File,
        allocator: std.mem.Allocator,
        buf: []const u8 = "",

        fn run(self: *StderrReader) void {
            var out = std.ArrayListUnmanaged(u8).empty;
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = self.file.read(&tmp) catch break;
                if (n == 0) break;
                out.appendSlice(self.allocator, tmp[0..n]) catch break;
            }
            self.buf = out.toOwnedSlice(self.allocator) catch "";
        }
    };

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) !ClaudeCliProvider {
        return .{ .allocator = allocator, .model = model orelse DEFAULT_MODEL };
    }

    pub fn provider(self: *ClaudeCliProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .supports_vision = supportsVisionImpl,
        .supports_streaming = supportsStreamingImpl,
        .stream_chat = streamChatImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatImpl(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, model: []const u8, _: f64) anyerror!ChatResponse {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        const actor = if (request.actor_name.len > 0) request.actor_name else "unknown";

        const session_id = loadSessionId(allocator, request.gemini_session_cwd);
        defer if (session_id) |id| allocator.free(id);
        const is_resume = session_id != null;

        const prompt = if (is_resume)
            try extractLastUserMessage(allocator, request)
        else
            try constructFullAwarePrompt(allocator, request, actor);
        defer allocator.free(prompt);

        log.info("{s}[{s}] calling claude resume={}", .{ actor, effective_model, is_resume });

        const res = try runClaudeFinal(allocator, prompt, effective_model, actor, request.gemini_session_cwd, session_id, null, null);
        defer res.deinit(allocator);

        if (!is_resume and !res.capacity_error) {
            if (res.session_id) |id| storeSessionId(request.gemini_session_cwd, id);
        }

        if (res.capacity_error) {
            if (request.fallback_model) |fb_model| {
                log.warn("{s}[{s}] capacity error, retrying with fallback {s}", .{ actor, effective_model, fb_model });
                const fb_res = try runClaudeFinal(allocator, prompt, fb_model, actor, request.gemini_session_cwd, session_id, null, null);
                defer fb_res.deinit(allocator);
                if (!is_resume and !fb_res.capacity_error) {
                    if (fb_res.session_id) |id| storeSessionId(request.gemini_session_cwd, id);
                }
                return ChatResponse{
                    .content = try allocator.dupe(u8, fb_res.content),
                    .model = try allocator.dupe(u8, fb_model),
                    .usage = fb_res.usage,
                };
            }
        }

        return ChatResponse{
            .content = try allocator.dupe(u8, res.content),
            .model = try allocator.dupe(u8, effective_model),
            .usage = res.usage,
        };
    }

    fn streamChatImpl(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, model: []const u8, _: f64, callback: StreamCallback, callback_ctx: *anyopaque) anyerror!StreamChatResult {
        const self: *ClaudeCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        const actor = if (request.actor_name.len > 0) request.actor_name else "unknown";

        const session_id = loadSessionId(allocator, request.gemini_session_cwd);
        defer if (session_id) |id| allocator.free(id);
        const is_resume = session_id != null;

        const prompt = if (is_resume)
            try extractLastUserMessage(allocator, request)
        else
            try constructFullAwarePrompt(allocator, request, actor);
        defer allocator.free(prompt);

        log.info("{s}[{s}] calling claude resume={}", .{ actor, effective_model, is_resume });

        const res = try runClaudeFinal(allocator, prompt, effective_model, actor, request.gemini_session_cwd, session_id, callback, callback_ctx);
        defer res.deinit(allocator);

        if (!is_resume and !res.capacity_error) {
            if (res.session_id) |id| storeSessionId(request.gemini_session_cwd, id);
        }

        if (res.capacity_error) {
            if (request.fallback_model) |fb_model| {
                log.warn("{s}[{s}] capacity error, retrying with fallback {s}", .{ actor, effective_model, fb_model });
                const notice = try std.fmt.allocPrint(allocator, "\n_(Model {s} quá tải, đang thử lại với {s}...)_\n\n", .{ effective_model, fb_model });
                defer allocator.free(notice);
                callback(callback_ctx, .{ .delta = notice, .is_final = false, .token_count = 0 });
                const fb_res = try runClaudeFinal(allocator, prompt, fb_model, actor, request.gemini_session_cwd, session_id, callback, callback_ctx);
                defer fb_res.deinit(allocator);
                if (!is_resume and !fb_res.capacity_error) {
                    if (fb_res.session_id) |id| storeSessionId(request.gemini_session_cwd, id);
                }
                callback(callback_ctx, .{ .delta = "", .is_final = true, .token_count = 0 });
                return StreamChatResult{ .content = try allocator.dupe(u8, fb_res.content), .usage = fb_res.usage };
            }
        }

        callback(callback_ctx, .{ .delta = "", .is_final = true, .token_count = 0 });
        return StreamChatResult{ .content = try allocator.dupe(u8, res.content), .usage = res.usage };
    }

    fn runClaudeFinal(
        allocator: std.mem.Allocator,
        prompt: []const u8,
        model_name: []const u8,
        actor_name: []const u8,
        session_cwd: ?[]const u8,
        session_id: ?[]const u8,
        stream_cb: ?StreamCallback,
        cb_ctx: ?*anyopaque,
    ) !InternalResult {
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (argv.items) |arg| allocator.free(arg);
            argv.deinit(allocator);
        }

        try argv.append(allocator, try allocator.dupe(u8, CLI_NAME));
        try argv.append(allocator, try allocator.dupe(u8, "--output-format"));
        try argv.append(allocator, try allocator.dupe(u8, "stream-json"));
        try argv.append(allocator, try allocator.dupe(u8, "--verbose"));
        try argv.append(allocator, try allocator.dupe(u8, "--model"));
        try argv.append(allocator, try allocator.dupe(u8, model_name));
        if (session_id) |id| {
            try argv.append(allocator, try allocator.dupe(u8, "--resume"));
            try argv.append(allocator, try allocator.dupe(u8, id));
        }
        try argv.append(allocator, try allocator.dupe(u8, "-p")); // reads from stdin when no arg follows

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        if (session_cwd) |cwd| child.cwd = cwd;

        child.spawn() catch |err| {
            log.err("{s}[claude] spawn failed (is 'claude' installed?): {}", .{ actor_name, err });
            return err;
        };
        log.info("{s}[{s}] spawned, writing prompt ({d} bytes)", .{ actor_name, model_name, prompt.len });

        // Drain stderr concurrently to prevent pipe deadlock
        var stderr_reader = StderrReader{ .file = child.stderr.?, .allocator = allocator };
        const stderr_thread = try std.Thread.spawn(.{}, StderrReader.run, .{&stderr_reader});

        try child.stdin.?.writeAll(prompt);
        child.stdin.?.close();
        child.stdin = null;

        var full_content = std.ArrayListUnmanaged(u8).empty;
        errdefer full_content.deinit(allocator);
        var usage = root.TokenUsage{};
        var parsed_session_id: ?[]const u8 = null;
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(allocator);
        var lines_received: u32 = 0;

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = child.stdout.?.read(&read_buf) catch |err| {
                log.err("{s}[claude] stdout read error: {}", .{ actor_name, err });
                break;
            };
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n') {
                    lines_received += 1;
                    const line = std.mem.trim(u8, line_buf.items, " \t\r\n");
                    if (line.len > 0 and std.mem.startsWith(u8, line, "{")) {
                        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
                            line_buf.clearRetainingCapacity();
                            continue;
                        };
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            const obj = parsed.value.object;
                            if (obj.get("type")) |t| {
                                if (t == .string) {
                                    // Streaming assistant content
                                    if (std.mem.eql(u8, t.string, "assistant")) {
                                        if (obj.get("message")) |msg| {
                                            if (msg == .object) {
                                                if (msg.object.get("content")) |content_arr| {
                                                    if (content_arr == .array) {
                                                        for (content_arr.array.items) |item| {
                                                            if (item != .object) continue;
                                                            const item_type = item.object.get("type") orelse continue;
                                                            if (item_type != .string) continue;
                                                            if (!std.mem.eql(u8, item_type.string, "text")) continue;
                                                            const text = item.object.get("text") orelse continue;
                                                            if (text != .string) continue;
                                                            try full_content.appendSlice(allocator, text.string);
                                                            if (stream_cb) |cb| cb(cb_ctx.?, .{ .delta = text.string, .is_final = false, .token_count = 0 });
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    // Final result event
                                    } else if (std.mem.eql(u8, t.string, "result")) {
                                        // Capture session_id for future resume
                                        if (parsed_session_id == null) {
                                            if (obj.get("session_id")) |sid| {
                                                if (sid == .string) {
                                                    parsed_session_id = allocator.dupe(u8, sid.string) catch null;
                                                }
                                            }
                                        }
                                        // Usage stats
                                        if (obj.get("stats")) |stats| {
                                            if (stats == .object) {
                                                if (stats.object.get("output_tokens")) |ot| {
                                                    if (ot == .integer) usage.total_tokens += @intCast(ot.integer);
                                                }
                                                if (stats.object.get("input_tokens")) |it| {
                                                    if (it == .integer) usage.total_tokens += @intCast(it.integer);
                                                }
                                            }
                                        }
                                        // Fallback: result field if content still empty
                                        if (full_content.items.len == 0) {
                                            if (obj.get("result")) |rv| {
                                                if (rv == .string and rv.string.len > 0) {
                                                    try full_content.appendSlice(allocator, rv.string);
                                                    if (stream_cb) |cb| cb(cb_ctx.?, .{ .delta = rv.string, .is_final = false, .token_count = 0 });
                                                }
                                            }
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

        stderr_thread.join();
        defer allocator.free(stderr_reader.buf);

        // Detect capacity/rate-limit errors from stderr
        const is_capacity_error = stderr_reader.buf.len > 0 and (
            std.mem.indexOf(u8, stderr_reader.buf, "rate_limit_error") != null or
            std.mem.indexOf(u8, stderr_reader.buf, "overloaded_error") != null or
            std.mem.indexOf(u8, stderr_reader.buf, "529") != null or
            std.mem.indexOf(u8, stderr_reader.buf, "Rate limit") != null
        );

        const term = child.wait() catch |err| {
            log.err("{s}[{s}] wait() failed: {}", .{ actor_name, model_name, err });
            return InternalResult{ .content = try full_content.toOwnedSlice(allocator), .usage = usage, .session_id = parsed_session_id };
        };

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    if (is_capacity_error) {
                        log.warn("{s}[{s}] capacity error (exit={d}), will retry with fallback", .{ actor_name, model_name, code });
                    } else {
                        if (stderr_reader.buf.len > 0) {
                            log.err("{s}[{s}] stderr: {s}", .{ actor_name, model_name, stderr_reader.buf });
                        }
                        log.err("{s}[{s}] exit={d} lines={d} bytes={d}", .{ actor_name, model_name, code, lines_received, full_content.items.len });
                    }
                } else {
                    log.info("{s}[{s}] done exit=0 lines={d} bytes={d} tokens={d}", .{ actor_name, model_name, lines_received, full_content.items.len, usage.total_tokens });
                }
            },
            else => log.warn("{s}[{s}] terminated abnormally: {}", .{ actor_name, model_name, term }),
        }

        if (full_content.items.len == 0 and !is_capacity_error) {
            log.warn("{s}[{s}] empty content (lines_received={d})", .{ actor_name, model_name, lines_received });
        }

        return InternalResult{
            .content = try full_content.toOwnedSlice(allocator),
            .usage = usage,
            .capacity_error = is_capacity_error,
            .session_id = parsed_session_id,
        };
    }

    fn chatWithSystemImpl(_: *anyopaque, allocator: std.mem.Allocator, system_prompt: ?[]const u8, message: []const u8, model: []const u8, _: f64) anyerror![]const u8 {
        const prompt = if (system_prompt) |s| try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ s, message }) else message;
        defer if (system_prompt != null) allocator.free(prompt);
        const res = try runClaudeFinal(allocator, prompt, model, "system", null, null, null, null);
        defer if (res.session_id) |id| allocator.free(id);
        return res.content;
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool { return false; }
    fn supportsVisionImpl(_: *anyopaque) bool { return false; }
    fn supportsStreamingImpl(_: *anyopaque) bool { return true; }
    fn getNameImpl(_: *anyopaque) []const u8 { return "claude-cli"; }
    fn deinitImpl(_: *anyopaque) void {}
};

// ════════════════════════════════════════════════════════════════════════════
// Session ID persistence
// ════════════════════════════════════════════════════════════════════════════

/// Loads the stored claude session ID from the session directory.
/// Returns owned slice or null. Caller must free if non-null.
fn loadSessionId(allocator: std.mem.Allocator, session_cwd: ?[]const u8) ?[]const u8 {
    const cwd = session_cwd orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, SESSION_ID_FILE }) catch return null;
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const id = f.readToEndAlloc(allocator, 256) catch return null;
    const trimmed = std.mem.trim(u8, id, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(id);
        return null;
    }
    if (trimmed.len < id.len) {
        const owned = allocator.dupe(u8, trimmed) catch { allocator.free(id); return null; };
        allocator.free(id);
        return owned;
    }
    return id;
}

/// Stores the claude session ID into the session directory.
fn storeSessionId(session_cwd: ?[]const u8, session_id: []const u8) void {
    const cwd = session_cwd orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, SESSION_ID_FILE }) catch return;
    const f = std.fs.createFileAbsolute(path, .{}) catch return;
    defer f.close();
    f.writeAll(session_id) catch {};
    log.info("[claude] session stored: {s}", .{session_id});
}

// ════════════════════════════════════════════════════════════════════════════
// Prompt builders
// ════════════════════════════════════════════════════════════════════════════

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

    var has_history = false;
    for (request.messages) |msg| {
        if (msg.role == .system) continue;
        if (!has_history) {
            try full_prompt.appendSlice(allocator, "[LỊCH SỬ HỘI THOẠI]\n");
            has_history = true;
        }
        const role = if (msg.role == .user) "Người dùng" else "Bạn";
        try std.fmt.format(full_prompt.writer(allocator), "- {s}: {s}\n", .{ role, msg.content });
    }

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

// ════════════════════════════════════════════════════════════════════════════
// Helpers
// ════════════════════════════════════════════════════════════════════════════

pub fn checkCliAvailable(allocator: std.mem.Allocator, cli_name: []const u8) !void {
    const argv = [_][]const u8{ "which", cli_name };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = child.stdout.?.readToEndAlloc(allocator, 4096) catch {
        _ = child.wait() catch {};
        return error.CliNotFound;
    };
    allocator.free(out);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| { if (code != 0) return error.CliNotFound; },
        else => return error.CliNotFound,
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "ClaudeCliProvider.getNameImpl returns claude-cli" {
    const vt = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude-cli", vt.getName(@ptrCast(&dummy)));
}

test "ClaudeCliProvider default model is claude-opus-4-6" {
    try std.testing.expectEqualStrings("claude-opus-4-6", ClaudeCliProvider.DEFAULT_MODEL);
}

test "ClaudeCliProvider supports streaming" {
    const vt = ClaudeCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expect(vt.supports_streaming != null);
    try std.testing.expect(vt.supports_streaming.?(@ptrCast(&dummy)));
}

test "loadSessionId returns null for missing file" {
    try std.testing.expect(loadSessionId(std.testing.allocator, null) == null);
}

test "storeSessionId and loadSessionId roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    storeSessionId(dir_path, "test-session-123");

    const loaded = loadSessionId(std.testing.allocator, dir_path);
    defer if (loaded) |id| std.testing.allocator.free(id);

    try std.testing.expect(loaded != null);
    try std.testing.expectEqualStrings("test-session-123", loaded.?);
}
