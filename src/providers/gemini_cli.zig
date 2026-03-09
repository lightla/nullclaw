const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const ChatMessage = root.ChatMessage;
const StreamChunk = root.StreamChunk;
const StreamCallback = root.StreamCallback;
const StreamChatResult = root.StreamChatResult;

/// Provider that delegates to the `gemini` CLI with Streaming support.
pub const GeminiCliProvider = struct {
    allocator: std.mem.Allocator,
    model: []const u8,

    const DEFAULT_MODEL = "auto";
    const CLI_NAME = "gemini";
    const TIMEOUT_NS: u64 = 120 * std.time.ns_per_s;

    pub fn init(allocator: std.mem.Allocator, model: ?[]const u8) !GeminiCliProvider {
        try checkCliAvailable(allocator, CLI_NAME);
        return .{
            .allocator = allocator,
            .model = model orelse DEFAULT_MODEL,
        };
    }

    pub fn provider(self: *GeminiCliProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
        .supports_streaming = supportsStreamingImpl,
        .supports_vision = supportsVisionImpl,
        .stream_chat = streamChatImpl,
    };

    fn supportsStreamingImpl(_: *anyopaque) bool {
        return true;
    }

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *GeminiCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        const prompt = if (system_prompt) |sys|
            try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ sys, message })
        else
            try allocator.dupe(u8, message);
        defer allocator.free(prompt);

        return (try runGemini(allocator, prompt, effective_model, null, null)).content;
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        _: f64,
    ) anyerror!ChatResponse {
        const self: *GeminiCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;

        const prompt = extractLastUserMessage(request.messages) orelse return error.NoUserMessage;

        const result = try runGemini(allocator, prompt, effective_model, null, null);

        return ChatResponse{
            .content = result.content,
            .model = try allocator.dupe(u8, effective_model),
            .usage = result.usage,
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
        const self: *GeminiCliProvider = @ptrCast(@alignCast(ptr));
        const effective_model = if (model.len > 0) model else self.model;
        const prompt = extractLastUserMessage(request.messages) orelse return error.NoUserMessage;

        const res = try runGemini(allocator, prompt, effective_model, callback, callback_ctx);
        return StreamChatResult{
            .content = res.content,
            .usage = res.usage,
        };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "gemini-cli";
    }

    fn deinitImpl(_: *anyopaque) void {}

    const InternalResult = struct {
        content: []const u8,
        usage: root.TokenUsage = .{},
    };

    fn runGemini(
        allocator: std.mem.Allocator,
        prompt: []const u8,
        model: []const u8,
        stream_cb: ?StreamCallback,
        cb_ctx: ?*anyopaque,
    ) !InternalResult {
        var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv_list.deinit(allocator);

        try argv_list.append(allocator, CLI_NAME);
        try argv_list.append(allocator, "-p");
        try argv_list.append(allocator, prompt);
        try argv_list.append(allocator, "--output-format");
        try argv_list.append(allocator, "stream-json");

        if (!std.mem.eql(u8, model, "auto") and !std.mem.eql(u8, model, "latest")) {
            try argv_list.append(allocator, "-m");
            try argv_list.append(allocator, model);
        }

        var child = std.process.Child.init(argv_list.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var full_content: std.ArrayListUnmanaged(u8) = .empty;
        errdefer full_content.deinit(allocator);

        const stdout_file = child.stdout.?;
        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buf.deinit(allocator);

        var usage = root.TokenUsage{};
        var read_buf: [4096]u8 = undefined;

        // Manual line-by-line reading for maximum compatibility
        while (true) {
            const n = stdout_file.read(&read_buf) catch break;
            if (n == 0) break;

            for (read_buf[0..n]) |byte| {
                if (byte == '\n') {
                    const line = line_buf.items;
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, "{")) {
                        const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
                            line_buf.clearRetainingCapacity();
                            continue;
                        };
                        defer parsed.deinit();

                        if (parsed.value == .object) {
                            const obj = parsed.value.object;
                            const type_val = obj.get("type") orelse continue;
                            
                            if (type_val == .string and std.mem.eql(u8, type_val.string, "message")) {
                                if (obj.get("role")) |role| {
                                    if (role == .string and std.mem.eql(u8, role.string, "assistant")) {
                                        if (obj.get("content")) |c| {
                                            if (c == .string) {
                                                try full_content.appendSlice(allocator, c.string);
                                                if (stream_cb) |cb| {
                                                    cb(cb_ctx.?, .{
                                                        .delta = c.string,
                                                        .is_final = false,
                                                        .token_count = 0,
                                                    });
                                                }
                                            }
                                        }
                                    }
                                }
                            } else if (type_val == .string and std.mem.eql(u8, type_val.string, "result")) {
                                if (obj.get("stats")) |stats_val| {
                                    if (stats_val == .object) {
                                        const stats = stats_val.object;
                                        usage.prompt_tokens = if (stats.get("input_tokens")) |it| (if (it == .integer) @intCast(it.integer) else 0) else 0;
                                        usage.completion_tokens = if (stats.get("output_tokens")) |ot| (if (ot == .integer) @intCast(ot.integer) else 0) else 0;
                                        usage.total_tokens = if (stats.get("total_tokens")) |tt| (if (tt == .integer) @intCast(tt.integer) else 0) else 0;
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

        const stderr_result = child.stderr.?.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
            _ = child.wait() catch {};
            return err;
        };
        defer allocator.free(stderr_result);

        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("Gemini CLI error (code {d}): {s}\n", .{ code, stderr_result });
                    return error.CliProcessFailed;
                }
            },
            else => return error.CliProcessFailed,
        }

        if (stream_cb) |cb| {
            cb(cb_ctx.?, .{
                .delta = "",
                .is_final = true,
                .token_count = 0,
            });
        }

        return InternalResult{
            .content = try full_content.toOwnedSlice(allocator),
            .usage = usage,
        };
    }
};

/// Check if CLI exists
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

fn extractLastUserMessage(messages: []const ChatMessage) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .user) return messages[i].content;
    }
    return null;
}
