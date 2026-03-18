# NullClaw — App Flow & Provider Architecture

> See also: `gemini-cli-flow.md` (session lifecycle, memory model, fallback)
> See also: `provider-flow.md` (gemini vs gemini-cli, current flow diagram)

## 0. AI Design Flow Behavior (Actor Model)

### Concept

NullClaw được thiết kế theo mô hình **Actor**: mỗi agent là một thực thể độc lập với trí nhớ riêng, cá tính riêng, model riêng. Nhiều agent có thể tồn tại song song trong cùng một workspace Slack, hoạt động hoàn toàn độc lập.

### Ví dụ thực tế: `/dev` và `/mentor` trên Slack

```
User gửi: "/dev tại sao code này bị lỗi?"
User gửi: "/mentor giải thích cho tôi về async/await"
           ↓
NullClaw khởi tạo 2 agent instance song song, KHÔNG chờ nhau
  - Agent "dev"    → session key: agent:dev:slack:direct:user123
  - Agent "mentor" → session key: agent:mentor:slack:direct:user123
```

Hai agent này:
- Có **lịch sử hội thoại hoàn toàn riêng biệt**
- Có **system prompt riêng** (dev: kỹ thuật, mentor: giảng dạy)
- Có thể dùng **model khác nhau** (dev: gpt-4, mentor: claude)
- Có thể dùng **provider khác nhau** (openai, anthropic, gemini...)
- **Chạy song song** — không block nhau

### Flow từ Slack message đến Agent response

```
1. Slack gửi event → SlackChannel nhận
       ↓
2. SlackChannel.handleSlackMessage() phát hiện mention/alias:
   - "<@BOTID>" (direct mention)
   - "/dev", "@dev" (alias match từ account_id config)
   - Mỗi Slack bot account → 1 agent riêng
       ↓
3. dispatchToAgent(): gắn tag agent vào message
   raw_text = "tại sao code này lỗi?"
   tagged   = "dev: tại sao code này lỗi?"  ← routing hint
       ↓
4. Bus.publishInbound(message)
       ↓
5. agent_routing.resolveRoute(): 7-tier binding lookup
   agent_bindings config → tìm agent_id phù hợp → "dev"
       ↓
6. buildSessionKeyWithScope():
   → "agent:dev:slack:direct:user123"   (dev nói chuyện với user123)
   → "agent:mentor:slack:direct:user123" (mentor nói chuyện riêng)
       ↓
7. SessionManager.getOrCreate(session_key):
   - Lần đầu: tạo Agent instance mới
     * Đọc NamedAgentConfig tên "dev" từ config
     * Override model_name, system_prompt
     * Tạo history array rỗng
     * Load persisted history từ session store (nếu có)
   - Lần tiếp theo: trả về instance cũ (có sẵn history)
       ↓
8. session.agent.turn(content) → provider.chat/streamChat()
       ↓
9. Response trả về Slack
```

### Isolation Properties

| Property | agent:dev:slack:direct:user123 | agent:mentor:slack:direct:user123 |
|---|---|---|
| Agent instance | Riêng | Riêng |
| Conversation history | Độc lập | Độc lập |
| System prompt | "Expert developer..." | "Patient teacher..." |
| Model | gpt-4-turbo | claude-opus |
| Provider | openai | anthropic |
| Memory session ID | agent:dev:... | agent:mentor:... |

### Concurrency Model

```
SessionManager
  ├─ mutex: short-hold (chỉ khi lookup/tạo session)
  └─ sessions map:
       "agent:dev:slack:direct:user123"    → Session A { mutex: long-hold }
       "agent:mentor:slack:direct:user123" → Session B { mutex: long-hold }
       "agent:dev:slack:direct:user456"    → Session C { mutex: long-hold }
```

- **Khác agent**: chạy **song song** (A + B cùng lúc ✓)
- **Cùng agent, khác user**: chạy **song song** (A + C cùng lúc ✓)
- **Cùng agent, cùng user**: **tuần tự** (tránh race condition trên history)

### Config mẫu để tạo 2 actor dev + mentor

```json
{
  "agents": [
    {
      "name": "dev",
      "provider": "gemini-cli",
      "model": "gemini-2.5-pro",
      "system_prompt": "Mày là dev senior, trả lời kỹ thuật, ngắn gọn."
    },
    {
      "name": "mentor",
      "provider": "gemini-cli",
      "model": "gemini-2.5-pro",
      "system_prompt": "Mày là mentor, giải thích từ từ, dùng ví dụ."
    }
  ],
  "agent_bindings": [
    { "agent_id": "dev",    "match": { "channel": "slack", "account_id": "dev_bot" } },
    { "agent_id": "mentor", "match": { "channel": "slack", "account_id": "mentor_bot" } }
  ],
  "channels": {
    "slack": [
      { "account_id": "dev_bot",    "bot_token": "xoxb-dev-...",    "app_token": "xapp-..." },
      { "account_id": "mentor_bot", "bot_token": "xoxb-mentor-...", "app_token": "xapp-..." }
    ]
  }
}
```

### Kết nối với gemini-cli

