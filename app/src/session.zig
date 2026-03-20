//! Session Manager — persistent in-process Agent sessions.
//!
//! Replaces subprocess spawning with reusable Agent instances keyed by
//! session_key (e.g. "telegram:chat123"). Each session maintains its own
//! conversation history across turns.
//!
//! Thread safety: SessionManager.mutex guards the sessions map (short hold),
//! Session.mutex serializes turn() per session (may be long). Different
//! sessions are processed in parallel.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;
const Agent = @import("agent/root.zig").Agent;
const ConversationContext = @import("agent/prompt.zig").ConversationContext;
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const providers_factory = @import("providers/factory.zig");
const providers_api_key = @import("providers/api_key.zig");
const memory_mod = @import("memory/root.zig");
const Memory = memory_mod.Memory;
const observability = @import("observability.zig");
const Observer = observability.Observer;
const tools_mod = @import("tools/root.zig");
const Tool = tools_mod.Tool;
const SecurityPolicy = @import("security/policy.zig").SecurityPolicy;
const streaming = @import("streaming.zig");
const thread_stacks = @import("thread_stacks.zig");
const NamedAgentConfig = @import("config_types.zig").NamedAgentConfig;
const SlackConfig = @import("config_types.zig").SlackConfig;
const http_util = @import("http_util.zig");
const log = std.log.scoped(.session);
const MESSAGE_LOG_MAX_BYTES: usize = 4096;
const TOKEN_USAGE_LEDGER_FILENAME = "llm_token_usage.jsonl";
const NS_PER_SEC: i128 = std.time.ns_per_s;

/// Apply model and system_prompt overrides from a NamedAgentConfig to an Agent.
/// Returns true so callers can set a `resolved` flag in a single expression.
fn applyNamedAgentConfig(allocator: Allocator, agent: *Agent, named: NamedAgentConfig) !bool {
    const model_copy = try allocator.dupe(u8, named.model);
    if (agent.model_name_owned) allocator.free(agent.model_name);
    agent.model_name = model_copy;
    agent.model_name_owned = true;
    agent.default_model = model_copy;
    agent.actor_name = named.name;
    agent.fallback_model = named.fallback_model;
    if (named.system_prompt) |sp| {
        try agent.history.append(allocator, .{
            .role = .system,
            .content = try allocator.dupe(u8, sp),
        });
        agent.has_system_prompt = true;
    }
    return true;
}

const MemDirective = union(enum) {
    all,
    last: usize,
    query: []const u8,
};

pub const DeleteDirective = union(enum) {
    all,
    last: usize,
};

fn parseMemDirectiveBody(body: []const u8) ?MemDirective {
    const trimmed = std.mem.trim(u8, body, " \t");
    if (trimmed.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(trimmed, "all")) return .all;

    if (trimmed.len > 4 and std.ascii.eqlIgnoreCase(trimmed[0..4], "last")) {
        const separator = trimmed[4];
        if (separator == ' ' or separator == '\t') {
            const n_str = std.mem.trim(u8, trimmed[5..], " \t");
            const n = std.fmt.parseUnsigned(usize, n_str, 10) catch return null;
            return .{ .last = n };
        }
    }

    return .{ .query = trimmed };
}

/// Parses standalone memory directives:
///   - `mem: all`
///   - `mem: last 10`
///   - `mem: docker issue`
///   - legacy `:mem ...`
fn parseStandaloneMemDirective(content: []const u8) ?MemDirective {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "mem:")) {
        return parseMemDirectiveBody(trimmed["mem:".len..]);
    }

    if (!std.mem.startsWith(u8, trimmed, ":mem")) return null;
    const after = trimmed[":mem".len..];
    if (after.len == 0) return null;
    if (after[0] != ' ' and after[0] != '\t') return null;
    return parseMemDirectiveBody(after[1..]);
}

/// Legacy compatibility for inline `:mem ...` directives embedded in a message.
fn parseInlineLegacyMemDirective(content: []const u8) ?MemDirective {
    const prefix = ":mem ";
    const idx = std.mem.indexOf(u8, content, prefix) orelse return null;
    const after = content[idx + prefix.len ..];
    const end = std.mem.indexOfAny(u8, after, "\r\n") orelse after.len;
    return parseMemDirectiveBody(after[0..end]);
}

fn detectMemDirective(content: []const u8) ?MemDirective {
    return parseStandaloneMemDirective(content) orelse parseInlineLegacyMemDirective(content);
}

/// Detects `:sync` command in message.
fn detectSync(content: []const u8) bool {
    return std.mem.indexOf(u8, content, ":sync") != null;
}

pub fn isSyncCommand(content: []const u8) bool {
    return detectSync(content);
}

fn detectHelp(content: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, content, " \t\r\n"), ":help");
}

pub fn isHelpCommand(content: []const u8) bool {
    return detectHelp(content);
}

fn detectDeleteDirective(content: []const u8) ?DeleteDirective {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, ":del")) return null;

    const after = trimmed[":del".len..];
    if (after.len == 0) return null;
    if (after[0] != ' ' and after[0] != '\t') return null;

    const arg = std.mem.trim(u8, after[1..], " \t");
    if (arg.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(arg, "all")) return .all;

    const count = std.fmt.parseUnsigned(usize, arg, 10) catch return null;
    if (count == 0) return null;
    return .{ .last = count };
}

pub fn parseDeleteCommand(content: []const u8) ?DeleteDirective {
    return detectDeleteDirective(content);
}

pub fn isSystemOnlySlackAccount(config: *const Config, account_id: ?[]const u8) bool {
    const aid = account_id orelse return false;
    for (config.channels.slack) |slack_cfg| {
        if (std.mem.eql(u8, slack_cfg.account_id, aid)) {
            return slack_cfg.system_only;
        }
    }
    return false;
}

pub fn shouldHandleSlackHelp(config: *const Config, account_id: ?[]const u8) bool {
    return account_id != null and isSystemOnlySlackAccount(config, account_id);
}

fn loadHelpMessageFromRoot(allocator: Allocator, root: []const u8) ?[]u8 {
    var current = root;
    var depth: usize = 0;
    while (depth < 4 and current.len > 0) : (depth += 1) {
        const candidate = std.fs.path.join(allocator, &.{ current, ".knowledge", "command.md" }) catch return null;
        defer allocator.free(candidate);

        const file = std.fs.openFileAbsolute(candidate, .{}) catch {
            current = std.fs.path.dirname(current) orelse break;
            continue;
        };
        defer file.close();

        return file.readToEndAlloc(allocator, 64 * 1024) catch null;
    }
    return null;
}

pub fn loadHelpMessage(allocator: Allocator, config: *const Config) ![]u8 {
    if (config.project_dir.len > 0) {
        if (loadHelpMessageFromRoot(allocator, config.project_dir)) |content| return content;
    }
    if (std.fs.path.dirname(config.config_path)) |config_dir| {
        if (loadHelpMessageFromRoot(allocator, config_dir)) |content| return content;
    }
    return allocator.dupe(
        u8,
        "Help file not found. Expected `.knowledge/command.md` near the project root.",
    );
}

/// Builds memory context from already-fetched entries.
/// Internal autosave/hygiene/bootstrap entries are filtered out.
/// Caller owns the returned slice. Returns null when nothing visible remains.
fn buildMemContextFromEntries(allocator: Allocator, entries: []const memory_mod.MemoryEntry) ?[]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    buf.appendSlice(allocator, "[BỘ NHỚ LIÊN QUAN TỪ LỊCH SỬ]\n") catch return null;
    var visible_count: usize = 0;
    for (entries) |e| {
        if (memory_mod.isInternalMemoryEntryKeyOrContent(e.key, e.content)) continue;
        std.fmt.format(buf.writer(allocator), "- {s}\n", .{e.content}) catch continue;
        visible_count += 1;
    }
    if (visible_count == 0) return null;

    return buf.toOwnedSlice(allocator) catch null;
}

/// Builds enriched content string from already-fetched entries.
/// Caller owns the returned slice. Returns null on error or when nothing visible remains.
fn buildMemEnrichedContentFromEntries(allocator: Allocator, entries: []const memory_mod.MemoryEntry, query: []const u8) ?[]const u8 {
    const context = buildMemContextFromEntries(allocator, entries) orelse return null;
    defer allocator.free(context);

    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ context, query }) catch null;
}

fn buildMemDirectiveContext(
    allocator: Allocator,
    mem: Memory,
    session_key: []const u8,
    directive: MemDirective,
) ?[]const u8 {
    switch (directive) {
        .all => {
            const entries = mem.list(allocator, null, null) catch return null;
            defer memory_mod.freeEntries(allocator, entries);
            return buildMemContextFromEntries(allocator, entries);
        },
        .last => |n| {
            const entries = mem.list(allocator, null, session_key) catch return null;
            defer memory_mod.freeEntries(allocator, entries);
            const start = if (entries.len > n) entries.len - n else 0;
            return buildMemContextFromEntries(allocator, entries[start..]);
        },
        .query => |query| {
            const entries = mem.recall(allocator, query, 10, session_key) catch return null;
            defer memory_mod.freeEntries(allocator, entries);
            return buildMemContextFromEntries(allocator, entries);
        },
    }
}

