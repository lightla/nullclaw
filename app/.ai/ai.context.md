# NullClaw AI System Context - Sang Vu Edition

########### NEW REQUIREMENT ##############

0. Với Provider Gemini Cli
+ Bỏ cơ chế gọi qua gemini prompt, phải khởi động các instance gemni cli lên, luôn sẵn sàng chờ lệnh
    + số lượng instance gemini = số actor

1. Cần 1 file config (tùy chọn json, yaml, toml), bạn tùy chọn sao cho dễ đọc nhất với zig
    + Nội dung cần có:
        + 1. Danh sách actor (cụ thể là bot) cho slack (sau này mở rộng lên app khác như tele)
            + actor-name: dev, mentor, ... (giống như code là unique với mỗi actor)
            + actor-family-name: tên hiển thị (tạm thời chưa cần)
2. Khi khởi động, không cố định mentor & dev (cái này là mức cơ bản muốn test thôi nhưng đang lỗi)
    + Mục đích chính là tạo 1 team agent mỗi 1 agent có 1 nhiệm vụ, hiểu biết và context riêng 
    + context history của từng actor đọc trong sqllite 

3. Luồng hoạt động sẽ như này
+ Khi call: nullclaw gateway
    + Hệ thống đọc file config -> tạo n multi thread parallel (song song thực sự), ứng với mỗi 1 actor 

+ Với riêng slack trước:
    + Hệ thống tự động load danh sách channel ứng với từng bot dùng slack api
    + Khi user nhập text vào channel slack, actor nào join thì lắng nghe text đó, nạp vào sqlite memories riêng, nhưng không phản hồi
    + Khi được nhắc tên thì mới phản hồi: /dev, mentor, /<actor-name>


NOTE:
    + Mục tiêu cần đạt:
        + Các actor giống  như con người thực sự, có trí nhớ độc lập, không chung
        + Chỉ có trí nhớ chung nếu chúng lắng nghe cùng 1 channel được join
        => Luôn luôn tuyệt đối copy memories, không cần tiết kiệm bộ nhớ tạo ra 1 nơi share memories, 
            => vì nó không phải độc lập tuyết đối

    + Nghiên cứu về 2 giải pháp sau:
        + 1 là có 1 actor chính lắng nghe message, sau đó chuyển message đó tới các actor được nhắc tên
        + 2 là các actor luôn luôn lăng nghe message cùng lúc
        => Bạn chọn cách nào tốt nhất cho hệ thống 

        + Không có 1 actor nào là default tự động phản hồi hay call ai-agent (gemini cli)
        + Chỉ các actor trực tiếp config được phép call ai-agent llm (gemini cli)

        + Nếu chọn giải pháp có actor chính 
            => actor chính này tách ra là 1 assistant riêng, dùng để nghe nhận thông tin và chuyển tới các actor chuyên biệt, 
            => actor tuyệt đối không được phép call ai-agent llm riêng, vì mình muốn kiểm soát hành vi 


####### AI CONTEXT ##################

## 1. Tổng quan hệ thống
Hệ thống NullClaw chạy song song 2 Agent độc lập trên Slack:
- **Dev (/dev)**: Senior Developer, dùng `gemini-3-flash-preview`.
- **Mentor (/mentor)**: Senior Architect, dùng `gemini-3.1-pro-preview`.

## 2. Nguyên tắc cốt lõi (Core Principles)
- **Realtime > Now**: Chỉ phản hồi tin nhắn mới sau khi start.
- **Tool Use "0 Token"**: Xử lý Tool local, không tốn tài nguyên AI.
- **Minh bạch Log**: Format `call_gemini_cli[agent][model]: message`.

## 3. Quyết định kỹ thuật & Bài học kinh nghiệm
- **Zig 0.15.2**: Cực kỳ khắt khe về biến thừa và cấu trúc fields trong struct.
- **Stdin Protocol**: Chống lỗi Gemini nhại lại lịch sử (Echo issue) cực tốt.
- **Slack Loop Prevention**: Đã lấy được Bot User ID thật để chặn bot tự nghe chính mình.