Khi provider là `gemini-cli`:
- `session.agent.turn()` gọi `GeminiCliProvider.chatImpl()`
- `constructFullAwarePrompt()` build prompt có lịch sử hội thoại từ `request.messages`
- Spawn subprocess `gemini --yolo` → binary gemini chạy agentic loop riêng
- NullClaw đọc output → trả về Slack

Mỗi lần gọi spawn 1 process riêng biệt. Không có "session dài hạn" bên trong binary gemini — NullClaw là người giữ lịch sử, còn gemini CLI chỉ nhận full context mỗi lần.

### TODO: claude-auth / claude-cli

Tương tự gemini-cli, cần:
- `ClaudeAuthProvider` với `constructFullAwarePrompt` giống hệt
- Spawn `claude -p --output-format stream-json --model M --verbose`
- Parse `assistant` events (thay vì `message` events của gemini)
- Lấy usage từ `result` event

Điều này cho phép dùng `claude-cli` làm provider cho actor dev/mentor, song song với gemini-cli, với lịch sử hội thoại do NullClaw quản lý.

---

## 1. Agent Loop (High Level)

Entry point: `src/agent/root.zig` → `Agent.turn(user_message)`

```
Agent.turn(user_message)
  1. memory_loader: inject memory context vào message history
  2. prompt.zig: build system prompt
  3. LOOP (max_tool_iterations = 1000, max_history_messages = 100):
     a. provider.streamChat() hoặc provider.chat()
     b. dispatcher: parse tool calls từ response
     c. Thực thi tools → collect results
     d. Append tool results vào message history
     e. Có tool calls? → tiếp tục loop
     f. Không? → return final text response
```

Provider được inject vào Agent struct, gọi qua vtable (`Provider` interface). Agent không biết provider cụ thể là gì.

---

## 2. Provider Selection & Init từ Config

File: `src/providers/factory.zig`

```
ProviderHolder.fromConfig(provider_name, api_key, base_url, native_tools, user_agent)
  │
  ├─ classifyProvider(provider_name)
  │    ├─ core_providers map: anthropic, openai, gemini, gemini-cli, claude-cli, claude-auth, ...
  │    ├─ compat_providers table: 90+ OpenAI-compatible (groq, mistral, deepseek...)
  │    ├─ "custom:<url>" → .compatible_provider
  │    ├─ "anthropic-custom:<url>" → .anthropic_provider
  │    └─ unknown → fallback openrouter
  │
  └─ switch(ProviderKind) → khởi tạo concrete provider
       ├─ .anthropic_provider → AnthropicProvider.init(allocator, api_key, base_url)
       ├─ .gemini_provider    → GeminiProvider.init(allocator, api_key)
       ├─ .gemini_cli_provider → GeminiCliProvider.init(allocator, null)
       ├─ .claude_cli_provider → ClaudeCliProvider.init(allocator, null)  [fallback openrouter nếu lỗi]
       ├─ .claude_auth_provider → ClaudeAuthProvider.init(allocator, null) [fallback openrouter nếu lỗi]
       └─ .compatible_provider → OpenAiCompatibleProvider.init + apply flags từ bảng
```

Kết quả: `ProviderHolder` (tagged union) chứa concrete provider, expose qua `Provider` vtable interface.

**API key resolution** (`src/providers/api_key.zig`) — chạy TRƯỚC khi init provider:
```
1. config api_key (explicit)
2. Provider-specific env var (ANTHROPIC_API_KEY, GEMINI_API_KEY...)
3. Generic fallback: NULLCLAW_API_KEY, API_KEY
```

---

## 3. Gemini Provider Flow (`src/providers/gemini.zig`)

### Auth selection trong `GeminiProvider.init()` — 5 bậc fallback:

```
1. config api_key (explicit)           → GeminiAuth.explicit_key
2. GEMINI_API_KEY env var              → GeminiAuth.env_gemini_key
3. GOOGLE_API_KEY env var              → GeminiAuth.env_google_key
4. GEMINI_OAUTH_TOKEN env var          → GeminiAuth.env_oauth_token
5. đọc ~/.gemini/oauth_creds.json      → GeminiAuth.oauth_token  ← THÊM VÀO SAU
   (file do `gemini auth login` tạo ra)
   - parse JSON: { access_token, refresh_token, expires_at/expiry_date }
   - nếu token hết hạn → tự refresh qua Google OAuth endpoint
   - ghi token mới lại vào file
```

`GeminiAuth.isApiKey()`:
- `true` → explicit_key, env_gemini_key, env_google_key → gửi qua query param `?key=<value>`
- `false` → env_oauth_token, oauth_token → gửi qua header `Authorization: Bearer <token>`

### Chat flow:
```
chatImpl / streamChatImpl
  → buildUrl(model, auth)         // nếu OAuth: không append ?key=
  → buildChatRequestBody(...)
  → if isApiKey:  curlPostTimed(url, body, headers=[])
    if OAuth:     curlPostTimed(url, body, headers=["Authorization: Bearer <token>"])
  → parseResponse / parseChatResponse
```

