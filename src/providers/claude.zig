const std = @import("std");
const root = @import("root.zig");
const anthropic = @import("anthropic.zig");
const platform = @import("../platform.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;
const StreamCallback = root.StreamCallback;
const StreamChatResult = root.StreamChatResult;

const log = std.log.scoped(.claude);

/// Credentials loaded from ~/.claude/.credentials.json (written by `claude auth login`).
pub const ClaudeCliCredentials = struct {
    access_token: []const u8,  // sk-ant-oat01-...
    refresh_token: ?[]const u8, // sk-ant-ort01-...
    expires_at: ?i64,           // unix seconds (converted from ms)

    /// Returns true if the token is expired (or within 5 minutes of expiring).
    pub fn isExpired(self: ClaudeCliCredentials) bool {
        const expiry = self.expires_at orelse return false;
        const now = std.time.timestamp();
        const buffer_seconds: i64 = 5 * 60;
        return now >= (expiry - buffer_seconds);
    }
};

/// Parse ~/.claude/.credentials.json:
/// { "claudeAiOauth": { "accessToken": "sk-ant-oat01-...", "refreshToken": "sk-ant-ort01-...", "expiresAt": <ms> } }
pub fn parseCredentialsJson(allocator: std.mem.Allocator, json_bytes: []const u8) ?ClaudeCliCredentials {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return null;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return null,
    };

    // Navigate into "claudeAiOauth" object
    const oauth_val = root_obj.get("claudeAiOauth") orelse return null;
    const oauth = switch (oauth_val) {
        .object => |obj| obj,
        else => return null,
    };

    // accessToken is required
    const at_val = oauth.get("accessToken") orelse return null;
    const at_str = switch (at_val) {
        .string => |s| s,
        else => return null,
    };
    if (at_str.len == 0) return null;
    const access_token = allocator.dupe(u8, at_str) catch return null;

    // refreshToken is optional
    const refresh_token: ?[]const u8 = if (oauth.get("refreshToken")) |rt_val| blk: {
        switch (rt_val) {
            .string => |s| {
                if (s.len > 0) break :blk allocator.dupe(u8, s) catch null;
                break :blk null;
            },
            else => break :blk null,
        }
    } else null;

    // expiresAt is in milliseconds — convert to seconds
    const expires_at: ?i64 = if (oauth.get("expiresAt")) |ea_val| blk: {
        switch (ea_val) {
            .integer => |i| break :blk @divFloor(i, 1000),
            .float => |f| break :blk @intFromFloat(f / 1000.0),
            else => break :blk null,
        }
    } else null;

    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at = expires_at,
    };
}

const RefreshResponse = struct {
    access_token: []const u8,
    expires_in: i64,
};

/// Refresh a Claude OAuth token.
/// Uses `builtin.is_test` guard to return a mock token during tests.
pub fn refreshOAuthToken(allocator: std.mem.Allocator, refresh_token: []const u8) !RefreshResponse {
    if (@import("builtin").is_test) {
        return .{
            .access_token = try allocator.dupe(u8, "test-refreshed-token"),
            .expires_in = 3600,
        };
    }

    // TODO: verify exact Claude Code OAuth refresh endpoint/format
    const url = "https://claude.ai/api/auth/oauth/token";

    var body_buf = std.ArrayListUnmanaged(u8).empty;
    defer body_buf.deinit(allocator);
    try body_buf.appendSlice(allocator, "{\"grant_type\":\"refresh_token\",\"refresh_token\":");
    try root.appendJsonString(&body_buf, allocator, refresh_token);
    try body_buf.append(allocator, '}');

    const resp_body = root.curlPostTimed(
        allocator,
        url,
        body_buf.items,
        &.{"Content-Type: application/json"},
        10,
    ) catch return error.RefreshFailed;
    defer allocator.free(resp_body);

    const p = std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{}) catch return error.RefreshFailed;
    defer p.deinit();
    if (p.value != .object) return error.RefreshFailed;
    const obj = p.value.object;
    if (obj.get("error") != null) return error.RefreshFailed;

    const new_at_val = obj.get("access_token") orelse return error.RefreshFailed;
    if (new_at_val != .string) return error.RefreshFailed;
    const new_at = allocator.dupe(u8, new_at_val.string) catch return error.RefreshFailed;

    const expires_in: i64 = if (obj.get("expires_in")) |ei| switch (ei) {
        .integer => |i| i,
        else => 3600,
    } else 3600;

    return .{ .access_token = new_at, .expires_in = expires_in };
}