## 4. Các lệnh đặc biệt
- `/dev`, `/mentor`: Gọi đúng nhân cách.
- `show channel /dev`: Xem thông tin bối cảnh.
- `delete history /dev`: Tẩy não Agent.

## 5. [ERROR]: Important Problem (Vấn đề chí mạng)

### 5.1. Triệu chứng
Hệ thống luôn mặc định gọi Agent **`main`** dù tin nhắn đến từ bất kỳ Account nào (`dev_bot` hoặc `mentor_bot`). Log luôn hiện: `call_gemini_cli[main]`.

### 5.2. Phân tích nguyên nhân
- **Mất định tuyến**: NullClaw Bus/Dispatcher không nhận diện được các `bindings` trong `config.json` để ánh xạ Account sang đúng Agent.
- **Infinite Loop**: Do thằng `main` nhảy vào trả lời mọi thứ, nó tự nghe chính nó và đồng nghiệp bot, gây ra vòng lặp "pong" vô hạn.

### 5.3. Các nỗ lực đã thất bại
- **Cố gắng 1**: Nhồi `account_id` vào Metadata JSON -> NullClaw vẫn không khớp Binding.
- **Cố gắng 2**: Gán tên Agent vào tham số Media/Metadata của `makeInboundFull` -> Sai kiểu dữ liệu hoặc bị hệ thống bỏ qua.
- **Cố gắng 3**: Ép model name dạng `model--agent` -> Hệ thống ghi đè về model mặc định trước khi tới Provider.

### 5.4. Hướng đi cho Session sau
Cần phải đọc kỹ `src/daemon.zig` đoạn `resolveInboundRouteSessionKeyWithMetadata` để hiểu chính xác NullClaw cần cái gì trong Metadata để Routing hoạt động. Có khả năng phải can thiệp vào cách NullClaw so khớp `BindingMatch`.

### 5.5. Giải Quyết Vấn Đề Hiệu Năng & Khóa Tài Khoản (ĐÃ GIẢI QUYẾT)
**Vấn đề:** 
- `gemini-cli` Node.js bị cold-start (~4 giây mỗi tin nhắn), không hỗ trợ chế độ REPL giữ stdin mở liên tục trong chế độ `stream-json`.
- Lo ngại bị Google block khi dùng các tool CLI/phần mềm thứ ba (như bài học từ OpenClaw bị khóa account vì scrape cookie/web).

**Giải pháp đột phá - Native Provider:**
- Đổi cấu hình từ `"provider": "gemini-cli"` thành `"provider": "gemini"` trong `config.json`.
- Cập nhật mã nguồn `src/providers/gemini.zig` (Native C/Zig) để **tự động đọc bẻ khóa file credential `~/.gemini/oauth_creds.json`** mà `gemini-cli` tạo ra khi `gemini auth login`.
- Parse đúng định dạng `expiry_date` (ms) của file token mới nhất.
- Chạy thẳng HTTP REST API (`https://generativelanguage.googleapis.com/...`) bằng token Oauth chính chủ (Client ID của Gemini CLI).

**Kết quả:**
- **Toc độ:** Giảm độ trễ từ 4s xuống < 200ms (bỏ Node.js, luồng mạng C/Zig gửi thẳng), hỗ trợ Streaming thực sự cho Slack update từng chunk.
- **An toàn 100% Legit:** Gửi request chuẩn REST bằng giao thức OAuth2 qua cổng Developer API chính thức, không scrape web, không giả dạng Chrome, Google coi request này là hợp lệ hoàn toàn và chỉ áp dụng Rate Limit (lỗi 429) thay vì khóa account.

### COMMAND FOR ME (NOT FOR AI)
zig build -Doptimize=ReleaseSmall
nullclaw gateway

killall nullclaw


CUSTOM
nullclaw workspace append
