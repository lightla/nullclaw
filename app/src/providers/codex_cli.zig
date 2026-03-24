const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const ChatMessage = root.ChatMessage;
const StreamCallback = root.StreamCallback;
const StreamChatResult = root.StreamChatResult;

const log = std.log.scoped(.codex_cli);

/// File in the session directory that stores the Codex thread ID.
/// Presence + non-empty content means subsequent turns can resume the same Codex CLI session.
const THREAD_ID_FILE = ".codex_thread_id";

pub const CodexCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,

    const DEFAULT_MODEL = "codex-mini-latest";
    const CLI_NAME = "codex";

    const InternalResult = struct {
        content: []const u8,
        usage: root.TokenUsage,
        capacity_error: bool = false,
        thread_id: ?[]const u8 = null,

        fn deinit(self: InternalResult, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
            if (self.thread_id) |id| allocator.free(id);
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

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) !CodexCliProvider {
        try checkCliAvailable(allocator, CLI_NAME);
        return .{
            .allocator = allocator,
            .model = model orelse DEFAULT_MODEL,
        };
    }

    pub fn provider(self: *CodexCliProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
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

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *CodexCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        const actor = if (request.actor_name.len > 0) request.actor_name else "unknown";

        const thread_id = loadThreadId(allocator, request.gemini_session_cwd);
        defer if (thread_id) |id| allocator.free(id);
        const is_resume = thread_id != null;

        const prompt = if (is_resume)
            try extractLastUserMessage(allocator, request)
        else
            try constructFullAwarePrompt(allocator, request, actor);
        defer allocator.free(prompt);

        log.info("{s}[{s}] calling codex resume={}", .{ actor, effective_model, is_resume });

        const res = try runCodexFinal(
            allocator,
            prompt,
            effective_model,
            actor,
            request.gemini_session_cwd,
            request.workspace_dir,
            thread_id,
            null,
            null,
        );
        defer res.deinit(allocator);

        if (!res.capacity_error) {
            if (res.thread_id) |id| storeThreadId(request.gemini_session_cwd, id);
        }

        if (res.capacity_error) {
            if (request.fallback_model) |fb_model| {
                log.warn("{s}[{s}] capacity error, retrying with fallback {s}", .{ actor, effective_model, fb_model });
                const fb_res = try runCodexFinal(
                    allocator,
                    prompt,
                    fb_model,
                    actor,
                    request.gemini_session_cwd,
                    request.workspace_dir,
                    thread_id,
                    null,
                    null,
                );
                defer fb_res.deinit(allocator);
                if (!fb_res.capacity_error) {
                    if (fb_res.thread_id) |id| storeThreadId(request.gemini_session_cwd, id);
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

    fn streamChatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
        callback: StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!StreamChatResult {
        const self: *CodexCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        const actor = if (request.actor_name.len > 0) request.actor_name else "unknown";

        const thread_id = loadThreadId(allocator, request.gemini_session_cwd);
        defer if (thread_id) |id| allocator.free(id);
        const is_resume = thread_id != null;

        const prompt = if (is_resume)
            try extractLastUserMessage(allocator, request)
        else
            try constructFullAwarePrompt(allocator, request, actor);
        defer allocator.free(prompt);

        log.info("{s}[{s}] calling codex resume={}", .{ actor, effective_model, is_resume });

        const res = try runCodexFinal(
            allocator,
            prompt,
            effective_model,
            actor,
            request.gemini_session_cwd,
            request.workspace_dir,
            thread_id,
            callback,
            callback_ctx,
        );
        defer res.deinit(allocator);

        if (!res.capacity_error) {
            if (res.thread_id) |id| storeThreadId(request.gemini_session_cwd, id);
        }

        if (res.capacity_error) {
            if (request.fallback_model) |fb_model| {
                log.warn("{s}[{s}] capacity error, retrying with fallback {s}", .{ actor, effective_model, fb_model });
                const notice = try std.fmt.allocPrint(
                    allocator,
                    "\n_(Model {s} quá tải, đang thử lại với {s}...)_\n\n",
                    .{ effective_model, fb_model },
                );
                defer allocator.free(notice);
                callback(callback_ctx, .{ .delta = notice, .is_final = false, .token_count = 0 });

                const fb_res = try runCodexFinal(
                    allocator,
                    prompt,
                    fb_model,
                    actor,
                    request.gemini_session_cwd,
                    request.workspace_dir,
                    thread_id,
                    callback,
                    callback_ctx,
                );
                defer fb_res.deinit(allocator);
                if (!fb_res.capacity_error) {
                    if (fb_res.thread_id) |id| storeThreadId(request.gemini_session_cwd, id);
                }
                callback(callback_ctx, .{ .delta = "", .is_final = true, .token_count = 0 });
                return StreamChatResult{
                    .content = try allocator.dupe(u8, fb_res.content),
                    .usage = fb_res.usage,
                };
            }
        }

        callback(callback_ctx, .{ .delta = "", .is_final = true, .token_count = 0 });
        return StreamChatResult{
            .content = try allocator.dupe(u8, res.content),
            .usage = res.usage,
        };
    }

    fn runCodexFinal(
        allocator: std.mem.Allocator,
        prompt: []const u8,
        model_name: []const u8,
        actor_name: []const u8,
        session_cwd: ?[]const u8,
        workspace_dir: ?[]const u8,
        thread_id: ?[]const u8,
        stream_cb: ?StreamCallback,
        cb_ctx: ?*anyopaque,
    ) !InternalResult {
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (argv.items) |arg| allocator.free(arg);
            argv.deinit(allocator);
        }

        try argv.append(allocator, try allocator.dupe(u8, CLI_NAME));
        try argv.append(allocator, try allocator.dupe(u8, "-a"));
        try argv.append(allocator, try allocator.dupe(u8, "never"));
        try argv.append(allocator, try allocator.dupe(u8, "-s"));
        try argv.append(allocator, try allocator.dupe(u8, "workspace-write"));
        try argv.append(allocator, try allocator.dupe(u8, "exec"));
        if (thread_id != null) {
            try argv.append(allocator, try allocator.dupe(u8, "resume"));
        }
        try argv.append(allocator, try allocator.dupe(u8, "--json"));
        try argv.append(allocator, try allocator.dupe(u8, "--skip-git-repo-check"));
        if (model_name.len > 0) {
            try argv.append(allocator, try allocator.dupe(u8, "--model"));
            try argv.append(allocator, try allocator.dupe(u8, model_name));
        }
        if (thread_id) |id| {
            try argv.append(allocator, try allocator.dupe(u8, id));
        }
        try argv.append(allocator, try allocator.dupe(u8, "-"));

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        const effective_cwd = workspace_dir orelse session_cwd;
        if (effective_cwd) |cwd| child.cwd = cwd;

        child.spawn() catch |err| {
            log.err("{s}[codex] spawn failed (is 'codex' installed?): {}", .{ actor_name, err });
            return err;
        };
        log.info("{s}[{s}] spawned, writing prompt ({d} bytes)", .{ actor_name, model_name, prompt.len });

        var stderr_reader = StderrReader{ .file = child.stderr.?, .allocator = allocator };
        const stderr_thread = try std.Thread.spawn(.{}, StderrReader.run, .{&stderr_reader});

        try child.stdin.?.writeAll(prompt);
        child.stdin.?.close();
        child.stdin = null;

        var full_content = std.ArrayListUnmanaged(u8).empty;
        errdefer full_content.deinit(allocator);
        var usage = root.TokenUsage{};
        var parsed_thread_id: ?[]const u8 = null;
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(allocator);
        var lines_received: u32 = 0;

        const ParseAction = struct {
            fn processLine(
                line: []const u8,
                allocator_: std.mem.Allocator,
                full_content_: *std.ArrayListUnmanaged(u8),
                usage_: *root.TokenUsage,
                parsed_thread_id_: *?[]const u8,
                stream_cb_: ?StreamCallback,
                cb_ctx_: ?*anyopaque,
            ) !void {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0 or !std.mem.startsWith(u8, trimmed, "{")) return;

                const parsed = std.json.parseFromSlice(std.json.Value, allocator_, trimmed, .{}) catch return;
                defer parsed.deinit();
                if (parsed.value != .object) return;

                const obj = parsed.value.object;
                const type_val = obj.get("type") orelse return;
                if (type_val != .string) return;

                if (std.mem.eql(u8, type_val.string, "thread.started")) {
                    if (parsed_thread_id_.* == null) {
                        if (obj.get("thread_id")) |id_val| {
                            if (id_val == .string and id_val.string.len > 0) {
                                parsed_thread_id_.* = allocator_.dupe(u8, id_val.string) catch null;
                            }
                        }
                    }
                    return;
                }

                if (std.mem.eql(u8, type_val.string, "item.completed")) {
                    const item_val = obj.get("item") orelse return;
                    if (item_val != .object) return;
                    const item_type = item_val.object.get("type") orelse return;
                    if (item_type != .string) return;
                    if (!std.mem.eql(u8, item_type.string, "agent_message")) return;
                    const text_val = item_val.object.get("text") orelse return;
                    if (text_val != .string or text_val.string.len == 0) return;

                    try full_content_.appendSlice(allocator_, text_val.string);
                    if (stream_cb_) |cb| {
                        cb(cb_ctx_.?, .{ .delta = text_val.string, .is_final = false, .token_count = 0 });
                    }
                    return;
                }

                if (std.mem.eql(u8, type_val.string, "turn.completed")) {
                    const usage_val = obj.get("usage") orelse return;
                    if (usage_val != .object) return;

                    var prompt_tokens: u32 = 0;
                    var cached_tokens: u32 = 0;
                    var completion_tokens: u32 = 0;

                    if (usage_val.object.get("input_tokens")) |it| {
                        if (it == .integer) prompt_tokens = @intCast(it.integer);
                    }
                    if (usage_val.object.get("cached_input_tokens")) |ct| {
                        if (ct == .integer) cached_tokens = @intCast(ct.integer);
                    }
                    if (usage_val.object.get("output_tokens")) |ot| {
                        if (ot == .integer) completion_tokens = @intCast(ot.integer);
                    }

                    usage_.* = .{
                        .prompt_tokens = prompt_tokens + cached_tokens,
                        .completion_tokens = completion_tokens,
                        .total_tokens = prompt_tokens + cached_tokens + completion_tokens,
                    };
                }
            }
        };

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = child.stdout.?.read(&read_buf) catch |err| {
                log.err("{s}[codex] stdout read error: {}", .{ actor_name, err });
                break;
            };
            if (n == 0) break;
            for (read_buf[0..n]) |byte| {
                if (byte == '\n') {
                    lines_received += 1;
                    try ParseAction.processLine(
                        line_buf.items,
                        allocator,
                        &full_content,
                        &usage,
                        &parsed_thread_id,
                        stream_cb,
                        cb_ctx,
                    );
                    line_buf.clearRetainingCapacity();
                } else {
                    try line_buf.append(allocator, byte);
                }
            }
        }

        if (line_buf.items.len > 0) {
            lines_received += 1;
            try ParseAction.processLine(
                line_buf.items,
                allocator,
                &full_content,
                &usage,
                &parsed_thread_id,
                stream_cb,
                cb_ctx,
            );
        }

        stderr_thread.join();
        defer allocator.free(stderr_reader.buf);

        const is_capacity_error = stderr_reader.buf.len > 0 and (std.mem.indexOf(u8, stderr_reader.buf, "rate limit") != null or
            std.mem.indexOf(u8, stderr_reader.buf, "Rate limit") != null or
            std.mem.indexOf(u8, stderr_reader.buf, "429") != null or
            std.mem.indexOf(u8, stderr_reader.buf, "overloaded") != null or
            std.mem.indexOf(u8, stderr_reader.buf, "capacity") != null);

        const term = child.wait() catch |err| {
            log.err("{s}[{s}] wait() failed: {}", .{ actor_name, model_name, err });
            return InternalResult{
                .content = try full_content.toOwnedSlice(allocator),
                .usage = usage,
                .capacity_error = is_capacity_error,
                .thread_id = parsed_thread_id,
            };
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
            .thread_id = parsed_thread_id,
        };
    }

    fn chatWithSystemImpl(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const prompt = if (system_prompt) |s|
            try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ s, message })
        else
            try allocator.dupe(u8, message);
        defer allocator.free(prompt);

        const res = try runCodexFinal(allocator, prompt, model, "system", null, null, null, null, null);
        defer if (res.thread_id) |id| allocator.free(id);
        return res.content;
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsStreamingImpl(_: *anyopaque) bool {
        return true;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "codex-cli";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

/// Loads the stored Codex thread ID from the session directory.
/// Returns an owned slice or null. Caller must free if non-null.
fn loadThreadId(allocator: std.mem.Allocator, session_cwd: ?[]const u8) ?[]const u8 {
    const cwd = session_cwd orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, THREAD_ID_FILE }) catch return null;
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    const id = f.readToEndAlloc(allocator, 256) catch return null;
    const trimmed = std.mem.trim(u8, id, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(id);
        return null;
    }
    if (trimmed.len < id.len) {
        const owned = allocator.dupe(u8, trimmed) catch {
            allocator.free(id);
            return null;
        };
        allocator.free(id);
        return owned;
    }
    return id;
}

