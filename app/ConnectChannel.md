# Hướng dẫn kết nối Slack Channel cho NullClaw

Tài liệu này hướng dẫn cách cấu hình Slack Bot ở chế độ **Socket Mode** để hỗ trợ đa bot (Dev/Mentor) chạy song song và độc lập tuyệt đối.

## 1. Tạo Slack App (Manifest)

Truy cập [Slack App Dashboard](https://api.slack.com/apps) và chọn **Create New App** > **From an app manifest**. Sử dụng nội dung sau để cấu hình nhanh:

```json
{
    "display_information": {
        "name": "NullClaw Assistant",
        "description": "AI Assistant powered by NullClaw",
        "background_color": "#1a1a1a"
    },
    "features": {
        "bot_user": {
            "display_name": "Assistant",
            "always_online": true
        }
    },
    "oauth_config": {
        "scopes": {
            "bot": [
                "channels:history",
                "groups:history",
                "im:history",
                "chat:write",
                "app_mentions:read"
            ]
        }
    },
    "settings": {
        "event_subscriptions": {
            "bot_events": [
                "message.channels",
                "message.groups",
                "message.im",
                "app_mention"
            ]
        },
        "org_deploy_enabled": false,
        "socket_mode_enabled": true,
        "token_rotation_enabled": false
    }
}
```

## 2. Lấy thông tin xác thực

Sau khi tạo App, bạn cần lấy 2 loại mã (Token):

1.  **Bot User OAuth Token (`xoxb-...`)**:
    *   Vào mục **OAuth & Permissions**.
    *   Nhấn **Install to Workspace**.
    *   Copy mã `xoxb-...`.

2.  **App-level Token (`xapp-...`)**:
    *   Vào mục **Basic Information**.
    *   Kéo xuống phần **App-level Tokens**.
    *   Nhấn **Generate Token and Scopes**.
    *   Thêm scope `connections:write`.
    *   Copy mã `xapp-...`.

## 3. Cấu hình đa Bot song song (Dev & Mentor)

Để chạy 2 bot cùng lúc trên Slack và đảm bảo chúng không tranh việc của nhau, cấu hình file `~/.nullclaw/config.json` như sau:

```json
{
  "channels": {
    "slack": {
      "accounts": {
        "dev_bot": {
          "bot_token": "xoxb-TOKEN-CỦA-BOT-DEV",
          "app_token": "xapp-TOKEN-CỦA-BOT-DEV",
          "group_policy": "open",
          "allow_from": ["*"]
        },
        "mentor_bot": {
          "bot_token": "xoxb-TOKEN-CỦA-BOT-MENTOR",
          "app_token": "xapp-TOKEN-CỦA-BOT-MENTOR",
          "group_policy": "open",
          "allow_from": ["*"]
        }
      }
    }
  }
}
```

## 4. Cách sử dụng trên Slack

Sau khi khởi động `nullclaw gateway`, bạn mời cả 2 bot vào channel bằng lệnh `/invite`.

*   **Gọi Dev**: Gõ bất kỳ câu nào có chứa `/dev` (ví dụ: `/dev viết code Zig cho tôi`).
*   **Gọi Mentor**: Gõ bất kỳ câu nào có chứa `/mentor` (ví dụ: `/mentor định hướng sự nghiệp`).
*   **Cùng lúc**: Gõ `/dev /mentor chào hai đứa`. Cả 2 bot sẽ nhảy vào trả lời song song ngay lập tức.

## 5. Lưu ý kỹ thuật

*   Mỗi bot sẽ khởi tạo một **Instance Gemini CLI** riêng biệt (`--session dev` và `--session mentor`).
*   Trí nhớ được lưu trữ độc lập trong SQLite, đảm bảo ngữ cảnh không bị lẫn lộn giữa các vai trò.
*   Hệ thống sử dụng **Socket Mode** nên không cần mở port trên Router hay dùng ngrok.
