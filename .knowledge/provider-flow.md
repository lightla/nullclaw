# Provider Flow

## Tổng quan

NullClaw có nhiều provider. Hai provider hay bị nhầm lẫn nhất: `gemini` và `gemini-cli`.

---

## `gemini` provider (`src/providers/gemini.zig`)

Gọi **Gemini HTTP API trực tiếp**.

### Auth — load 1 lần lúc khởi động:
```
1. config api_key (explicit)
2. GEMINI_API_KEY env var
3. GOOGLE_API_KEY env var
4. GEMINI_OAUTH_TOKEN env var
5. ~/.gemini/oauth_creds.json  ← fallback cuối
   - nếu token hết hạn → tự refresh
   - nếu refresh fail → auth = null → CredentialsNotSet
```

**Điểm yếu**: auth chỉ load **một lần lúc boot**. Nếu token hết hạn sau khi chạy, hoặc refresh thất bại → mọi request đều bị `CredentialsNotSet`.

### Config:
```json
"primary": "gemini/gemini-3-flash-preview"
```

---

## `gemini-cli` provider (`src/providers/gemini_cli.zig`)

> ⚠️ **QUAN TRỌNG — hay bị hiểu nhầm**: `gemini-cli` **KHÔNG phải wrapper của `gemini` provider**, **KHÔNG gọi lại `gemini.zig`** theo bất kỳ cách nào. Đây là 2 provider hoàn toàn độc lập trong codebase. `gemini-cli` chỉ spawn binary `gemini` cài trên máy — binary đó tự gọi Gemini API theo cách riêng của nó, NullClaw không can thiệp vào.

Spawn binary `gemini` trên máy làm subprocess. Không gọi HTTP trực tiếp.

### Flow mỗi request:
```
NullClaw → spawn process: gemini -m <model> --output-format stream-json --yolo
           pipe prompt vào stdin
           đọc stream-json từ stdout
           → parse response → trả về
```

Binary `gemini` tự lo auth nội bộ (có daemon refresh token riêng). NullClaw không quan tâm.

### Auth: không cần cấu hình gì — binary `gemini` tự xử lý.

### Config:
```json
"primary": "gemini-cli/gemini-3-flash-preview"
```

---

## So sánh nhanh

| | `gemini` | `gemini-cli` |
|---|---|---|
| Gọi API | HTTP trực tiếp | Qua binary `gemini` |
| Auth | Load 1 lần lúc boot, có thể expire | Binary tự xử lý mỗi lần |
| Token expire | Có thể bị `CredentialsNotSet` | Không bao giờ |
| Tốc độ | Nhanh | Chậm hơn (overhead spawn process) |
| Native tools | Không | Có (binary gemini có tools riêng) |

---

## Lý do dùng `gemini-cli` thay `gemini` cho actor dev/mentor

Config `./config/config.json` (nhánh `claude`) dùng `gemini/...` → bị `CredentialsNotSet` vì token OAuth trong `~/.gemini/oauth_creds.json` đã hết hạn và refresh thất bại.

Config `~/.nullclaw/config.json` (nhánh `main`) dùng `gemini-cli/...` → binary tự refresh → không bao giờ bị lỗi này.

**Fix**: đổi default primary sang `gemini-cli/gemini-3-flash-preview` trong `./config/config.json`.

---

## applyNamedAgentConfig KHÔNG đổi provider

Khi `session.getOrCreate()` resolve agent từ session key, nó gọi `applyNamedAgentConfig()` — hàm này chỉ set `model_name` và `system_prompt`, **không đổi provider**.

Provider luôn lấy từ **global default** (`SessionManager.provider`) được khởi tạo từ `agents.defaults.model.primary`.

Tức là dù agent config có `"provider": "gemini-cli"`, nếu default là `gemini` thì vẫn dùng `gemini` để call API.
