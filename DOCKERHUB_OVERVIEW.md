# ProtectGram — UniFi Protect → Telegram Snapshot Webhook

Send a snapshot from your UniFi Protect camera to Telegram whenever an Automation (motion, AI/person, doorbell ring, etc.) fires. One container exposes webhook endpoints; paste those URLs into Protect Automations.

- **Image:** `zalaghi/protectgram`
- **Tags:** `latest`, `1.1.2-hotfix6`
- **Port:** `8080/tcp`

## Quick start
```bash
TOKEN=$(openssl rand -hex 16)
docker rm -f protectgram 2>/dev/null || true
docker run -d   --name protectgram   --restart unless-stopped   -p 8080:8080   -e UNIFI_ADDR="https://10.0.0.5"   -e UNIFI_USERNAME="unifi_user_readonly"   -e UNIFI_PASSWORD="your_password"   -e TELEGRAM_TOKEN="123456:ABCDEF"   -e TELEGRAM_CHAT="123456789"   -e WEBHOOK_TOKEN="$TOKEN"   -e STAMP_TZ="Europe/Madrid"   zalaghi/protectgram:1.1.2-hotfix6
curl -fsS http://127.0.0.1:8080/health | jq
```