/// Write updated credentials back to ~/.claude/.credentials.json.
pub fn writeCredentialsJson(allocator: std.mem.Allocator, creds: ClaudeCliCredentials, path: []const u8) !void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"claudeAiOauth\":{\"accessToken\":");
    try root.appendJsonString(&buf, allocator, creds.access_token);

    if (creds.refresh_token) |rt| {
        try buf.appendSlice(allocator, ",\"refreshToken\":");
        try root.appendJsonString(&buf, allocator, rt);
    }

    if (creds.expires_at) |exp| {
        try buf.appendSlice(allocator, ",\"expiresAt\":");
        var num_buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{exp * 1000}) catch return error.FormatError;
        try buf.appendSlice(allocator, num_str);
    }

    try buf.appendSlice(allocator, "}}");

    const file = std.fs.createFileAbsolute(path, .{ .mode = 0o600 }) catch return error.FileWriteError;
    defer file.close();
    try file.writeAll(buf.items);
}

/// Try to load Claude CLI OAuth credentials from ~/.claude/.credentials.json.
/// Refreshes the token if expired and a refresh_token is available.
/// Returns null on any error. Never reads files during tests.
pub fn tryLoadClaudeCliToken(allocator: std.mem.Allocator) ?ClaudeCliCredentials {
    if (@import("builtin").is_test) return null;

    const home = platform.getHomeDir(allocator) catch return null;
    defer allocator.free(home);

    const path = std.fs.path.join(allocator, &.{ home, ".claude", ".credentials.json" }) catch return null;
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const json_bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(json_bytes);

    const creds = parseCredentialsJson(allocator, json_bytes) orelse return null;

    if (creds.isExpired()) {
        if (creds.refresh_token) |rt| {
            if (refreshOAuthToken(allocator, rt)) |refreshed| {
                const now = std.time.timestamp();
                const ttl: i64 = if (refreshed.expires_in > 0) refreshed.expires_in else 3600;
                const new_expires_at = std.math.add(i64, now, ttl) catch std.math.maxInt(i64);

                const refreshed_creds = ClaudeCliCredentials{
                    .access_token = refreshed.access_token,
                    .refresh_token = allocator.dupe(u8, rt) catch {
                        allocator.free(refreshed.access_token);
                        allocator.free(creds.access_token);
                        if (creds.refresh_token) |r| allocator.free(r);
                        return null;
                    },
                    .expires_at = new_expires_at,
                };

                writeCredentialsJson(allocator, refreshed_creds, path) catch {};

                allocator.free(creds.access_token);
                if (creds.refresh_token) |r| allocator.free(r);

                return refreshed_creds;
            } else |_| {}
        }

        allocator.free(creds.access_token);
        if (creds.refresh_token) |rt| allocator.free(rt);
        return null;
    }

    return creds;
}

/// Authentication method for Claude.
pub const ClaudeAuth = union(enum) {
    /// Explicit api_key from config.
    explicit_key: []const u8,
    /// OAuth/setup token from ANTHROPIC_OAUTH_TOKEN env var.
    env_oauth_token: []const u8,
    /// API key from ANTHROPIC_API_KEY env var.
    env_api_key: []const u8,
    /// OAuth access token from ~/.claude/.credentials.json (`claude auth login`).
    oauth_token: []const u8,

    pub fn credential(self: ClaudeAuth) []const u8 {
        return switch (self) {
            inline else => |v| v,
        };
    }

    pub fn source(self: ClaudeAuth) []const u8 {
        return switch (self) {
            .explicit_key => "config",
            .env_oauth_token => "ANTHROPIC_OAUTH_TOKEN",
            .env_api_key => "ANTHROPIC_API_KEY",
            .oauth_token => "~/.claude/.credentials.json",
        };
    }
};