fn buildMemDirectiveEnrichedContent(
    allocator: Allocator,
    mem: Memory,
    session_key: []const u8,
    raw_content: []const u8,
    directive: MemDirective,
) ?[]const u8 {
    switch (directive) {
        .all => {
            const entries = mem.list(allocator, null, null) catch return null;
            defer memory_mod.freeEntries(allocator, entries);
            return buildMemEnrichedContentFromEntries(allocator, entries, raw_content);
        },
        .last => |n| {
            const entries = mem.list(allocator, null, session_key) catch return null;
            defer memory_mod.freeEntries(allocator, entries);
            const start = if (entries.len > n) entries.len - n else 0;
            return buildMemEnrichedContentFromEntries(allocator, entries[start..], raw_content);
        },
        .query => |query| {
            const entries = mem.recall(allocator, query, 10, session_key) catch return null;
            defer memory_mod.freeEntries(allocator, entries);
            return buildMemEnrichedContentFromEntries(allocator, entries, query);
        },
    }
}

fn messageLogPreview(text: []const u8) struct { slice: []const u8, truncated: bool } {
    if (text.len <= MESSAGE_LOG_MAX_BYTES) {
        return .{ .slice = text, .truncated = false };
    }
    return .{ .slice = text[0..MESSAGE_LOG_MAX_BYTES], .truncated = true };
}

