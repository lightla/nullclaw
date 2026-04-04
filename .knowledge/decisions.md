# Decisions — Các Quyết Định Kiến Trúc

---

## [2026-03-17] Routing Architecture: Mỗi bot một socket riêng

### Quyết định
Mỗi Slack bot account (dev_bot, mentor_bot, ...) mở một WebSocket connection độc lập.
Không có actor trung tâm điều phối (dispatcher).

### Bối cảnh
Hệ thống cần hỗ trợ nhiều AI actor chạy song song trên cùng một Slack workspace:
- Mỗi actor có trí nhớ độc lập (SQLite riêng)
- Tất cả actors đều lắng nghe passive (save memory) nhưng chỉ phản hồi khi được nhắc tên (`/dev`, `/mentor`, ...)
- Actors phải độc lập tuyệt đối — một con chết không ảnh hưởng con kia

Có hai lựa chọn được cân nhắc:
1. **Central dispatcher**: 1 socket lắng nghe tất cả, forward message tới từng actor
2. **Per-actor socket**: mỗi bot account mở socket riêng, tự xử lý

### Lựa chọn: Per-actor socket (option 2)

### Lý do

**1. Slack Socket Mode bắt buộc theo hướng này**
Mỗi Slack App có `app_token` riêng → mỗi `app_token` = 1 WebSocket connection.
Không có cơ chế native nào để 1 socket nhận event của nhiều app token khác nhau.
Central dispatcher sẽ phải workaround, tăng độ phức tạp không cần thiết.

**2. Kiến trúc hiện tại đã đi theo hướng này**
`config.json` đã có `slack.accounts` với `dev_bot` và `mentor_bot` mỗi cái có `bot_token` + `app_token` riêng.
Chỉ cần fix routing bug, không cần refactor lớn.

**3. Isolation tự nhiên — không cần enforce thêm**
- Memory isolation: mỗi socket chỉ nhận event của bot mình → SQLite riêng, không cần copy hay sync
- Fault isolation: dev_bot chết không ảnh hưởng mentor_bot
- Central dispatcher tạo ra single point of failure — nếu dispatcher chết, toàn bộ hệ thống im lặng

**4. Passive listening hoạt động đúng concept "con người thực"**
Cả 2 bots đều join cùng channel → cả 2 WebSocket đều nhận cùng 1 message từ Slack.
Mỗi actor tự quyết định: có bị nhắc tên không → respond hay chỉ save memory.
Không cần thêm logic forward nội bộ.

**5. Scale dễ hơn**
Thêm actor mới = thêm 1 entry vào `config.json`.
Central dispatcher phải được cập nhật mỗi khi thêm actor mới → coupling cao.

### Tradeoff phải chấp nhận

| Tradeoff | Mức độ | Ghi chú |l
|---|---|---|
| Nhiều WebSocket connection hơn | Thấp | Slack cho phép nhiều connection, cost không đáng kể |
| Mỗi message Slack được xử lý N lần (N = số actors) | Thấp | Chỉ là save memory, không gọi LLM, rất nhẹ |
| Phải quản lý N process/thread thay vì 1 | Trung bình | Đã có threading infrastructure trong NullClaw |
| Nếu cần broadcast từ actor này sang actor kia | Cao | Phải dùng in-process message bus, không qua Slack |

### Kết quả kỳ vọng
- Mỗi actor chạy trong thread riêng, độc lập hoàn toàn
- Passive observe: tất cả actors save memory khi có message mới trong channel
- Active respond: chỉ actor được nhắc tên mới gọi LLM và trả lời
- Fix routing bug là việc cần làm trước tiên để kiến trúc này hoạt động đúng