/// Claude provider with automatic credential discovery:
/// 1. Explicit api_key from config
/// 2. ANTHROPIC_OAUTH_TOKEN env var (OAuth/setup token)
/// 3. ANTHROPIC_API_KEY env var
/// 4. ~/.claude/.credentials.json (from `claude auth login`)
///
/// Delegates all API calls to AnthropicProvider internally.
pub const ClaudeProvider = struct {
    inner: anthropic.AnthropicProvider,
    auth: ?ClaudeAuth,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, api_key: ?[]const u8, base_url: ?[]const u8) ClaudeProvider {
        var auth: ?ClaudeAuth = null;

        // 1. Explicit key from config
        if (api_key) |key| {
            const trimmed = std.mem.trim(u8, key, " \t\r\n");
            if (trimmed.len > 0) auth = .{ .explicit_key = trimmed };
        }

        // 2. ANTHROPIC_OAUTH_TOKEN env var
        if (auth == null) {
            if (loadNonEmptyEnv(allocator, "ANTHROPIC_OAUTH_TOKEN")) |value|
                auth = .{ .env_oauth_token = value };
        }

        // 3. ANTHROPIC_API_KEY env var
        if (auth == null) {
            if (loadNonEmptyEnv(allocator, "ANTHROPIC_API_KEY")) |value|
                auth = .{ .env_api_key = value };
        }

        // 4. ~/.claude/.credentials.json (claude auth login)
        if (auth == null) {
            if (tryLoadClaudeCliToken(allocator)) |creds| {
                auth = .{ .oauth_token = creds.access_token };
                // refresh_token only needed for the initial load; not stored in ClaudeAuth
                if (creds.refresh_token) |rt| allocator.free(rt);
            }
        }

        if (auth) |a| log.info("claude auth source: {s}", .{a.source()});

        return .{
            .inner = anthropic.AnthropicProvider.init(
                allocator,
                if (auth) |a| a.credential() else null,
                base_url,
            ),
            .auth = auth,
            .allocator = allocator,
        };
    }

    pub fn provider(self: *ClaudeProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
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

    // All API calls delegate through self.inner.provider() → AnthropicProvider vtable.

    fn chatWithSystemImpl(ptr: *anyopaque, allocator: std.mem.Allocator, system_prompt: ?[]const u8, message: []const u8, model: []const u8, temperature: f64) anyerror![]const u8 {
        const self: *ClaudeProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().chatWithSystem(allocator, system_prompt, message, model, temperature);
    }

    fn chatImpl(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, model: []const u8, temperature: f64) anyerror!ChatResponse {
        const self: *ClaudeProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().chat(allocator, request, model, temperature);
    }

    fn streamChatImpl(ptr: *anyopaque, allocator: std.mem.Allocator, request: ChatRequest, model: []const u8, temperature: f64, callback: StreamCallback, callback_ctx: *anyopaque) anyerror!StreamChatResult {
        const self: *ClaudeProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().streamChat(allocator, request, model, temperature, callback, callback_ctx);
    }

    fn supportsNativeToolsImpl(ptr: *anyopaque) bool {
        const self: *ClaudeProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().supportsNativeTools();
    }

    fn supportsStreamingImpl(ptr: *anyopaque) bool {
        const self: *ClaudeProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().supportsStreaming();
    }

    fn supportsVisionImpl(ptr: *anyopaque) bool {
        const self: *ClaudeProvider = @ptrCast(@alignCast(ptr));
        return self.inner.provider().supportsVision();
    }

    fn getNameImpl(_: *anyopaque) []const u8 { return "claude"; }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ClaudeProvider = @ptrCast(@alignCast(ptr));
        if (self.auth) |auth| {
            switch (auth) {
                .env_oauth_token => |v| self.allocator.free(v),
                .env_api_key => |v| self.allocator.free(v),
                .oauth_token => |v| self.allocator.free(v),
                .explicit_key => {}, // not owned — points into config string
            }
        }
        self.auth = null;
    }
};

