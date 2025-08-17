# ProtectGram — UniFi Protect → Telegram Snapshots
Public image: `docker.io/zalaghi/protectgram:latest`

## Quick Start
```bash
mkdir -p ~/protectgram && cd ~/protectgram
cat > .env <<'ENV'
UNIFI_ADDR=https://unvr.local
UNIFI_USERNAME=telegram-snapshot
UNIFI_PASSWORD=********
TELEGRAM_TOKEN=123456:ABCDEF...
TELEGRAM_CHAT=123456789
WEBHOOK_TOKEN=some-long-random-string
SERVICE_PORT=8080
STAMP_TZ=Europe/Madrid
ENV

docker run -d --name protectgram   --restart unless-stopped   --env-file .env   -p 8080:8080   docker.io/zalaghi/protectgram:latest
```
