const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const bus_mod = @import("../bus.zig");
const websocket = @import("../websocket.zig");

const log = std.log.scoped(.slack);

pub const SlackChannel = struct {
    allocator: std.mem.Allocator,
    account_id: []const u8 = "default",
    bot_token: []const u8,
    app_token: ?[]const u8,
    channel_id: ?[]const u8 = null,
    allow_from: []const []const u8,
    reply_to_mode: config_types.SlackReplyToMode = .off,
    policy: root.ChannelPolicy = .{},
    bus: ?*bus_mod.Bus = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    bot_user_id: ?[]u8 = null,
    thread_ts: ?[]const u8 = null,
    socket_thread: ?std.Thread = null,
    discovered_channels: std.StringHashMapUnmanaged([]u8) = .empty, // Lưu ID channel và last_ts

    pub const API_BASE = "https://slack.com/api";

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.SlackConfig) SlackChannel {
        return .{
            .allocator = allocator,
            .bot_token = cfg.bot_token,
            .app_token = cfg.app_token,
            .channel_id = cfg.channel_id,
            .allow_from = cfg.allow_from,
            .account_id = cfg.account_id,
            .reply_to_mode = cfg.reply_to_mode,
            .policy = .{ .group = .open, .allowlist = cfg.allow_from },
        };
    }

    fn normalizedBotToken(self: *const SlackChannel) []const u8 {
        return std.mem.trim(u8, self.bot_token, " \t\r\n");
    }

    fn fetchBotUserId(self: *SlackChannel) !void {
        const url = API_BASE ++ "/auth.test";
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
        defer self.allocator.free(auth_header);
        const resp = try root.http_util.curlGet(self.allocator, url, &.{auth_header}, "15");
        defer self.allocator.free(resp);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("user_id")) |uid| self.bot_user_id = try self.allocator.dupe(u8, uid.string);
    }

    fn handleSlackMessage(self: *SlackChannel, msg_obj: std.json.ObjectMap, channel_id: []const u8, is_live: bool) !void {
        if (msg_obj.get("bot_id")) |_| return;
        const text_val = msg_obj.get("text") orelse return;
        if (text_val != .string) return;
        const text = std.mem.trim(u8, text_val.string, " \t\r\n");
        const sender_id = if (msg_obj.get("user")) |u| u.string else "unknown";

        if (self.bot_user_id) |bid| if (std.mem.eql(u8, sender_id, bid)) return;

        const my_session_key = try std.fmt.allocPrint(self.allocator, "slack:{s}:{s}", .{self.account_id, channel_id});
        defer self.allocator.free(my_session_key);

        if (is_live) {
            log.info("[{s}] LIVE >> {s}", .{self.account_id, text});
            
            const is_dev_cmd = std.mem.indexOf(u8, text, "/dev") != null;
            const is_mentor_cmd = std.mem.indexOf(u8, text, "/mentor") != null;

            if (std.mem.eql(u8, self.account_id, "dev_bot") and is_dev_cmd) {
                try self.dispatchToAgent(text, "dev", sender_id, channel_id, my_session_key, msg_obj);
            } else if (std.mem.eql(u8, self.account_id, "mentor_bot") and is_mentor_cmd) {
                try self.dispatchToAgent(text, "mentor", sender_id, channel_id, my_session_key, msg_obj);
            } else {
                try self.dispatchToAgent(text, "monitor", sender_id, channel_id, my_session_key, msg_obj);
            }
        } else {
            try self.dispatchToAgent(text, "monitor", sender_id, channel_id, my_session_key, msg_obj);
        }
    }

    fn dispatchToAgent(
        self: *SlackChannel,
        raw_text: []const u8,
        agent_name: []const u8,
        sender_id: []const u8,
        channel_id: []const u8,
        session_key: []const u8,
        msg_obj: std.json.ObjectMap,
    ) !void {
        const message_ts = if (msg_obj.get("ts")) |ts_val| ts_val.string else "";
        const thread_ts = if (msg_obj.get("thread_ts")) |thread_ts_val| thread_ts_val.string else null;
        const is_thread_reply = if (thread_ts) |tts| if (message_ts.len > 0) !std.mem.eql(u8, tts, message_ts) else true else false;
        const effective_thread_ts: ?[]const u8 = switch (self.reply_to_mode) {
            .off => if (is_thread_reply) thread_ts else null,
            .all => thread_ts orelse (if (message_ts.len > 0) message_ts else null),
        };
        const chat_id = if (effective_thread_ts) |tts| try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ channel_id, tts }) else try self.allocator.dupe(u8, channel_id);
        defer self.allocator.free(chat_id);

        const tagged_text = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ agent_name, raw_text });
        defer self.allocator.free(tagged_text);

        var metadata = std.ArrayListUnmanaged(u8).empty;
        defer metadata.deinit(self.allocator);
        try metadata.writer(self.allocator).print("{{\"account_id\":\"{s}\",\"agent_name\":\"{s}\",\"channel_id\":\"{s}\",\"ts\":\"{s}\"}}", .{ self.account_id, agent_name, channel_id, message_ts });

        const inbound = try bus_mod.makeInboundFull(self.allocator, "slack", sender_id, chat_id, tagged_text, session_key, &.{}, metadata.items);
        if (self.bus) |b| b.publishInbound(inbound) catch |err| { log.err("LỖI BUS: {}", .{err}); inbound.deinit(self.allocator); } else inbound.deinit(self.allocator);
    }

    pub fn sendMessage(self: *SlackChannel, target_channel: []const u8, text: []const u8) !void {
        if (text.len == 0) return;
        const url = API_BASE ++ "/chat.postMessage";
        const actual_channel = self.parseTarget(target_channel);
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(self.allocator);
        try body.writer(self.allocator).print("{{\"channel\":\"{s}\",\"text\":", .{actual_channel});
        try root.json_util.appendJsonString(&body, self.allocator, text);
        if (self.thread_ts) |tts| try body.writer(self.allocator).print(",\"thread_ts\":\"{s}\"", .{tts});
        try body.appendSlice(self.allocator, "}");
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
        defer self.allocator.free(auth_header);
        _ = try root.http_util.curlPost(self.allocator, url, body.items, &.{auth_header});
    }

    fn socketLoop(self: *SlackChannel) void {
        log.info("[{s}] Luồng lắng nghe 100% Live.", .{self.account_id});
        _ = std.Thread.spawn(.{}, backgroundHistoryLoader, .{self}) catch {};
        while (self.running.load(.acquire)) {
            self.pollLiveMessages() catch {};
            std.Thread.sleep(std.time.ns_per_s * 2);
        }
    }

    fn pollLiveMessages(self: *SlackChannel) !void {
        var it = self.discovered_channels.iterator();
        while (it.next()) |entry| {
            const channel_id = entry.key_ptr.*;
            const last_ts = entry.value_ptr.*;
            const url = try std.fmt.allocPrint(self.allocator, "{s}/conversations.history?channel={s}&oldest={s}&limit=5", .{ API_BASE, channel_id, last_ts });
            defer self.allocator.free(url);
            
            const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
            defer self.allocator.free(auth_header);
            const resp = root.http_util.curlGet(self.allocator, url, &.{auth_header}, "5") catch continue;
            defer self.allocator.free(resp);
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value.object.get("messages")) |messages_val| {
                if (messages_val == .array and messages_val.array.items.len > 0) {
                    const newest_ts = messages_val.array.items[0].object.get("ts").?.string;
                    self.allocator.free(entry.value_ptr.*);
                    entry.value_ptr.* = try self.allocator.dupe(u8, newest_ts);

                    var i = messages_val.array.items.len;
                    while (i > 0) {
                        i -= 1;
                        try self.handleSlackMessage(messages_val.array.items[i].object, channel_id, true);
                    }
                }
            }
        }
    }

    fn backgroundHistoryLoader(self: *SlackChannel) void {
        std.Thread.sleep(std.time.ns_per_s * 2);
        const url = API_BASE ++ "/users.conversations?types=public_channel,private_channel";
        const bot_token_str = self.normalizedBotToken();
        const auth_header = std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{bot_token_str}) catch return;
        defer self.allocator.free(auth_header);
        const resp = root.http_util.curlGet(self.allocator, url, &.{auth_header}, "15") catch return;
        defer self.allocator.free(resp);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value.object.get("channels")) |channels_val| {
            if (channels_val == .array) {
                for (channels_val.array.items) |ch| {
                    if (ch.object.get("id")) |id_val| {
                        const id = id_val.string;
                        const now_ts = std.fmt.allocPrint(self.allocator, "{d}.000000", .{std.time.timestamp()}) catch continue;
                        const id_copy = self.allocator.dupe(u8, id) catch continue;
                        self.discovered_channels.put(self.allocator, id_copy, now_ts) catch {};
                        log.info("[{s}] Đang nạp SQLite ngầm cho channel: {s}", .{self.account_id, id});
                        self.pollHistoryDeep(id) catch {};
                    }
                }
            }
        }
    }

    fn pollHistoryDeep(self: *SlackChannel, channel_id: []const u8) !void {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/conversations.history?channel={s}&limit=20", .{ API_BASE, channel_id });
        defer self.allocator.free(url);
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
        defer self.allocator.free(auth_header);
        const resp = try root.http_util.curlGet(self.allocator, url, &.{auth_header}, "30");
        defer self.allocator.free(resp);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("messages")) |messages_val| {
            if (messages_val == .array) {
                var i = messages_val.array.items.len;
                while (i > 0) {
                    i -= 1;
                    try self.handleSlackMessage(messages_val.array.items[i].object, channel_id, false);
                }
            }
        }
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void { 
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.running.store(true, .release);
        try self.fetchBotUserId();
        self.socket_thread = try std.Thread.spawn(.{}, socketLoop, .{self});
    }
    fn vtableStop(ptr: *anyopaque) void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.running.store(false, .release);
        if (self.socket_thread) |t| t.join();
    }
    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }
    fn vtableName(_: *anyopaque) []const u8 { return "slack"; }
    fn vtableHealthCheck(_: *anyopaque) bool { return true; }
    pub const vtable = root.Channel.VTable{ .start = &vtableStart, .stop = &vtableStop, .send = &vtableSend, .name = &vtableName, .healthCheck = &vtableHealthCheck };
    pub fn channel(self: *SlackChannel) root.Channel { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn normalizeWebhookPath(path: []const u8) []const u8 { return path; }
    pub const DEFAULT_WEBHOOK_PATH = "/slack/events";
    pub fn parseTarget(self: *SlackChannel, target: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, target, ':')) |idx| {
            const parsed_thread = target[idx + 1 ..];
            self.thread_ts = if (parsed_thread.len > 0) parsed_thread else null;
            return target[0..idx];
        }
        self.thread_ts = null;
        return target;
    }
    pub fn shouldHandle(self: *SlackChannel, _: []const u8, _: bool, _: []const u8, _: ?[]const u8) bool { _ = self; return true; }
    pub fn processHistoryMessage(self: *SlackChannel, msg_obj: std.json.ObjectMap, channel_id: []const u8) !void {
        try self.handleSlackMessage(msg_obj, channel_id, true);
    }
};
