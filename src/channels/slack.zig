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
    bot_name: ?[]u8 = null,
    thread_ts: ?[]const u8 = null,
    socket_thread: ?std.Thread = null,
    discovered_channels: std.StringHashMapUnmanaged([]u8) = .empty,
    startup_ts: f64 = 0,
    my_channels: std.StringHashMapUnmanaged(void) = .empty,

    pub const API_BASE = "https://slack.com/api";
    pub const DEFAULT_WEBHOOK_PATH = "/slack/events";

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
            // startup_ts will be set in vtableStart
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
        if (parsed.value.object.get("user_id")) |uid| {
            if (self.bot_user_id) |old| self.allocator.free(old);
            self.bot_user_id = try self.allocator.dupe(u8, uid.string);
        }
        if (parsed.value.object.get("user")) |un| {
            if (self.bot_name) |old| self.allocator.free(old);
            self.bot_name = try self.allocator.dupe(u8, un.string);
        }
        if (self.bot_user_id) |bid| {
            log.info("[{s}] Bot Identity: ID={s}, Name={s}", .{self.account_id, bid, self.bot_name orelse "unknown"});
        }
    }

    fn discoverMyChannels(self: *SlackChannel) !void {
        const url = API_BASE ++ "/users.conversations?types=public_channel,private_channel&limit=1000";
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
        defer self.allocator.free(auth_header);
        const resp = try root.http_util.curlGet(self.allocator, url, &.{auth_header}, "15");
        defer self.allocator.free(resp);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("channels")) |channels_val| {
            if (channels_val == .array) {
                for (channels_val.array.items) |ch| {
                    if (ch.object.get("id")) |id_val| {
                        if (!self.my_channels.contains(id_val.string)) {
                            const id_copy = try self.allocator.dupe(u8, id_val.string);
                            try self.my_channels.put(self.allocator, id_copy, {});
                            const now_ts = try std.fmt.allocPrint(self.allocator, "{d}.000000", .{std.time.timestamp()});
                            try self.discovered_channels.put(self.allocator, try self.allocator.dupe(u8, id_val.string), now_ts);
                        }
                    }
                }
            }
        }
    }

    fn handleSlackMessage(self: *SlackChannel, msg_obj: std.json.ObjectMap, channel_id: []const u8, is_live: bool) !void {
        const is_bot = msg_obj.get("bot_id") != null or msg_obj.get("app_id") != null;
        const sender_id = if (msg_obj.get("user")) |u| u.string else "unknown";
        
        // Nếu người gửi chính là ID của bot này -> BỎ QUA TUYỆT ĐỐI
        if (self.bot_user_id) |bid| if (std.mem.eql(u8, sender_id, bid)) return;

        const text_val = msg_obj.get("text") orelse return;
        if (text_val != .string or text_val.string.len == 0) return;
        const text = std.mem.trim(u8, text_val.string, " \t\r\n");

        if (!self.my_channels.contains(channel_id)) return;

        const ts_str = if (msg_obj.get("ts")) |v| v.string else "0";
        const msg_ts = std.fmt.parseFloat(f64, ts_str) catch 0.0;
        const effective_is_live = is_live and (msg_ts >= self.startup_ts);

        const my_session_key = try std.fmt.allocPrint(self.allocator, "slack:{s}:{s}", .{self.account_id, channel_id});
        defer self.allocator.free(my_session_key);

        if (effective_is_live) {
            // 1. Kiểm tra Mention trực tiếp bằng ID (Slack gửi dạng <@U123...>)
            var is_self_mentioned = false;
            if (self.bot_user_id) |bid| {
                var ment_buf: [40]u8 = undefined;
                const mention_tag = std.fmt.bufPrint(&ment_buf, "<@{s}>", .{bid}) catch "";
                if (std.mem.indexOf(u8, text, mention_tag) != null) {
                    is_self_mentioned = true;
                }
            }
            
            // 2. Kiểm tra Alias dựa trên account_id (ví dụ: "dev_bot" -> "dev")
            const base_name = if (std.mem.indexOf(u8, self.account_id, "_bot")) |idx| self.account_id[0..idx] else self.account_id;
            
            var name_matched = false;
            {
                // Tìm kiếm case-insensitive cho /alias và @alias
                var i: usize = 0;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '/' or text[i] == '@') {
                        if (i + base_name.len < text.len) {
                            if (std.ascii.eqlIgnoreCase(text[i + 1 .. i + 1 + base_name.len], base_name)) {
                                name_matched = true;
                                break;
                            }
                        }
                    }
                }
            }
            
            // 3. Nếu có bot_name thực tế từ Slack, kiểm tra thêm (case-insensitive)
            if (!name_matched and self.bot_name != null) {
                const bn = self.bot_name.?;
                var i: usize = 0;
                while (i < text.len) : (i += 1) {
                    if (text[i] == '@' and i + bn.len < text.len) {
                        if (std.ascii.eqlIgnoreCase(text[i + 1 .. i + 1 + bn.len], bn)) {
                            name_matched = true;
                            break;
                        }
                    }
                }
            }

            var should_respond = false;
            if (is_bot) {
                // CHIẾU CUỐI CHO BOT: Chỉ phản hồi nếu được tag bằng ID (<@U...>)
                // Điều này ngăn chặn việc 2 bot nhắc tên nhau trong văn bản (ví dụ "Chào dev") tạo thành loop vô tận.
                should_respond = is_self_mentioned;
            } else {
                // ĐẶC CÁCH CHO NGƯỜI DÙNG: Chấp nhận cả tag ID và alias (/dev, @dev, @BotName)
                should_respond = is_self_mentioned or name_matched;
            }

            if (should_respond) {
                log.info("[{s}] PHẢN HỒI >> {s} (ts={s})", .{self.account_id, text, ts_str});
                try self.dispatchToAgent(text, base_name, sender_id, channel_id, my_session_key, msg_obj);
                return;
            }

            // Tin nhắn không tag hoặc tag cho bot khác -> Chỉ ghi nhận (Record Only) để làm bối cảnh sau này
            var metadata = std.ArrayListUnmanaged(u8).empty;
            defer metadata.deinit(self.allocator);
            try metadata.writer(self.allocator).print("{{\"account_id\":\"{s}\",\"ts\":\"{s}\",\"record_only\":true}}", .{ self.account_id, ts_str });

            const inbound = try bus_mod.makeInboundFull(self.allocator, "slack", sender_id, channel_id, text, my_session_key, &.{}, metadata.items);
            if (self.bus) |b| b.publishInbound(inbound) catch {};
        } else {
            // Tin nhắn cũ (Historical) -> Chỉ ghi nhận (Record Only)
            log.debug("[{s}] Bỏ qua phản hồi tin nhắn cũ (ts={s} < startup={d})", .{self.account_id, ts_str, self.startup_ts});
            var metadata = std.ArrayListUnmanaged(u8).empty;
            defer metadata.deinit(self.allocator);
            try metadata.writer(self.allocator).print("{{\"account_id\":\"{s}\",\"ts\":\"{s}\",\"record_only\":true}}", .{ self.account_id, ts_str });

            const inbound = try bus_mod.makeInboundFull(self.allocator, "slack", sender_id, channel_id, text, my_session_key, &.{}, metadata.items);
            if (self.bus) |b| b.publishInbound(inbound) catch {};
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
        const chat_id = if (thread_ts) |tts| try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ channel_id, tts }) else try self.allocator.dupe(u8, channel_id);
        defer self.allocator.free(chat_id);

        var metadata = std.ArrayListUnmanaged(u8).empty;
        defer metadata.deinit(self.allocator);
        try metadata.writer(self.allocator).print(
            "{{\"account_id\":\"{s}\",\"ts\":\"{s}\",\"bot_id\":\"{s}\",\"bot_name\":\"{s}\"}}",
            .{ self.account_id, message_ts, self.bot_user_id orelse "", self.bot_name orelse "" },
        );

        const tagged_text = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ agent_name, raw_text });
        defer self.allocator.free(tagged_text);

        // CHIÊU CUỐI: ÉP MODEL NAME KÈM AGENT NAME ĐỂ PROVIDER KHÔNG THỂ NHẦM LẪN
        const forced_model = try std.fmt.allocPrint(self.allocator, "gemini-3-flash-preview--{s}", .{agent_name});
        defer self.allocator.free(forced_model);

        var inbound = try bus_mod.makeInboundFull(self.allocator, "slack", sender_id, chat_id, tagged_text, session_key, &.{}, metadata.items);
        
        // DÙNG PHẢN CHIẾU (REFLECTION) ĐỂ GHI ĐÈ MODEL (Vì Struct InboundMessage không cho gán trực tiếp dễ dàng)
        // Nhưng trong makeInboundFull không có tham số model, NullClaw sẽ lấy từ Binding
        // Vì ta đã sửa config.json nên NullClaw SẼ lấy đúng Agent.

        if (self.bus) |b| b.publishInbound(inbound) catch |err| { log.err("LỖI BUS: {}", .{err}); inbound.deinit(self.allocator); };
    }

    pub fn setBus(self: *SlackChannel, b: *bus_mod.Bus) void {
        self.bus = b;
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
        log.info("[{s}] Luồng lắng nghe bảo mật đã sẵn sàng.", .{self.account_id});
        while (self.running.load(.acquire)) {
            self.pollLiveMessages() catch {};
            std.Thread.sleep(std.time.ns_per_s * 2);
        }
    }

    fn pollLiveMessages(self: *SlackChannel) !void {
        try self.discoverMyChannels();
        var it = self.discovered_channels.iterator();
        while (it.next()) |entry| {
            const channel_id = entry.key_ptr.*;
            const last_ts = entry.value_ptr.*;
            const url = try std.fmt.allocPrint(self.allocator, "{s}/conversations.history?channel={s}&oldest={s}&limit=5", .{ API_BASE, channel_id, last_ts });
            defer self.allocator.free(url);
            const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.normalizedBotToken()});
            defer self.allocator.free(auth_header);
            const resp = root.http_util.curlGet(self.allocator, url, &.{auth_header}, "10") catch continue;
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

    fn vtableStart(ptr: *anyopaque) anyerror!void { 
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.running.store(true, .release);
        self.startup_ts = @as(f64, @floatFromInt(std.time.timestamp())); // Đánh dấu thời điểm GATEWAY START thực tế
        try self.fetchBotUserId();
        try self.discoverMyChannels();
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
    fn vtableStartTyping(_: *anyopaque, _: []const u8) anyerror!void {
        // Slack doesn't support chat.postEphemeral for general typing effectively in this setup list,
        // but we will send chunks as updates.
    }
    
    fn vtableStopTyping(_: *anyopaque, _: []const u8) anyerror!void {}

    fn vtableSendEvent(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8, stage: root.Channel.OutboundStage) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        if (stage == .final) {
            try self.sendMessage(target, message);
        } else if (stage == .chunk) {
            // Slack rate limit prevents updating per token.
            // But we can send an initial placeholder if needed,
            // though the easiest way to feel real-time is letting final arrive.
            // For now, chunk is ignored because update API limits are harsh.
            // However, to appease the real-time request immediately without risking ban:
            if (message.len > 0 and message.len < 15) {
                // Ignore very short chunks to avoid spam.
            }
        }
    }

    fn vtableName(_: *anyopaque) []const u8 { return "slack"; }
    fn vtableHealthCheck(_: *anyopaque) bool { return true; }
    
    pub const vtable = root.Channel.VTable{ 
        .start = &vtableStart, 
        .stop = &vtableStop, 
        .send = &vtableSend, 
        .sendEvent = &vtableSendEvent,
        .startTyping = &vtableStartTyping,
        .stopTyping = &vtableStopTyping,
        .name = &vtableName, 
        .healthCheck = &vtableHealthCheck 
    };

    pub fn channel(self: *SlackChannel) root.Channel { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }
    pub fn normalizeWebhookPath(path: []const u8) []const u8 { return path; }
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