/// Stores the Codex thread ID into the session directory.
fn storeThreadId(session_cwd: ?[]const u8, thread_id: []const u8) void {
    const cwd = session_cwd orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, THREAD_ID_FILE }) catch return;
    const f = std.fs.createFileAbsolute(path, .{}) catch return;
    defer f.close();
    f.writeAll(thread_id) catch {};
    log.info("[codex] thread stored: {s}", .{thread_id});
}

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

fn constructFullAwarePrompt(
    allocator: std.mem.Allocator,
    request: ChatRequest,
    agent_name: []const u8,
) ![]const u8 {
    var full_prompt = std.ArrayListUnmanaged(u8).empty;
    errdefer full_prompt.deinit(allocator);

    try std.fmt.format(
        full_prompt.writer(allocator),
        "CHỈ THỊ HỆ THỐNG: Mày là {s} trên Slack. Hãy trả lời câu hỏi cuối cùng của người dùng. Tuyệt đối không lặp lại lịch sử, không in rác hệ thống.\n\n",
        .{agent_name},
    );

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

fn checkCliAvailable(allocator: std.mem.Allocator, cli_name: []const u8) !void {
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
        .Exited => |code| {
            if (code != 0) return error.CliNotFound;
        },
        else => return error.CliNotFound,
    }
}