fn emitSilentMemDirectiveTrace(session_key: []const u8, content: []const u8, staged_context: bool) void {
    if (builtin.is_test) return;
    std.debug.print(
        "[mem] session={s} command={f} slack_reply=suppressed context_staged={}\n",
        .{ session_key, std.json.fmt(content, .{}), staged_context },
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Session
// ═══════════════════════════════════════════════════════════════════════════

pub const Session = struct {
    agent: Agent,
    created_at: i64,
    last_active: i64,
    last_consolidated: u64 = 0,
    session_key: []const u8, // owned copy
    turn_count: u64,
    turn_running: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,
    /// Per-session provider created when the named agent config specifies a
    /// different provider than the SessionManager default (e.g. claude-cli vs
    /// gemini-cli). Null when the session shares the global provider.
    owned_provider: ?*providers_factory.ProviderHolder = null,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        if (self.agent.gemini_session_cwd) |dir| allocator.free(dir);
        self.agent.gemini_session_cwd = null;
        self.agent.deinit();
        allocator.free(self.session_key);
        if (self.owned_provider) |ph| {
            ph.deinit();
            allocator.destroy(ph);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SessionManager
// ═══════════════════════════════════════════════════════════════════════════

pub const SessionManager = struct {
    allocator: Allocator,
    config: *const Config,
    provider: Provider,
    tools: []const Tool,
    mem: ?Memory,
    session_store: ?memory_mod.SessionStore = null,
    response_cache: ?*memory_mod.cache.ResponseCache = null,
    mem_rt: ?*memory_mod.MemoryRuntime = null,
    observer: Observer,
    policy: ?*const SecurityPolicy = null,

    mutex: std.Thread.Mutex,
    usage_log_mutex: std.Thread.Mutex,
    usage_ledger_state_initialized: bool,
    usage_ledger_window_started_at: i64,
    usage_ledger_line_count: u64,
    sessions: std.StringHashMapUnmanaged(*Session),

    pub fn init(
        allocator: Allocator,
        config: *const Config,
        provider: Provider,
        tools: []const Tool,
        mem: ?Memory,
        observer_i: Observer,
        session_store: ?memory_mod.SessionStore,
        response_cache: ?*memory_mod.cache.ResponseCache,
    ) SessionManager {
        tools_mod.bindMemoryTools(tools, mem);

        return .{
            .allocator = allocator,
            .config = config,
            .provider = provider,
            .tools = tools,
            .mem = mem,
            .session_store = session_store,
            .response_cache = response_cache,
            .observer = observer_i,
            .mutex = .{},
            .usage_log_mutex = .{},
            .usage_ledger_state_initialized = false,
            .usage_ledger_window_started_at = 0,
            .usage_ledger_line_count = 0,
            .sessions = .{},
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
    }

    /// Find or create a session for the given key. Thread-safe.
    pub fn getOrCreate(self: *SessionManager, session_key: []const u8) !*Session {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_key)) |session| {
            session.last_active = std.time.timestamp();
            return session;
        }

        // Create new session
        const owned_key = try self.allocator.dupe(u8, session_key);
        errdefer self.allocator.free(owned_key);

        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);

        var agent = try Agent.fromConfig(
            self.allocator,
            self.config,
            self.provider,
            self.tools,
            self.mem,
            self.observer,
        );
        agent.policy = self.policy;
        agent.session_store = self.session_store;
        agent.response_cache = self.response_cache;
        agent.mem_rt = self.mem_rt;
        agent.memory_session_id = owned_key;

        // Set up isolated gemini-cli session directory (hash of session_key).
        // Each NullClaw session gets its own cwd so gemini stores history separately.
        {
            const config_dir = std.fs.path.dirname(self.config.config_path) orelse ".";
            const hash = std.hash.Wyhash.hash(0, session_key);
            const session_dir = std.fmt.allocPrint(self.allocator, "{s}/gemini-sessions/{x:0>16}", .{ config_dir, hash }) catch null;
            if (session_dir) |dir| {
                std.fs.cwd().makePath(dir) catch {
                    self.allocator.free(dir);
                };
                if (agent.gemini_session_cwd == null) {
                    agent.gemini_session_cwd = dir;
                }
            }
        }

        if (self.config.diagnostics.token_usage_ledger_enabled) {
            agent.usage_record_callback = usageRecordForwarder;
            agent.usage_record_ctx = @ptrCast(self);
        }

        // Override model + system_prompt based on agent_id parsed from session_key.
        // Session key format: "agent:{id}:..." — extract the second segment.
        // {id} may be either the agent name ("dev") or a channel account_id ("dev_bot").
        // If a direct name match fails, we fall back to resolving via agent_bindings
        // (account_id → agent_id) so that stable channel IDs can be used in session keys.
        var resolved_provider_name: ?[]const u8 = null;
        if (std.mem.startsWith(u8, session_key, "agent:")) {
            const after_prefix = session_key["agent:".len..];
            const colon_pos = std.mem.indexOfScalar(u8, after_prefix, ':');
            const extracted_id = if (colon_pos) |pos| after_prefix[0..pos] else after_prefix;

            // Step 1: direct name match.
            var resolved = false;
            for (self.config.agents) |named| {
                if (std.mem.eql(u8, named.name, extracted_id)) {
                    resolved = try applyNamedAgentConfig(self.allocator, &agent, named);
                    resolved_provider_name = named.provider;
                    break;
                }
            }

            // Step 2: if no direct match, resolve account_id → agent_id via bindings.
            if (!resolved) {
                for (self.config.agent_bindings) |binding| {
                    const aid = binding.match.account_id orelse continue;
                    if (!std.mem.eql(u8, aid, extracted_id)) continue;
                    for (self.config.agents) |named| {
                        if (std.mem.eql(u8, named.name, binding.agent_id)) {
                            _ = try applyNamedAgentConfig(self.allocator, &agent, named);
                            resolved_provider_name = named.provider;
                            break;
                        }
                    }
                    break;
                }
            }
        }

        // If named config specifies a provider, create a per-session ProviderHolder
        // so the agent uses the correct backend regardless of the SessionManager default.
        var owned_provider: ?*providers_factory.ProviderHolder = null;
        if (resolved_provider_name) |pname| {
            const api_key = providers_api_key.resolveApiKeyFromConfig(
                self.allocator,
                pname,
                self.config.providers,
            ) catch null;
            defer if (api_key) |k| self.allocator.free(k);

            const ph = try self.allocator.create(providers_factory.ProviderHolder);
            ph.* = providers_factory.ProviderHolder.fromConfig(
                self.allocator,
                pname,
                api_key,
                null,
                self.config.getProviderNativeTools(pname),
                null,
            );
            agent.provider = ph.provider();
            owned_provider = ph;
        }
        errdefer if (owned_provider) |ph| {
            ph.deinit();
            self.allocator.destroy(ph);
        };

        session.* = .{
            .agent = agent,
            .created_at = std.time.timestamp(),
            .last_active = std.time.timestamp(),
            .last_consolidated = 0,
            .session_key = owned_key,
            .turn_count = 0,
            .turn_running = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .owned_provider = owned_provider,
        };
        // From here, session owns agent — must deinit on error.
        errdefer session.agent.deinit();

        // Restore persisted conversation history from session store
        if (self.session_store) |store| {
            const entries = store.loadMessages(self.allocator, session_key) catch &.{};
            if (entries.len > 0) {
                session.agent.loadHistory(entries) catch {};
                for (entries) |entry| {
                    self.allocator.free(entry.role);
                    self.allocator.free(entry.content);
                }
                self.allocator.free(entries);
            }
        }

        try self.sessions.put(self.allocator, owned_key, session);
        return session;
    }

    fn slashCommandName(message: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, message, " \t\r\n");
        if (trimmed.len <= 1 or trimmed[0] != '/') return null;

        const body = trimmed[1..];
        var split_idx: usize = 0;
        while (split_idx < body.len) : (split_idx += 1) {
            const ch = body[split_idx];
            if (ch == ':' or ch == ' ' or ch == '\t') break;
        }
        if (split_idx == 0) return null;
        return body[0..split_idx];
    }

    fn slashClearsSession(message: []const u8) bool {
        const cmd = slashCommandName(message) orelse return false;
        return std.ascii.eqlIgnoreCase(cmd, "new") or
            std.ascii.eqlIgnoreCase(cmd, "reset") or
            std.ascii.eqlIgnoreCase(cmd, "restart");
    }

    const StreamAdapterCtx = struct {
        sink: streaming.Sink,
    };

    fn streamChunkForwarder(ctx_ptr: *anyopaque, chunk: providers.StreamChunk) void {
        const adapter: *StreamAdapterCtx = @ptrCast(@alignCast(ctx_ptr));
        streaming.forwardProviderChunk(adapter.sink, chunk);
    }

    fn usageRecordForwarder(ctx_ptr: *anyopaque, record: Agent.UsageRecord) void {
        const self: *SessionManager = @ptrCast(@alignCast(ctx_ptr));
        self.appendUsageRecord(record);
    }

    fn usageLedgerPath(self: *SessionManager) ?[]u8 {
        if (!self.config.diagnostics.token_usage_ledger_enabled) return null;
        const config_dir = std.fs.path.dirname(self.config.config_path) orelse return null;
        return std.fs.path.join(self.allocator, &.{ config_dir, TOKEN_USAGE_LEDGER_FILENAME }) catch null;
    }

    fn usageWindowSeconds(self: *SessionManager) i64 {
        const hours = self.config.diagnostics.token_usage_ledger_window_hours;
        if (hours == 0) return 0;
        return @as(i64, @intCast(hours)) * 60 * 60;
    }

    fn countLedgerLines(file: *std.fs.File) !u64 {
        try file.seekTo(0);
        var lines: u64 = 0;
        var saw_data = false;
        var last_byte: u8 = '\n';
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try file.read(&buf);
            if (n == 0) break;
            saw_data = true;
            last_byte = buf[n - 1];
            lines += @intCast(std.mem.count(u8, buf[0..n], "\n"));
        }
        if (saw_data and last_byte != '\n') lines += 1;
        return lines;
    }

    fn initializeUsageLedgerState(
        self: *SessionManager,
        file: *std.fs.File,
        stat: std.fs.File.Stat,
        now_ts: i64,
    ) void {
        if (self.usage_ledger_state_initialized) return;
        self.usage_ledger_state_initialized = true;
        if (stat.size > 0) {
            const mtime_secs: i64 = @intCast(@divFloor(stat.mtime, NS_PER_SEC));
            self.usage_ledger_window_started_at = if (mtime_secs > 0) mtime_secs else now_ts;
            if (self.config.diagnostics.token_usage_ledger_max_lines > 0) {
                self.usage_ledger_line_count = countLedgerLines(file) catch 0;
            } else {
                self.usage_ledger_line_count = 0;
            }
        } else {
            self.usage_ledger_window_started_at = now_ts;
            self.usage_ledger_line_count = 0;
        }
    }

    fn shouldResetUsageLedger(
        self: *SessionManager,
        stat: std.fs.File.Stat,
        now_ts: i64,
        pending_bytes: usize,
        pending_lines: u64,
    ) bool {
        const window_secs = self.usageWindowSeconds();
        if (window_secs > 0) {
            const started_at = self.usage_ledger_window_started_at;
            if (started_at > 0 and now_ts - started_at >= window_secs) return true;
        }

        const max_bytes = self.config.diagnostics.token_usage_ledger_max_bytes;
        if (max_bytes > 0) {
            const projected = @as(u64, @intCast(stat.size)) + @as(u64, @intCast(pending_bytes));
            if (projected > max_bytes) return true;
        }

        const max_lines = self.config.diagnostics.token_usage_ledger_max_lines;
        if (max_lines > 0 and self.usage_ledger_line_count + pending_lines > max_lines) return true;

        return false;
    }

    fn appendUsageRecord(self: *SessionManager, record: Agent.UsageRecord) void {
        self.usage_log_mutex.lock();
        defer self.usage_log_mutex.unlock();

        const ledger_path = self.usageLedgerPath() orelse return;
        defer self.allocator.free(ledger_path);

        var file = std.fs.openFileAbsolute(ledger_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => std.fs.createFileAbsolute(ledger_path, .{ .truncate = false, .read = true }) catch return,
            else => return,
        };
        var file_needs_close = true;
        defer if (file_needs_close) file.close();

        const now_ts = std.time.timestamp();
        const stat = file.stat() catch return;
        self.initializeUsageLedgerState(&file, stat, now_ts);

        const record_line = std.fmt.allocPrint(
            self.allocator,
            "{{\"ts\":{d},\"provider\":{f},\"model\":{f},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"success\":{}}}\n",
            .{
                record.ts,
                std.json.fmt(record.provider, .{}),
                std.json.fmt(record.model, .{}),
                record.usage.prompt_tokens,
                record.usage.completion_tokens,
                record.usage.total_tokens,
                record.success,
            },
        ) catch return;
        defer self.allocator.free(record_line);

        const pending_bytes: usize = record_line.len;
        if (self.shouldResetUsageLedger(stat, now_ts, pending_bytes, 1)) {
            file.close();
            file_needs_close = false;
            file = std.fs.createFileAbsolute(ledger_path, .{ .truncate = true, .read = true }) catch return;
            file_needs_close = true;
            self.usage_ledger_state_initialized = true;
            self.usage_ledger_window_started_at = now_ts;
            self.usage_ledger_line_count = 0;
        }

        // Zig 0.15 buffered File.writer ignores manual seek position for append-style writes.
        // Use direct file.writeAll after seek to guarantee true append semantics.
        file.seekFromEnd(0) catch return;
        file.writeAll(record_line) catch return;

        if (self.usage_ledger_window_started_at == 0) {
            self.usage_ledger_window_started_at = now_ts;
        }
        if (self.config.diagnostics.token_usage_ledger_max_lines > 0) {
            self.usage_ledger_line_count += 1;
        }
    }

    /// Process a message within a session context.
    /// Finds or creates the session, locks it, runs agent.turn(), returns owned response.
    pub fn processMessage(self: *SessionManager, session_key: []const u8, content: []const u8, conversation_context: ?ConversationContext) ![]const u8 {
        return self.processMessageStreaming(session_key, content, conversation_context, null);
    }

    /// Record a message in history and persistent store WITHOUT calling the LLM.
    /// Used for "listening" mode when an agent is not directly tagged.
    pub fn recordMessage(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
    ) !void {
        const session = try self.getOrCreate(session_key);
        session.mutex.lock();
        defer session.mutex.unlock();

        // 1. Add to in-memory history (for immediate context in next turn)
        try session.agent.recordUserMessage(content);

        // 2. Persist to SQLite
        if (self.session_store) |store| {
            const message_id = if (conversation_context) |ctx| ctx.message_id else null;
            store.saveMessage(session_key, "user", content, message_id) catch {};
        }

        // 3. Auto-save to memory if enabled
        if (session.agent.auto_save) {
            if (session.agent.mem) |mem| {
                const ts: u128 = @bitCast(std.time.nanoTimestamp());
                const save_key = try std.fmt.allocPrint(self.allocator, "autosave_listen_{d}", .{ts});
                defer self.allocator.free(save_key);
                _ = mem.store(save_key, content, .conversation, session.agent.memory_session_id) catch {};
                if (session.agent.mem_rt) |rt| {
                    rt.syncVectorAfterStore(self.allocator, save_key, content);
                }
            }
        }

        session.last_active = std.time.timestamp();
    }

    /// Stage a standalone `mem:`/`:mem` directive into session history without
    /// calling the LLM or auto-saving an assistant reply. Returns true when the
    /// message was recognized as a memory directive, even if no visible entries
    /// were found after filtering internal memory rows.
    pub fn stageMemoryDirectiveSilently(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        _: ?ConversationContext,
    ) bool {
        const directive = parseStandaloneMemDirective(content) orelse return false;
        const session = self.getOrCreate(session_key) catch |err| {
            log.warn("silent mem directive session init failed: {}", .{err});
            return true;
        };

        session.mutex.lock();
        defer session.mutex.unlock();

        var staged_context = false;
        if (session.agent.mem) |mem| {
            const context = buildMemDirectiveContext(self.allocator, mem, session_key, directive);
            defer if (context) |ctx| self.allocator.free(ctx);

            if (context) |ctx| {
                staged_context = true;
                session.agent.history.append(self.allocator, .{
                    .role = .user,
                    .content = self.allocator.dupe(u8, ctx) catch {
                        log.warn("silent mem directive history dupe failed", .{});
                        session.last_active = std.time.timestamp();
                        emitSilentMemDirectiveTrace(session_key, content, false);
                        return true;
                    },
                }) catch |err| {
                    log.warn("silent mem directive history append failed: {}", .{err});
                    session.last_active = std.time.timestamp();
                    emitSilentMemDirectiveTrace(session_key, content, false);
                    return true;
                };
            }
        }

        session.last_active = std.time.timestamp();
        emitSilentMemDirectiveTrace(session_key, content, staged_context);
        return true;
    }

    /// Delete a stored message by its message_id (e.g. Slack ts).
    pub fn deleteSessionMessage(self: *SessionManager, session_key: []const u8, message_id: []const u8) !void {
        if (self.session_store) |store| {
            try store.deleteMessageById(session_key, message_id);
            log.info("deleted message session={s} message_id={s}", .{ session_key, message_id });
        }
    }

    const SlackSessionTarget = struct {
        account_id: []const u8,
        channel_id: []const u8,
        api_token: []const u8,
        token_kind: []const u8,
    };

    fn slackTargetForAccount(
        self: *SessionManager,
        account_id: []const u8,
        channel_id: []const u8,
    ) !SlackSessionTarget {
        for (self.config.channels.slack) |sc| {
            if (!std.mem.eql(u8, sc.account_id, account_id)) continue;
            return .{
                .account_id = sc.account_id,
                .channel_id = channel_id,
                .api_token = sc.user_token orelse sc.bot_token,
                .token_kind = if (sc.user_token != null) "user" else "bot",
            };
        }
        return error.NoSlackConfig;
    }

    fn resolveSlackSessionTarget(self: *SessionManager, session_key: []const u8) !SlackSessionTarget {
        const agent_prefix = "agent:";
        const slack_marker = ":slack:channel:";
        const thread_marker = ":thread:";
        const after_agent = if (std.mem.startsWith(u8, session_key, agent_prefix))
            session_key[agent_prefix.len..]
        else
            session_key;
        const slack_idx = std.mem.indexOf(u8, after_agent, slack_marker) orelse return error.NotSlackSession;
        const extracted_id = after_agent[0..slack_idx];
        const channel_with_thread = after_agent[slack_idx + slack_marker.len ..];
        const channel_id = if (std.mem.indexOf(u8, channel_with_thread, thread_marker)) |thread_idx|
            channel_with_thread[0..thread_idx]
        else
            channel_with_thread;

        var resolved_account_id = extracted_id;
        var resolved_slack_cfg: ?SlackConfig = null;
        for (self.config.channels.slack) |sc| {
            if (std.mem.eql(u8, sc.account_id, extracted_id)) {
                resolved_slack_cfg = sc;
                break;
            }
        }
        if (resolved_slack_cfg == null) {
            for (self.config.agent_bindings) |binding| {
                const channel = binding.match.channel orelse continue;
                const account_id = binding.match.account_id orelse continue;
                if (!std.mem.eql(u8, channel, "slack")) continue;
                if (!std.mem.eql(u8, binding.agent_id, extracted_id)) continue;
                for (self.config.channels.slack) |sc| {
                    if (std.mem.eql(u8, sc.account_id, account_id)) {
                        resolved_account_id = sc.account_id;
                        resolved_slack_cfg = sc;
                        break;
                    }
                }
                if (resolved_slack_cfg != null) break;
            }
        }

        _ = resolved_slack_cfg orelse return error.NoSlackConfig;
        return self.slackTargetForAccount(resolved_account_id, channel_id);
    }

    /// Sync stored messages for the current session.
    /// For Slack sessions: compares against conversations.history and deletes orphaned messages.
    /// For other channels: clears stored messages with no message_id (stale records).
    pub fn syncChannel(self: *SessionManager, session_key: []const u8) ![]const u8 {
        // Try Slack sync first
        if (std.mem.indexOf(u8, session_key, ":slack:channel:")) |_| {
            return self.syncSlackImpl(session_key);
        }

        // Generic sync: remove messages with message_id that are no longer verifiable.
        // For non-Slack channels, just report stored message stats.
        if (self.session_store) |store| {
            const stored_ids = try store.loadMessageIds(self.allocator, session_key);
            defer {
                for (stored_ids) |s| self.allocator.free(s);
                self.allocator.free(stored_ids);
            }
            const stored_msgs = try store.loadMessages(self.allocator, session_key);
            defer memory_mod.freeMessages(self.allocator, stored_msgs);
            return try std.fmt.allocPrint(
                self.allocator,
                "Session has {d} stored messages ({d} with message_id). Slack sync is supported — for other channels, use /new to reset or manually review history.",
                .{ stored_msgs.len, stored_ids.len },
            );
        }
        return try self.allocator.dupe(u8, "No session store configured.");
    }

    fn syncSlackImpl(self: *SessionManager, session_key: []const u8) ![]const u8 {
        const target = try self.resolveSlackSessionTarget(session_key);

        log.info("sync: fetching Slack history for channel={s} account={s}", .{ target.channel_id, target.account_id });

        const url = try std.fmt.allocPrint(self.allocator, "https://slack.com/api/conversations.history?channel={s}&limit=200", .{target.channel_id});
        defer self.allocator.free(url);
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{target.api_token});
        defer self.allocator.free(auth_header);

        const resp_body = try http_util.curlGet(self.allocator, url, &.{auth_header}, "30");
        defer self.allocator.free(resp_body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp_body, .{});
        defer parsed.deinit();

        var live_ts = std.StringHashMap(void).init(self.allocator);
        defer live_ts.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("messages")) |msgs| {
                if (msgs == .array) {
                    for (msgs.array.items) |item| {
                        if (item != .object) continue;
                        if (item.object.get("ts")) |ts| {
                            if (ts == .string) try live_ts.put(ts.string, {});
                        }
                    }
                }
            }
        }

        var deleted: usize = 0;
        if (self.session_store) |store| {
            const stored_ids = try store.loadMessageIds(self.allocator, session_key);
            defer {
                for (stored_ids) |s| self.allocator.free(s);
                self.allocator.free(stored_ids);
            }
            for (stored_ids) |mid| {
                if (!live_ts.contains(mid)) {
                    store.deleteMessageById(session_key, mid) catch {};
                    deleted += 1;
                }
            }
        }

        return try std.fmt.allocPrint(self.allocator, "Sync complete: {d} message(s) removed from history. Slack shows {d} live messages.", .{ deleted, live_ts.count() });
    }

    fn collectSlackDeletionTargets(
        self: *SessionManager,
        target: SlackSessionTarget,
        directive: DeleteDirective,
    ) ![][]u8 {
        var targets: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (targets.items) |ts| self.allocator.free(ts);
            targets.deinit(self.allocator);
        }

        var cursor: ?[]u8 = null;
        defer if (cursor) |c| self.allocator.free(c);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{target.api_token});
        defer self.allocator.free(auth_header);

        while (true) {
            const remaining = switch (directive) {
                .all => 200,
                .last => |count| if (targets.items.len >= count) 0 else @min(count - targets.items.len, 200),
            };
            if (remaining == 0) break;

            const url = if (cursor) |next_cursor|
                try std.fmt.allocPrint(
                    self.allocator,
                    "https://slack.com/api/conversations.history?channel={s}&limit={d}&cursor={s}",
                    .{ target.channel_id, remaining, next_cursor },
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "https://slack.com/api/conversations.history?channel={s}&limit={d}",
                    .{ target.channel_id, remaining },
                );
            defer self.allocator.free(url);

            const resp_body = try http_util.curlGet(self.allocator, url, &.{auth_header}, "30");
            defer self.allocator.free(resp_body);

            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp_body, .{});
            defer parsed.deinit();

            var page_count: usize = 0;
            if (parsed.value == .object) {
                if (parsed.value.object.get("messages")) |msgs| {
                    if (msgs == .array) {
                        for (msgs.array.items) |item| {
                            if (item != .object) continue;
                            if (item.object.get("ts")) |ts| {
                                if (ts == .string) {
                                    try targets.append(self.allocator, try self.allocator.dupe(u8, ts.string));
                                    page_count += 1;
                                }
                            }
                            switch (directive) {
                                .all => {},
                                .last => |count| if (targets.items.len >= count) break,
                            }
                        }
                    }
                }
            }
            if (page_count == 0) break;

            const next_cursor: ?[]const u8 = blk: {
                if (parsed.value != .object) break :blk null;
                if (parsed.value.object.get("response_metadata")) |meta| {
                    if (meta == .object) {
                        if (meta.object.get("next_cursor")) |cursor_val| {
                            if (cursor_val == .string and cursor_val.string.len > 0) {
                                break :blk cursor_val.string;
                            }
                        }
                    }
                }
                break :blk null;
            };
            if (next_cursor == null) break;
            if (cursor) |old_cursor| self.allocator.free(old_cursor);
            cursor = try self.allocator.dupe(u8, next_cursor.?);
        }

        return targets.toOwnedSlice(self.allocator);
    }

    fn deleteSlackMessageByTs(self: *SessionManager, target: SlackSessionTarget, message_ts: []const u8) !bool {
        const url = "https://slack.com/api/chat.delete";
        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{target.api_token});
        defer self.allocator.free(auth_header);
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"channel\":\"{s}\",\"ts\":\"{s}\"}}",
            .{ target.channel_id, message_ts },
        );
        defer self.allocator.free(body);

        const resp_body = try http_util.curlPost(self.allocator, url, body, &.{auth_header});
        defer self.allocator.free(resp_body);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, resp_body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        if (parsed.value.object.get("ok")) |ok_val| {
            if (ok_val == .bool) return ok_val.bool;
        }
        return false;
    }

    pub fn deleteSlackMessages(self: *SessionManager, session_key: []const u8, directive: DeleteDirective) ![]const u8 {
        const target = try self.resolveSlackSessionTarget(session_key);
        return self.deleteSlackMessagesForAccount(target.account_id, target.channel_id, directive);
    }

    pub fn deleteSlackMessagesForAccount(
        self: *SessionManager,
        account_id: []const u8,
        channel_id: []const u8,
        directive: DeleteDirective,
    ) ![]const u8 {
        const target = try self.slackTargetForAccount(account_id, channel_id);
        log.info(
            "delete: fetching Slack history for channel={s} account={s} token_kind={s}",
            .{ target.channel_id, target.account_id, target.token_kind },
        );

        const targets = try self.collectSlackDeletionTargets(target, directive);
        defer {
            for (targets) |ts| self.allocator.free(ts);
            self.allocator.free(targets);
        }

        var deleted: usize = 0;
        var failed: usize = 0;
        for (targets) |message_ts| {
            if (self.deleteSlackMessageByTs(target, message_ts) catch false) {
                deleted += 1;
            } else {
                failed += 1;
            }
        }

        var scope_label: []const u8 = "all";
        var owned_scope_label: ?[]u8 = null;
        defer if (owned_scope_label) |label| self.allocator.free(label);
        switch (directive) {
            .all => {},
            .last => |count| {
                owned_scope_label = std.fmt.allocPrint(self.allocator, "last {d}", .{count}) catch null;
                scope_label = owned_scope_label orelse "last";
            },
        }

        var failed_suffix: []const u8 = "";
        var owned_failed_suffix: ?[]u8 = null;
        defer if (owned_failed_suffix) |suffix| self.allocator.free(suffix);
        if (failed > 0) {
            owned_failed_suffix = std.fmt.allocPrint(
                self.allocator,
                " {d} message(s) could not be deleted.",
                .{failed},
            ) catch null;
            failed_suffix = owned_failed_suffix orelse "";
        }

        return try std.fmt.allocPrint(
            self.allocator,
            "Delete complete: removed {d}/{d} message(s) from Slack channel {s} using account {s} ({s}).{s}",
            .{
                deleted,
                targets.len,
                target.channel_id,
                target.account_id,
                scope_label,
                failed_suffix,
            },
        );
    }

    /// Process a message within a session context and optionally forward text deltas.
    /// Deltas are only emitted when provider streaming is active.
    pub fn processMessageStreaming(
        self: *SessionManager,
        session_key: []const u8,
        content: []const u8,
        conversation_context: ?ConversationContext,
        stream_sink: ?streaming.Sink,
    ) ![]const u8 {
        const channel = if (conversation_context) |ctx| (ctx.channel orelse "unknown") else "unknown";
        const session_hash = std.hash.Wyhash.hash(0, session_key);

        if (self.config.diagnostics.log_message_receipts) {
            log.info("message receipt channel={s} session=0x{x} bytes={d}", .{ channel, session_hash, content.len });
        }
        if (self.config.diagnostics.log_message_payloads) {
            const preview = messageLogPreview(content);
            log.info(
                "message inbound channel={s} session=0x{x} bytes={d} content={f}{s}",
                .{
                    channel,
                    session_hash,
                    content.len,
                    std.json.fmt(preview.slice, .{}),
                    if (preview.truncated) " [log preview truncated]" else "",
                },
            );
        }

        const session = try self.getOrCreate(session_key);

        session.mutex.lock();
        defer session.mutex.unlock();
        session.turn_running.store(true, .release);
        defer {
            session.turn_running.store(false, .release);
            session.agent.clearInterruptRequest();
        }

        // Set conversation context for this turn (Signal-specific for now)
        session.agent.conversation_context = conversation_context;
        defer session.agent.conversation_context = null;

        const prev_stream_callback = session.agent.stream_callback;
        const prev_stream_ctx = session.agent.stream_ctx;
        defer {
            session.agent.stream_callback = prev_stream_callback;
            session.agent.stream_ctx = prev_stream_ctx;
        }

        var stream_adapter: StreamAdapterCtx = undefined;
        if (stream_sink) |sink| {
            stream_adapter = .{ .sink = sink };
            session.agent.stream_callback = streamChunkForwarder;
            session.agent.stream_ctx = @ptrCast(&stream_adapter);
        } else {
            session.agent.stream_callback = null;
            session.agent.stream_ctx = null;
        }

        // `mem: ...` / `:mem ...` — inject entries as context for this turn
        var mem_enriched: ?[]const u8 = null;
        defer if (mem_enriched) |s| self.allocator.free(s);
        if (!detectSync(content)) {
            if (session.agent.mem) |mem| {
                if (detectMemDirective(content)) |directive| {
                    switch (directive) {
                        .all => log.info("mem-all: loading all entries", .{}),
                        .last => |n| log.info("mem-last: loading last {d} entries", .{n}),
                        .query => |query| log.info("mem-search query=\"{s}\"", .{query}),
                    }

                    mem_enriched = buildMemDirectiveEnrichedContent(self.allocator, mem, session_key, content, directive);
                    if (mem_enriched != null) {
                        log.info("mem directive injected filtered context into prompt", .{});
                    } else {
                        log.info("mem directive produced no visible entries after filtering", .{});
                    }
                }
            }
        }
        const effective_content = mem_enriched orelse content;

        // :sync — reconcile stored messages with channel history, return summary directly.
        if (detectSync(content)) {
            log.info("sync: starting for session={s}", .{session_key});
            const sync_summary = self.syncChannel(session_key) catch |err| blk: {
                log.warn("sync: failed err={}", .{err});
                break :blk std.fmt.allocPrint(self.allocator, "Sync failed: {s}", .{@errorName(err)}) catch
                    try self.allocator.dupe(u8, "Sync failed.");
            };
            defer self.allocator.free(sync_summary);
            log.info("sync: done result=\"{s}\"", .{sync_summary});
            if (self.session_store) |store| {
                store.saveMessage(session_key, "user", content, null) catch {};
                store.saveMessage(session_key, "assistant", sync_summary, null) catch {};
            }
            return try self.allocator.dupe(u8, sync_summary);
        }

        const response = try session.agent.turn(effective_content);
        session.turn_count += 1;
        session.last_active = std.time.timestamp();

        // Track consolidation timestamp
        if (session.agent.last_turn_compacted) {
            session.last_consolidated = @intCast(@max(0, std.time.timestamp()));
        }

        // Persist messages via session store
        if (self.session_store) |store| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (slashClearsSession(trimmed)) {
                // Clear persisted messages on session reset
                store.clearMessages(session_key) catch {};
                // Clear stale auto-saved memories
                store.clearAutoSaved(session_key) catch {};
                // Reset gemini-cli session so next call rebuilds context from scratch.
                if (session.agent.gemini_session_cwd) |dir| {
                    const sentinel = std.fmt.allocPrint(self.allocator, "{s}/.initialized", .{dir}) catch null;
                    if (sentinel) |s| {
                        defer self.allocator.free(s);
                        std.fs.deleteFileAbsolute(s) catch {};
                    }
                }
            } else if (!std.mem.startsWith(u8, trimmed, "/")) {
                // Persist user + assistant messages (skip slash commands)
                const message_id = if (conversation_context) |ctx| ctx.message_id else null;
                store.saveMessage(session_key, "user", content, message_id) catch {};
                store.saveMessage(session_key, "assistant", response, null) catch {};
            }
        }

        if (self.config.diagnostics.log_message_payloads) {
            const preview = messageLogPreview(response);
            log.info(
                "message outbound channel={s} session=0x{x} bytes={d} content={f}{s}",
                .{
                    channel,
                    session_hash,
                    response.len,
                    std.json.fmt(preview.slice, .{}),
                    if (preview.truncated) " [log preview truncated]" else "",
                },
            );
        }

        return response;
    }

    pub const InterruptRequestResult = struct {
        requested: bool = false,
        active_tool: ?[]u8 = null,

        pub fn deinit(self: *InterruptRequestResult, allocator: Allocator) void {
            if (self.active_tool) |name| allocator.free(name);
            self.active_tool = null;
        }
    };

    /// Request interruption of a currently running turn for a session.
    /// Returns whether it was signaled and the active tool snapshot (if any).
    pub fn requestTurnInterrupt(self: *SessionManager, session_key: []const u8) InterruptRequestResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.sessions.get(session_key) orelse return .{};
        if (!session.turn_running.load(.acquire)) return .{};
        session.agent.requestInterrupt();
        return .{
            .requested = true,
            .active_tool = session.agent.snapshotActiveToolName(self.allocator) catch null,
        };
    }

    /// Number of active sessions.
    pub fn sessionCount(self: *SessionManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.count();
    }

    pub const ReloadSkillsResult = struct {
        sessions_seen: usize = 0,
        sessions_reloaded: usize = 0,
        failures: usize = 0,
    };

    /// Reload skill-backed system prompts for all active sessions.
    /// Each session is reloaded under its own lock to avoid in-flight turn races.
    pub fn reloadSkillsAll(self: *SessionManager) ReloadSkillsResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = ReloadSkillsResult{};

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            result.sessions_seen += 1;
            session.mutex.lock();
            session.agent.has_system_prompt = false;
            session.mutex.unlock();
            result.sessions_reloaded += 1;
        }

        return result;
    }

    /// Evict sessions idle longer than max_idle_secs. Returns number evicted.
    pub fn evictIdle(self: *SessionManager, max_idle_secs: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        var evicted: usize = 0;

        // Collect keys to remove (can't modify map while iterating)
        var to_remove: std.ArrayListUnmanaged([]const u8) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            const idle_secs: u64 = @intCast(@max(0, now - session.last_active));
            if (idle_secs > max_idle_secs) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                const session = kv.value;
                session.deinit(self.allocator);
                self.allocator.destroy(session);
                evicted += 1;
            }
        }

        return evicted;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

