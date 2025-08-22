# ProtectGram — UniFi Protect → Telegram Snapshot Webhook (v1.1.2-github-HOTFIX7)

This version keeps the **cookie‑first auth + auto re‑login on 401/403** fix and
adds an installer flow that **runs with `docker run -e ...`** on a VPS and **writes `.env` at the END** for your records (and optional compose later).

## Option A — Docker Hub (recommended)
```bash
TOKEN=$(openssl rand -hex 16)
docker rm -f protectgram 2>/dev/null || true
docker run -d \
  --name protectgram \
  --restart unless-stopped \
  -p 8080:8080 \
  -e UNIFI_ADDR="https://10.0.0.5" \
  -e UNIFI_USERNAME="unifi_user_readonly" \
  -e UNIFI_PASSWORD="your_password" \
  -e TELEGRAM_TOKEN="123456:ABCDEF" \
  -e TELEGRAM_CHAT="123456789" \
  -e WEBHOOK_TOKEN="$TOKEN" \
  -e STAMP_TZ="Europe/Madrid" \
  zalaghi/protectgram:1.1.2-hotfix7
```

## Option B — Installer (VPS, prompts then writes `.env` at the END)
```bash
sudo bash scripts/install.sh
# It will: ask for envs → docker run -e ... → print webhook URLs → write .env at the END
```

## Print Webhook URLs later
```bash
scripts/protectgram-urls.sh --port 8080 --token $TOKEN
```