### Credential file structs:
```zig
GeminiCliCredentials {
    access_token: []const u8,
    refresh_token: ?[]const u8,
    expires_at: ?i64,          // unix timestamp (seconds)
                               // hoặc expiry_date (milliseconds → convert /1000)
}
```

File path: `~/.gemini/oauth_creds.json`

---

## 4. Gemini CLI Provider Flow (`src/providers/gemini_cli.zig`)

**Khác hoàn toàn với `gemini.zig`**: không gọi HTTP, spawn binary `gemini` làm subprocess.

### Mục đích:
- Binary `gemini` là một **agentic loop hoàn chỉnh** (có tools: file, bash, Google Search...)
- Flag `--yolo` = tự động approve tất cả tool calls
- NullClaw chỉ đóng vai trò: gửi prompt → đọc kết quả cuối

### Model + agent_name routing:
```
model = "gemini-3-flash--myagent"
         ↑ dấu "--" tách model và agent_name
m_pure = "gemini-3-flash"
agent_name = "myagent"

Nếu agent_name == "monitor" → trả về response rỗng ngay (skip call)
```

### Prompt construction (`constructFullAwarePrompt`):
```
CHỈ THỊ HỆ THỐNG: Mày là <agent_name> trên Slack. Hãy trả lời câu hỏi
cuối cùng của người dùng. Tuyệt đối không lặp lại lịch sử...

[LỊCH SỬ HỘI THOẠI]
- Người dùng: <msg>
- Bạn: <msg>
...

[CÂU HỎI CUỐI CÙNG]: <last user message>

TRẢ LỜI NGAY:
```
(system messages bị skip, không đưa vào history)

### Subprocess invocation:
```
argv = ["gemini", "-m", <model>, "--output-format", "stream-json", "--yolo"]
stdin = prompt text (pipe)
stdout = stream-json lines (pipe)
stderr = Ignore
```

### Parse stdout (stream-json line-by-line):
```
Mỗi dòng là 1 JSON object:
  type="message", role="assistant"  → lấy content → full_content + stream_cb
  type="result"                     → lấy stats.total_tokens → usage
  (các type khác bỏ qua)

Filter: bỏ qua content chứa "Reflect on" (internal gemini reasoning)
```

### Auth: không cần — binary `gemini` tự xử lý auth nội bộ từ credentials của nó.

---

## 5. Anthropic Provider Flow (`src/providers/anthropic.zig`)

### Auth — CHỈ nhận từ ngoài truyền vào, KHÔNG tự đọc gì:
```
AnthropicProvider.init(api_key, base_url)
  credential = api_key (trimmed) hoặc null
  → không fallback env var, không đọc file
```

Env var resolution (`ANTHROPIC_OAUTH_TOKEN` → `ANTHROPIC_API_KEY`) được xử lý ở `api_key.zig` **trước** khi gọi init.

### Token type detection:
```zig
isSetupToken(token) → token.startsWith("sk-ant-oat01-")
  → true:  OAuth/setup token → Bearer auth + ?beta=true URL + extra beta headers
  → false: API key → x-api-key header, URL bình thường
```

### Chat flow:
```
chatImpl / streamChatImpl
  credential orelse return error.CredentialsNotSet
  is_oauth = isSetupToken(credential)

  url = if is_oauth: base_url/v1/messages?beta=true
        else:        base_url/v1/messages

  auth_hdr = if is_oauth: "authorization: Bearer <token>"
             else:        "x-api-key: <key>"

  if is_oauth: curlPostOAuth(...)    // thêm user-agent và anthropic-beta headers
  else:        curlPostTimed(...)

  → parseNativeResponse / SSE stream parse
```

---

## 6. So sánh tổng quan

| | `gemini` | `gemini-cli` | `anthropic` |
|---|---|---|---|
| **Gọi API** | HTTP trực tiếp | Spawn subprocess | HTTP trực tiếp |
| **Auth sources** | 5 bậc: config → 3 env → file | Không (binary tự xử lý) | 1: credential từ ngoài truyền vào |
| **OAuth fallback** | Có (đọc `~/.gemini/oauth_creds.json`) | Không cần | Không có — TODO |
| **Streaming** | SSE | Line-delimited JSON từ stdout | SSE |
| **Tools** | Không | Có (binary gemini tự dùng tools) | Không |
| **Agent loop** | Không | Binary gemini tự chạy loop | Không |
| **Token refresh** | Tự động | N/A | Không |

---

## 7. claude-auth Provider (mới thêm)

File: `src/providers/claude_auth.zig`

**Hiện tại**: theo pattern `gemini_cli.zig` — spawn `claude` binary với stdin pipe, parse stream-json output.

**TODO**: nên làm theo pattern `gemini.zig` — đọc credentials file mà `claude auth login` lưu (path chưa xác định, cần kiểm tra `~/.claude/`), rồi truyền token vào `AnthropicProvider` có sẵn (vì AnthropicProvider đã support OAuth token `sk-ant-oat01-` với Bearer auth).

Anthropic cũng sẽ cần thêm fallback tương tự gemini: `ANTHROPIC_OAUTH_TOKEN` env var (đã có trong api_key.zig) + đọc credentials file (chưa có).
