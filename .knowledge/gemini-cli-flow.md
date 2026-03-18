# Gemini CLI — Session Flow & Memory Model

## Tổng quan

`gemini-cli` provider spawn binary `gemini` làm subprocess mỗi lần call. Binary này có
session history riêng lưu trên disk — **hoàn toàn độc lập với NullClaw**.

---

## Session directory

```
.nullclaw/gemini-sessions/<hash_of_session_key>/
  .initialized    ← sentinel file (rỗng, chỉ check tồn tại)
```

- Path được tính từ `Wyhash.hash(0, session_key)` → **deterministic**, cùng session_key
  luôn ra cùng path
- Tạo lúc `SessionManager.getOrCreate()` chạy lần đầu cho session đó
- Tồn tại trên disk cho đến khi bị xóa tay hoặc `/reset`

---

## First call vs Resume

### First call (`sentinel không tồn tại`)

```
constructFullAwarePrompt(all agent.history)
  ↓
spawn: gemini -m <model> --output-format stream-json --yolo
  cwd = .nullclaw/gemini-sessions/<hash>/
  stdin ← full prompt (system instruction + lịch sử + câu hỏi cuối)
  ↓
gemini tạo session mới trong cwd
  ↓
markInitialized() → tạo file .initialized (rỗng)
```

### Resume (`sentinel tồn tại`)

```
extractLastUserMessage()   ← chỉ lấy 1 tin nhắn cuối
  ↓
spawn: gemini --resume latest -m <model> --output-format stream-json --yolo
  cwd = .nullclaw/gemini-sessions/<hash>/   ← cùng dir cũ
  stdin ← chỉ message mới
  ↓
gemini load session cũ từ disk → tiếp tục, không mất context
```

---

## Persistence qua các sự kiện

| Sự kiện | agent.history (NullClaw) | Gemini CLI session |
|---|---|---|
| Restart NullClaw | **Giữ** (restore từ SQLite) | **Giữ** (disk + resume) |
| `/reset` | Reset | **Reset** (sentinel bị xóa) |
| Xóa `.nullclaw/gemini-sessions/` | Không đổi | **Reset** |
| Đổi channel/user | Session key mới → hash mới | Session dir mới |

---

## Gemini CLI lưu history ở đâu?

Binary `gemini` lưu session data vào thư mục riêng của nó (ngoài project NullClaw):

```
~/.gemini/sessions/
  hoặc
~/.config/gemini/sessions/
```

NullClaw chỉ set `child.cwd = session_dir` khi spawn. Binary `gemini` dùng cwd đó để
tìm/lưu session. NullClaw không đọc, không ghi, không biết format bên trong — black box.

---

## Sentinel file `.initialized`

File **rỗng** có chủ đích. Pattern Unix lockfile/done-marker:

```zig
// Tạo: chỉ tạo file, không ghi gì
const f = std.fs.createFileAbsolute(sentinel, .{}) catch return;
f.close();

// Check: chỉ hỏi OS "file có tồn tại không?"
std.fs.accessAbsolute(sentinel, .{}) catch return false;
```

Không cần nội dung → không tốn I/O ghi/đọc data thừa.

---

## Capacity error & fallback model

Khi gemini trả 429 / `RESOURCE_EXHAUSTED`:
- Binary gemini ghi lỗi vào stderr, exit non-zero
- NullClaw capture stderr trong thread riêng (tránh pipe deadlock)
- Detect pattern: `RESOURCE_EXHAUSTED`, `MODEL_CAPACITY_EXHAUSTED`, `rateLimitExceeded`
- Nếu có `fallback_model` trong config → retry với model đó
- Stream notify user: `_(Model X quá tải, đang thử lại với Y...)_`
- `markInitialized` chỉ gọi khi call thành công (không tạo sentinel khi fail)

Config fallback:
```json
"fallbackModel": "gemini-2.0-flash"
```

---

## SQLite và gemini-cli (hiện tại)

SQLite **không được feed vào gemini-cli**. Chỉ dùng để:
- Ghi log conversation (`recordMessage`)
- Restore `agent.history` khi NullClaw restart (`loadMessages`)

`constructFullAwarePrompt` skip `role == .system` → memory_loader injection không có tác dụng.

### Khi nào cần feed SQLite vào gemini-cli?

1. **On first call sau restart** → auto inject N messages gần nhất từ SQLite vào prompt
   (cold start context, tránh gemini không biết gì ngoài message mới nhất)
2. **Keyword trigger** (`:mem <query>`) → semantic search SQLite → inject vào prompt
3. **Context overflow** → khi gemini session quá lớn, reset + inject summary từ SQLite

Chưa implement. Cần thêm section `[BỘ NHỚ DÀI HẠN]` vào `constructFullAwarePrompt`.