const testing = std.testing;

// ---------------------------------------------------------------------------
// MockProvider — returns a fixed response, no network calls
// ---------------------------------------------------------------------------

const MockProvider = struct {
    response: []const u8,

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
    };

    fn provider(self: *MockProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return self.response;
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock";
    }

    fn mockDeinit(_: *anyopaque) void {}
};

const MockStreamingProvider = struct {
    response: []const u8,

    const vtable = Provider.VTable{
        .chatWithSystem = mockChatWithSystem,
        .chat = mockChat,
        .supportsNativeTools = mockSupportsNativeTools,
        .getName = mockGetName,
        .deinit = mockDeinit,
        .supports_streaming = mockSupportsStreaming,
        .stream_chat = mockStreamChat,
    };

    fn provider(self: *MockStreamingProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn mockChatWithSystem(
        ptr: *anyopaque,
        _: Allocator,
        _: ?[]const u8,
        _: []const u8,
        _: []const u8,
        _: f64,
    ) anyerror![]const u8 {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        return self.response;
    }

    fn mockChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        _: []const u8,
        _: f64,
    ) anyerror!providers.ChatResponse {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        return .{ .content = try allocator.dupe(u8, self.response) };
    }

    fn mockSupportsNativeTools(_: *anyopaque) bool {
        return false;
    }

    fn mockGetName(_: *anyopaque) []const u8 {
        return "mock_stream";
    }

    fn mockDeinit(_: *anyopaque) void {}

    fn mockSupportsStreaming(_: *anyopaque) bool {
        return true;
    }

    fn mockStreamChat(
        ptr: *anyopaque,
        allocator: Allocator,
        _: providers.ChatRequest,
        model: []const u8,
        _: f64,
        callback: providers.StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!providers.StreamChatResult {
        const self: *MockStreamingProvider = @ptrCast(@alignCast(ptr));
        const mid = self.response.len / 2;
        if (mid > 0) callback(callback_ctx, providers.StreamChunk.textDelta(self.response[0..mid]));
        callback(callback_ctx, providers.StreamChunk.textDelta(self.response[mid..]));
        callback(callback_ctx, providers.StreamChunk.finalChunk());
        return .{
            .content = try allocator.dupe(u8, self.response),
            .model = try allocator.dupe(u8, model),
        };
    }
};

const DeltaCollector = struct {
    allocator: Allocator,
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn onEvent(ctx_ptr: *anyopaque, event: streaming.Event) void {
        if (event.stage != .chunk or event.text.len == 0) return;
        const self: *DeltaCollector = @ptrCast(@alignCast(ctx_ptr));
        self.data.appendSlice(self.allocator, event.text) catch {};
    }

    fn deinit(self: *DeltaCollector) void {
        self.data.deinit(self.allocator);
    }
};

/// Create a test SessionManager with mock provider.
fn testSessionManager(allocator: Allocator, mock: *MockProvider, cfg: *const Config) SessionManager {
    return testSessionManagerWithMemory(allocator, mock, cfg, null, null);
}

fn testSessionManagerWithMemory(allocator: Allocator, mock: *MockProvider, cfg: *const Config, mem: ?Memory, session_store: ?memory_mod.SessionStore) SessionManager {
    var noop = observability.NoopObserver{};
    return SessionManager.init(
        allocator,
        cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        session_store,
        null,
    );
}

fn testConfig() Config {
    return .{
        .workspace_dir = "/tmp/yc_test",
        .config_path = "/tmp/yc_test/config.json",
        .default_model = "test/mock-model",
        .allocator = testing.allocator,
    };
}

// ---------------------------------------------------------------------------
// 1. Struct tests
// ---------------------------------------------------------------------------

test "SessionManager init/deinit — no leaks" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    sm.deinit();
}

