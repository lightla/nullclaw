# Gemini CLI Session Management

## Cách hoạt động

Nullclaw set CWD cho gemini CLI process = `$NULLCLAW_HOME/gemini-sessions/<hash>/`.
Gemini CLI tự quản lý session data của nó theo absolute path (internal, không expose ra ngoài).

Nullclaw chỉ dùng sentinel file `.initialized` trong session dir để biết có nên pass `--resume latest` hay không.

## Khi chuyển NULLCLAW_HOME sang path mới

Gemini CLI không nhận ra sessions cũ vì absolute path thay đổi → exit=42, "No previous sessions found for this project".

**Fix:** Xóa sessions cũ để gemini tạo lại từ đầu:

```bash
rm -rf $NULLCLAW_HOME/gemini-sessions/*
```

Không ảnh hưởng gì — gemini sẽ tạo session mới tự động.




### VẤN ĐỀ
CWD = Current Working Directory — thư mục đang làm việc khi process chạy.

Khi nullclaw spawn gemini CLI, nó set CWD của process đó = dist/gemini-sessions/<hash>/. Gemini CLI dùng CWD này như "project identifier" để lưu và tìm lại session.

Bản chất vấn đề:

Gemini CLI lưu session metadata ở đâu đó (likely ~/.gemini/) với key = absolute CWD path. Khi path thay đổi từ .nullclaw/... → dist/..., key không match → không tìm được session cũ.

Cách không cần xóa: Giữ nguyên path cũ — tức là không đổi tên folder gemini-sessions và NULLCLAW_HOME phải trỏ đúng path ban đầu. Vì nullclaw tính CWD = $NULLCLAW_HOME/gemini-sessions/<hash>, nên chỉ cần NULLCLAW_HOME không thay đổi là sessions vẫn valid.

Trong trường hợp của mày: từ .nullclaw/ → dist/ là thay đổi path nên sessions cũ mất. Lần này đã xóa rồi, session mới sẽ gắn với dist/ — từ giờ chỉ cần không đổi NULLCLAW_HOME nữa là ổn.


### GMP

Gemini CLI: Dùng CWD làm project identifier. 
Nullclaw set CWD = dist/gemini-sessions/<hash>/ → gemini "sống" trong đó, không biết mebs project.

Claude CLI: Không dùng CWD để identify project, dùng session ID. 
Nhưng nullclaw cũng set CWD = dist/gemini-sessions/<hash>/ luôn → claude cũng bị kẹt trong đó.

Ví dụ thực tế khi mày hỏi cdev "project này dùng framework gì?":

claude chạy ls → thấy dist/gemini-sessions/034a.../ → không có framework nào → trả lời sai
Fix cho claude (khả thi): Set CWD của claude = workspace (mebs project) thay vì session dir. Claude không cần CWD để manage session nên không ảnh hưởng gì.

Gemini thì không fix được vì nó cần CWD đúng để resume session.

Mày muốn fix claude trước không?


----------------
Gemini "sống" trong session dir chỉ là mình nói sai. Thực tế:

Gemini spawn với CWD = dist/gemini-sessions/<hash>/
Nhưng system prompt có Working directory: /home/sangvu/workspace/mebs/...
Gemini đọc system prompt → tự cd sang mebs → hoạt động đúng ✓