test "CodexCliProvider.getNameImpl returns codex-cli" {
    const vtable = CodexCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("codex-cli", vtable.getName(@ptrCast(&dummy)));
}

test "CodexCliProvider default model is codex-mini-latest" {
    try std.testing.expectEqualStrings("codex-mini-latest", CodexCliProvider.DEFAULT_MODEL);
}

test "CodexCliProvider supports streaming" {
    const vtable = CodexCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expect(vtable.supports_streaming != null);
    try std.testing.expect(vtable.supports_streaming.?(@ptrCast(&dummy)));
}

test "CodexCliProvider supportsNativeTools returns false" {
    const vtable = CodexCliProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expect(!vtable.supportsNativeTools(@ptrCast(&dummy)));
}

test "CodexCliProvider checkCliAvailable returns CliNotFound for missing binary" {
    const result = checkCliAvailable(std.testing.allocator, "nonexistent_binary_xyzzy_codex_99999");
    try std.testing.expectError(error.CliNotFound, result);
}

test "extractLastUserMessage finds last user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.user("first"),
        ChatMessage.assistant("ok"),
        ChatMessage.user("second"),
    };
    const req = ChatRequest{ .messages = &msgs };
    const result = try extractLastUserMessage(std.testing.allocator, req);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("second", result);
}

test "extractLastUserMessage returns empty string for no user" {
    const msgs = [_]ChatMessage{
        ChatMessage.system("Be helpful"),
        ChatMessage.assistant("ok"),
    };
    const req = ChatRequest{ .messages = &msgs };
    const result = try extractLastUserMessage(std.testing.allocator, req);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "loadThreadId returns null for missing file" {
    try std.testing.expect(loadThreadId(std.testing.allocator, null) == null);
}

test "storeThreadId and loadThreadId roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);

    storeThreadId(dir_path, "thread-123");

    const loaded = loadThreadId(std.testing.allocator, dir_path);
    defer if (loaded) |id| std.testing.allocator.free(id);

    try std.testing.expect(loaded != null);
    try std.testing.expectEqualStrings("thread-123", loaded.?);
}