test "usage ledger appends records when retention limits are disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 101,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 102,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 2, .total_tokens = 4 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":101") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":102") != null);
}

test "usage ledger resets when max line limit is reached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 2;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 1,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 2, .total_tokens = 3 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 2,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 3,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 3, .completion_tokens = 4, .total_tokens = 7 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":3") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":7") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger resets when window expires" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 1;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 10,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 1, .total_tokens = 2 },
        .success = true,
    });

    sm.usage_ledger_state_initialized = true;
    sm.usage_ledger_window_started_at = std.time.timestamp() - 2 * 60 * 60;

    sm.appendUsageRecord(.{
        .ts = 11,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 2, .total_tokens = 4 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":11") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":4") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger resets when byte limit would be exceeded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 140;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 21,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 1, .completion_tokens = 2, .total_tokens = 3 },
        .success = true,
    });
    sm.appendUsageRecord(.{
        .ts = 22,
        .provider = "p2",
        .model = "m2",
        .usage = .{ .prompt_tokens = 2, .completion_tokens = 3, .total_tokens = 5 },
        .success = true,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "\n"));
    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":22") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"total_tokens\":5") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":true") != null);
}

test "usage ledger records failed response flag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base);
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{base});
    defer testing.allocator.free(config_path);
    const ledger_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ base, TOKEN_USAGE_LEDGER_FILENAME });
    defer testing.allocator.free(ledger_path);

    var cfg = testConfig();
    cfg.workspace_dir = base;
    cfg.config_path = config_path;
    cfg.diagnostics.token_usage_ledger_enabled = true;
    cfg.diagnostics.token_usage_ledger_window_hours = 0;
    cfg.diagnostics.token_usage_ledger_max_lines = 0;
    cfg.diagnostics.token_usage_ledger_max_bytes = 0;

    var mock = MockProvider{ .response = "ok" };
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    sm.appendUsageRecord(.{
        .ts = 31,
        .provider = "p1",
        .model = "m1",
        .usage = .{ .prompt_tokens = 0, .completion_tokens = 0, .total_tokens = 0 },
        .success = false,
    });

    const file = try std.fs.openFileAbsolute(ledger_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"ts\":31") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"success\":false") != null);
}