fn loadNonEmptyEnv(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, name)) |value| {
        defer allocator.free(value);
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed) catch null;
        return null;
    } else |_| return null;
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "parseCredentialsJson extracts access_token" {
    const json =
        \\{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-xyz","expiresAt":9999999999000}}
    ;
    const creds = parseCredentialsJson(std.testing.allocator, json).?;
    defer std.testing.allocator.free(creds.access_token);
    defer if (creds.refresh_token) |rt| std.testing.allocator.free(rt);
    try std.testing.expectEqualStrings("sk-ant-oat01-abc", creds.access_token);
    try std.testing.expectEqualStrings("sk-ant-ort01-xyz", creds.refresh_token.?);
}

test "parseCredentialsJson converts expiresAt ms to seconds" {
    const json =
        \\{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","expiresAt":1773751119591}}
    ;
    const creds = parseCredentialsJson(std.testing.allocator, json).?;
    defer std.testing.allocator.free(creds.access_token);
    try std.testing.expectEqual(@as(?i64, 1773751119), creds.expires_at);
}

test "parseCredentialsJson returns null for missing claudeAiOauth" {
    const json =
        \\{"other":{"accessToken":"sk-ant-oat01-abc"}}
    ;
    try std.testing.expect(parseCredentialsJson(std.testing.allocator, json) == null);
}

test "parseCredentialsJson returns null for missing accessToken" {
    const json =
        \\{"claudeAiOauth":{"refreshToken":"sk-ant-ort01-xyz"}}
    ;
    try std.testing.expect(parseCredentialsJson(std.testing.allocator, json) == null);
}

test "parseCredentialsJson returns null for empty accessToken" {
    const json =
        \\{"claudeAiOauth":{"accessToken":""}}
    ;
    try std.testing.expect(parseCredentialsJson(std.testing.allocator, json) == null);
}

test "parseCredentialsJson handles invalid json" {
    try std.testing.expect(parseCredentialsJson(std.testing.allocator, "not json") == null);
}

test "ClaudeCliCredentials.isExpired returns false when expires_at is null" {
    const creds = ClaudeCliCredentials{
        .access_token = "tok",
        .refresh_token = null,
        .expires_at = null,
    };
    try std.testing.expect(!creds.isExpired());
}

test "ClaudeCliCredentials.isExpired returns true when past expiry" {
    const creds = ClaudeCliCredentials{
        .access_token = "tok",
        .refresh_token = null,
        .expires_at = 1, // far in the past
    };
    try std.testing.expect(creds.isExpired());
}

test "ClaudeCliCredentials.isExpired returns false for future expiry" {
    const creds = ClaudeCliCredentials{
        .access_token = "tok",
        .refresh_token = null,
        .expires_at = std.math.maxInt(i64),
    };
    try std.testing.expect(!creds.isExpired());
}

test "ClaudeAuth.source returns correct strings" {
    const a: ClaudeAuth = .{ .explicit_key = "k" };
    try std.testing.expectEqualStrings("config", a.source());
    const b: ClaudeAuth = .{ .env_api_key = "k" };
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", b.source());
    const c: ClaudeAuth = .{ .oauth_token = "k" };
    try std.testing.expectEqualStrings("~/.claude/.credentials.json", c.source());
}

test "ClaudeProvider.getName returns claude" {
    const vt = ClaudeProvider.vtable;
    var dummy: u8 = 0;
    try std.testing.expectEqualStrings("claude", vt.getName(@ptrCast(&dummy)));
}

test "tryLoadClaudeCliToken returns null in test mode" {
    // builtin.is_test guard ensures no real file I/O in tests
    try std.testing.expect(tryLoadClaudeCliToken(std.testing.allocator) == null);
}

test "refreshOAuthToken returns mock token in test mode" {
    const result = try refreshOAuthToken(std.testing.allocator, "sk-ant-ort01-fake");
    defer std.testing.allocator.free(result.access_token);
    try std.testing.expectEqualStrings("test-refreshed-token", result.access_token);
    try std.testing.expectEqual(@as(i64, 3600), result.expires_in);
}