test "getOrCreate creates new session for unknown key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("telegram:chat1");
    try testing.expect(session.turn_count == 0);
    try testing.expectEqualStrings("telegram:chat1", session.session_key);
}

test "getOrCreate returns same session for same key" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("key1");
    const s2 = try sm.getOrCreate("key1");
    try testing.expect(s1 == s2); // pointer equality
}

test "getOrCreate creates separate sessions for different keys" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("telegram:a");
    const s2 = try sm.getOrCreate("discord:b");
    try testing.expect(s1 != s2);
}

test "sessionCount reflects active sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
    _ = try sm.getOrCreate("a");
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
    _ = try sm.getOrCreate("b");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
    _ = try sm.getOrCreate("a"); // existing
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

test "session has correct initial state" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:init");
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(!s.turn_running.load(.acquire));
    try testing.expect(!s.agent.has_system_prompt);
    try testing.expectEqual(@as(usize, 0), s.agent.historyLen());
}

test "requestTurnInterrupt signals only active sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("interrupt:1");
    var none = sm.requestTurnInterrupt("interrupt:1");
    defer none.deinit(testing.allocator);
    try testing.expect(!none.requested);

    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);
    var yes = sm.requestTurnInterrupt("interrupt:1");
    defer yes.deinit(testing.allocator);
    try testing.expect(yes.requested);
    try testing.expect(session.agent.interrupt_requested.load(.acquire));
}

test "requestTurnInterrupt returns active tool snapshot when available" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("interrupt:tool");
    session.turn_running.store(true, .release);
    defer session.turn_running.store(false, .release);

    session.agent.tool_state_mu.lock();
    if (session.agent.active_tool_name) |old| testing.allocator.free(old);
    session.agent.active_tool_name = try testing.allocator.dupe(u8, "shell");
    session.agent.tool_state_mu.unlock();

    var res = sm.requestTurnInterrupt("interrupt:tool");
    defer res.deinit(testing.allocator);
    try testing.expect(res.requested);
    try testing.expect(res.active_tool != null);
    try testing.expectEqualStrings("shell", res.active_tool.?);
}

// ---------------------------------------------------------------------------
// 2. processMessage tests
// ---------------------------------------------------------------------------

test "processMessage returns mock response" {
    var mock = MockProvider{ .response = "Hello from mock" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp = try sm.processMessage("user:1", "hi", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("Hello from mock", resp);
}

test "stageMemoryDirectiveSilently filters internal entries and skips provider turn" {
    var mock = MockProvider{ .response = "should not be used" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    try mem.store("visible_fact", "Visible memory", .core, null);
    try mem.store("autosave_user_1", "hidden autosave", .conversation, null);
    try mem.store("last_hygiene_at", "1772051598", .core, null);

    var sm = testSessionManagerWithMemory(
        testing.allocator,
        &mock,
        &cfg,
        mem,
        sqlite_mem.sessionStore(),
    );
    defer sm.deinit();

    try testing.expect(sm.stageMemoryDirectiveSilently("mem:silent", "mem: all", null));

    const session = try sm.getOrCreate("mem:silent");
    try testing.expectEqual(@as(u64, 0), session.turn_count);
    try testing.expectEqual(@as(usize, 1), session.agent.historyLen());
    try testing.expect(std.mem.indexOf(u8, session.agent.history.items[0].content, "Visible memory") != null);
    try testing.expect(std.mem.indexOf(u8, session.agent.history.items[0].content, "hidden autosave") == null);
    try testing.expect(std.mem.indexOf(u8, session.agent.history.items[0].content, "last_hygiene_at") == null);
}

test "processMessageStreaming forwards provider deltas" {
    var mock = MockStreamingProvider{ .response = "streaming reply" };
    const cfg = testConfig();
    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        null,
        noop.observer(),
        null,
        null,
    );
    defer sm.deinit();

    var collector = DeltaCollector{ .allocator = testing.allocator };
    defer collector.deinit();

    const resp = try sm.processMessageStreaming(
        "stream:1",
        "hi",
        null,
        .{
            .callback = DeltaCollector.onEvent,
            .ctx = @ptrCast(&collector),
        },
    );
    defer testing.allocator.free(resp);

    try testing.expectEqualStrings("streaming reply", resp);
    try testing.expectEqualStrings("streaming reply", collector.data.items);
}

test "processMessage refreshes system prompt when conversation context is cleared" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const sender_uuid = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    const with_context: ?ConversationContext = .{
        .channel = "signal",
        .sender_number = "+15551234567",
        .sender_uuid = sender_uuid,
        .group_id = null,
        .is_group = false,
    };

    const resp1 = try sm.processMessage("ctx:user", "first", with_context);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("ctx:user");
    try testing.expect(session.agent.history.items.len > 0);
    const sys1 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys1, "## Conversation Context") != null);
    try testing.expect(std.mem.indexOf(u8, sys1, sender_uuid) != null);

    const resp2 = try sm.processMessage("ctx:user", "second", null);
    defer testing.allocator.free(resp2);

    try testing.expect(session.agent.history.items.len > 0);
    const sys2 = session.agent.history.items[0].content;
    try testing.expect(std.mem.indexOf(u8, sys2, "## Conversation Context") == null);
    try testing.expect(std.mem.indexOf(u8, sys2, sender_uuid) == null);
}

test "processMessage updates last_active" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("user:2");
    const before = session.last_active;

    // Small sleep so timestamp changes
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const resp = try sm.processMessage("user:2", "hello", null);
    defer testing.allocator.free(resp);

    try testing.expect(session.last_active >= before);
}

test "processMessage increments turn_count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("user:3", "msg1", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("user:3");
    try testing.expectEqual(@as(u64, 1), session.turn_count);

    const resp2 = try sm.processMessage("user:3", "msg2", null);
    defer testing.allocator.free(resp2);
    try testing.expectEqual(@as(u64, 2), session.turn_count);
}

test "processMessage preserves session across calls" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp1 = try sm.processMessage("persist:1", "first", null);
    defer testing.allocator.free(resp1);

    const session = try sm.getOrCreate("persist:1");
    // After first processMessage: system prompt + user msg + assistant response
    try testing.expect(session.agent.historyLen() > 0);

    const history_before = session.agent.historyLen();

    const resp2 = try sm.processMessage("persist:1", "second", null);
    defer testing.allocator.free(resp2);

    // History should have grown (user msg + assistant response added)
    try testing.expect(session.agent.historyLen() > history_before);
}

test "processMessage different keys — independent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const resp_a = try sm.processMessage("user:a", "hello a", null);
    defer testing.allocator.free(resp_a);

    const resp_b = try sm.processMessage("user:b", "hello b", null);
    defer testing.allocator.free(resp_b);

    const sa = try sm.getOrCreate("user:a");
    const sb = try sm.getOrCreate("user:b");
    try testing.expect(sa != sb);
    try testing.expectEqual(@as(u64, 1), sa.turn_count);
    try testing.expectEqual(@as(u64, 1), sb.turn_count);
}

test "processMessage /new clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    // Seed autosave entries for two different sessions.
    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /new with model clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/new gpt-4o-mini", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /reset clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/reset", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage /restart clears autosave only for current session" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var noop = observability.NoopObserver{};
    var sm = SessionManager.init(
        testing.allocator,
        &cfg,
        mock.provider(),
        &.{},
        mem,
        noop.observer(),
        sqlite_mem.sessionStore(),
        null,
    );
    defer sm.deinit();

    try mem.store("autosave_user_a", "session a", .conversation, "sess-a");
    try mem.store("autosave_user_b", "session b", .conversation, "sess-b");
    try testing.expectEqual(@as(usize, 2), try mem.count());

    const response = try sm.processMessage("sess-a", "/restart", null);
    defer testing.allocator.free(response);

    const a_entry = try mem.get(testing.allocator, "autosave_user_a");
    defer if (a_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(a_entry == null);

    const b_entry = try mem.get(testing.allocator, "autosave_user_b");
    defer if (b_entry) |entry| entry.deinit(testing.allocator);
    try testing.expect(b_entry != null);
    try testing.expectEqualStrings("session b", b_entry.?.content);
}

test "processMessage with sqlite memory first turn does not panic" {
    var mock = MockProvider{ .response = "ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const resp = try sm.processMessage("signal:session:1", "hello", null);
    defer testing.allocator.free(resp);
    try testing.expectEqualStrings("ok", resp);

    const entries = try sqlite_mem.loadMessages(testing.allocator, "signal:session:1");
    defer {
        for (entries) |entry| {
            testing.allocator.free(entry.role);
            testing.allocator.free(entry.content);
        }
        testing.allocator.free(entries);
    }
    // One user + one assistant message should be persisted.
    try testing.expect(entries.len >= 2);
}

// ---------------------------------------------------------------------------
// 3. evictIdle tests
// ---------------------------------------------------------------------------

test "evictIdle removes old sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const session = try sm.getOrCreate("old:1");
    // Force last_active to the past
    session.last_active = std.time.timestamp() - 1000;

    const evicted = sm.evictIdle(500);
    try testing.expectEqual(@as(usize, 1), evicted);
    try testing.expectEqual(@as(usize, 0), sm.sessionCount());
}

test "evictIdle preserves recent sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("recent:1");
    // This session was just created, last_active is now

    const evicted = sm.evictIdle(3600); // 1 hour threshold
    try testing.expectEqual(@as(usize, 0), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle returns correct count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    // Create 3 sessions, make 2 old
    const s1 = try sm.getOrCreate("s1");
    const s2 = try sm.getOrCreate("s2");
    _ = try sm.getOrCreate("s3");

    s1.last_active = std.time.timestamp() - 2000;
    s2.last_active = std.time.timestamp() - 2000;
    // s3 stays recent

    const evicted = sm.evictIdle(1000);
    try testing.expectEqual(@as(usize, 2), evicted);
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "evictIdle with no sessions returns 0" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 0), sm.evictIdle(60));
}

// ---------------------------------------------------------------------------
// 4. Thread safety tests
// ---------------------------------------------------------------------------

test "concurrent getOrCreate same key — single Session created" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;

    for (0..num_threads) |t| {
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.COORDINATION_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, out: **Session) void {
                out.* = mgr.getOrCreate("shared:key") catch unreachable;
            }
        }.run, .{ &sm, &sessions[t] });
    }

    for (handles) |h| h.join();

    // All threads should have gotten the same session pointer
    for (1..num_threads) |i| {
        try testing.expect(sessions[0] == sessions[i]);
    }
    try testing.expectEqual(@as(usize, 1), sm.sessionCount());
}

test "concurrent getOrCreate different keys — separate Sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 8;
    var sessions: [num_threads]*Session = undefined;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "key:{d}", .{t}) catch "?";
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.COORDINATION_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, key: []const u8, out: **Session) void {
                out.* = mgr.getOrCreate(key) catch unreachable;
            }
        }.run, .{ &sm, keys[t], &sessions[t] });
    }

    for (handles) |h| h.join();

    // All sessions should be distinct
    for (0..num_threads) |i| {
        for (i + 1..num_threads) |j| {
            try testing.expect(sessions[i] != sessions[j]);
        }
    }
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage different keys — no crash" {
    var mock = MockProvider{ .response = "concurrent ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][16]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "conc:{d}", .{t}) catch "?";
        // Match the runtime worker stack budget used for threaded session
        // turns so this test exercises concurrency rather than a tiny stack.
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator) void {
                for (0..3) |_| {
                    const resp = mgr.processMessage(key, "hello", null) catch return;
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator });
    }

    for (handles) |h| h.join();
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());
}

test "concurrent processMessage with sqlite memory does not panic" {
    var mock = MockProvider{ .response = "concurrent sqlite ok" };
    var cfg = testConfig();
    cfg.memory.auto_save = true;
    cfg.memory.backend = "sqlite";

    var sqlite_mem = try memory_mod.SqliteMemory.init(testing.allocator, ":memory:");
    defer sqlite_mem.deinit();
    const mem = sqlite_mem.memory();

    var sm = testSessionManagerWithMemory(testing.allocator, &mock, &cfg, mem, sqlite_mem.sessionStore());
    defer sm.deinit();

    const num_threads = 4;
    var handles: [num_threads]std.Thread = undefined;
    var key_bufs: [num_threads][24]u8 = undefined;
    var keys: [num_threads][]const u8 = undefined;
    var failed = std.atomic.Value(bool).init(false);

    for (0..num_threads) |t| {
        keys[t] = std.fmt.bufPrint(&key_bufs[t], "sqlite-conc:{d}", .{t}) catch "?";
        // This path still executes a full session turn, so keep it aligned
        // with the runtime stack budget for threaded message processing.
        handles[t] = try std.Thread.spawn(.{ .stack_size = thread_stacks.SESSION_TURN_STACK_SIZE }, struct {
            fn run(mgr: *SessionManager, key: []const u8, alloc: Allocator, failed_flag: *std.atomic.Value(bool)) void {
                for (0..5) |_| {
                    const resp = mgr.processMessage(key, "hello sqlite", null) catch {
                        failed_flag.store(true, .release);
                        return;
                    };
                    alloc.free(resp);
                }
            }
        }.run, .{ &sm, keys[t], testing.allocator, &failed });
    }

    for (handles) |h| h.join();
    try testing.expect(!failed.load(.acquire));
    try testing.expectEqual(@as(usize, num_threads), sm.sessionCount());

    const count = try mem.count();
    try testing.expect(count > 0);
}

// ---------------------------------------------------------------------------
// 5. Session consolidation tests
// ---------------------------------------------------------------------------

test "session last_consolidated defaults to zero" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:consolidation");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
}

test "session initial state includes last_consolidated" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s = try sm.getOrCreate("test:fields");
    try testing.expectEqual(@as(u64, 0), s.last_consolidated);
    try testing.expectEqual(@as(u64, 0), s.turn_count);
    try testing.expect(s.created_at > 0);
    try testing.expect(s.last_active > 0);
}

// ---------------------------------------------------------------------------
// 6. reloadSkillsAll tests
// ---------------------------------------------------------------------------

test "reloadSkillsAll with no sessions returns zero counts" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const result = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 0), result.sessions_seen);
    try testing.expectEqual(@as(usize, 0), result.sessions_reloaded);
    try testing.expectEqual(@as(usize, 0), result.failures);
}

test "reloadSkillsAll invalidates system prompt on all sessions" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    const s1 = try sm.getOrCreate("reload:a");
    const s2 = try sm.getOrCreate("reload:b");
    s1.agent.has_system_prompt = true;
    s2.agent.has_system_prompt = true;

    const result = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 2), result.sessions_seen);
    try testing.expectEqual(@as(usize, 2), result.sessions_reloaded);
    try testing.expect(!s1.agent.has_system_prompt);
    try testing.expect(!s2.agent.has_system_prompt);
}

test "reloadSkillsAll does not affect session count" {
    var mock = MockProvider{ .response = "ok" };
    const cfg = testConfig();
    var sm = testSessionManager(testing.allocator, &mock, &cfg);
    defer sm.deinit();

    _ = try sm.getOrCreate("reload:c");
    _ = try sm.getOrCreate("reload:d");
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());

    _ = sm.reloadSkillsAll();
    try testing.expectEqual(@as(usize, 2), sm.sessionCount());
}

test "parseDeleteCommand parses last and all" {
    const last = parseDeleteCommand(":del 30");
    try testing.expect(last != null);
    try testing.expectEqual(@as(usize, 30), last.?.last);

    const all = parseDeleteCommand(":del all");
    try testing.expect(all != null);
    try testing.expect(all.? == .all);

    try testing.expect(parseDeleteCommand(":del 0") == null);
    try testing.expect(parseDeleteCommand("hello") == null);
}

test "isSystemOnlySlackAccount matches sys slack config" {
    const slack_accounts = [_]SlackConfig{
        .{
            .account_id = "sys",
            .system_only = true,
            .bot_token = "xoxb-sys",
        },
        .{
            .account_id = "dev",
            .bot_token = "xoxb-dev",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = testing.allocator,
        .channels = .{
            .slack = &slack_accounts,
        },
    };

    try testing.expect(isSystemOnlySlackAccount(&cfg, "sys"));
    try testing.expect(!isSystemOnlySlackAccount(&cfg, "dev"));
    try testing.expect(!isSystemOnlySlackAccount(&cfg, null));
}

test "isHelpCommand detects standalone help" {
    try testing.expect(isHelpCommand(":help"));
    try testing.expect(isHelpCommand("  :help \n"));
    try testing.expect(!isHelpCommand("/dev :help"));
    try testing.expect(!isHelpCommand(":help me"));
}

test "shouldHandleSlackHelp only allows system-only slack account" {
    const slack_accounts = [_]SlackConfig{
        .{
            .account_id = "sys",
            .system_only = true,
            .bot_token = "xoxb-sys",
        },
        .{
            .account_id = "dev",
            .bot_token = "xoxb-dev",
        },
    };
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = testing.allocator,
        .channels = .{
            .slack = &slack_accounts,
        },
    };

    try testing.expect(shouldHandleSlackHelp(&cfg, "sys"));
    try testing.expect(!shouldHandleSlackHelp(&cfg, "dev"));
    try testing.expect(!shouldHandleSlackHelp(&cfg, null));

    const no_sys_accounts = [_]SlackConfig{
        .{
            .account_id = "dev",
            .bot_token = "xoxb-dev",
        },
    };
    const no_sys_cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = testing.allocator,
        .channels = .{
            .slack = &no_sys_accounts,
        },
    };

    try testing.expect(!shouldHandleSlackHelp(&no_sys_cfg, "dev"));
}
