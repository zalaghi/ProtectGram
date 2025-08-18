# ProtectGram — UniFi Protect → Telegram Snapshots

ProtectGram listens for **webhooks** from UniFi Protect Automations and sends a **snapshot** from the triggered camera to **Telegram**.

## Why this exists
- Keep UniFi credentials off your phone.
- Get pictures in Telegram for motion/AI/person events (or any Protect trigger).
- Simple to run: a single Docker container. The installer even builds and starts it for you.

---

## Features
- **Webhook endpoints** that accept triggers from UniFi Protect.
- Sends **snapshot photos** to Telegram with an optional **timestamp overlay**.
- **Camera discovery**: robust across Protect API variants (`/proxy/protect/api/cameras`, `bootstrap`, or `v1/cameras`).
- Fixed names:
  - Docker **container name**: `protectgram`
  - Local image tag (when built): `protectgram:latest`
- Built-in health endpoint and clean logs.
- **No API key** needed — uses a **dedicated read-only UniFi user** (recommended).

---

## Quick start (Debian 12+ host)
```bash
unzip unifi-protect-telegram-webhook-v1.1.2-github-cleanup-HOTFIX5-with-README.zip
cd unifi-protect-telegram-webhook-v1.1.2-github-cleanup-HOTFIX5-with-README
sudo bash scripts/install.sh
```
Follow the prompts:
- UniFi address (e.g., `https://unvr.local` or `https://192.168.1.2`)
- UniFi username/password (create a **read-only** account that can view selected cameras)
- Telegram bot token (from @BotFather) and your chat ID
- Timezone (for timestamp overlay)
- Port (default 8080)

The installer will:
1) Clean up any old containers/images named `protectgram` or older names.
2) Build & start the container.
3) Query cameras and show you a list to choose from.
4) Generate **ready-to-paste Webhook URLs** and save them in `webhook_urls.txt`.
5) (Optional) Send test snapshots to Telegram.

---

## UniFi Protect setup
- In **Protect → Automations** (or your NVR’s alarm manager),
  - Action: **Webhook**
  - Method: **POST**
  - URL: take one from `webhook_urls.txt` (the **By ID** URL is recommended).

Each URL looks like:
```
http://YOUR_SERVER_IP:8080/hook/by-id/<CAMERA_ID>?token=<WEBHOOK_TOKEN>&hq=true&stamp=1&stamp_tz=Europe/Madrid&caption=Motion%20on%20Door
```
**Parameters you can tweak**
- `hq=true|false`: high-quality snapshot via the v1 path if available.
- `stamp=1`: overlay timestamp in the bottom-left.
- `stamp_tz=Europe/Madrid`: timezone for the overlay.
- `stamp_fmt=%Y-%m-%d %H:%M:%S %Z`: (optional) custom timestamp format.
- `caption=...`: Telegram caption (URL-encoded).

---

## Endpoints (served by the container)
- `GET /health` → `{"ok": true}` when configured.
- `GET /cameras?token=...` → returns camera list (id, name, model).
- `GET /test/text?token=...&text=Hello` → send a test text to Telegram.
- `POST /hook/by-id/<camera_id>?token=...&hq=1&stamp=1&stamp_tz=Europe/Madrid&caption=...` → send snapshot.
- `POST /hook/<camera_name>?token=...&...` → same but camera matched by name.

---

## Environment variables (`.env`)
```ini
UNIFI_ADDR=https://10.0.0.5
UNIFI_USERNAME=your_user
UNIFI_PASSWORD=your_password
TELEGRAM_TOKEN=123456:ABCDEF
TELEGRAM_CHAT=123456789
WEBHOOK_TOKEN=choose-a-strong-random-string
SERVICE_PORT=8080
STAMP_TZ=Europe/Madrid
```

> **Security tips**
> - Always set `WEBHOOK_TOKEN` (it’s included in generated URLs).
> - Use a **dedicated read-only UniFi account** that can only view the cameras you need.
> - If exposing to the internet, put this behind a reverse proxy with HTTPS and IP allowlists (e.g., Nginx, Caddy, Cloudflare Tunnel).

---

## Local development
- Build and run:
  ```bash
  docker compose up -d --build
  docker logs -f protectgram
  ```
- Health & cameras:
  ```bash
  curl -fsS http://127.0.0.1:8080/health | jq
  curl -fsS "http://127.0.0.1:8080/cameras?token=$WEBHOOK_TOKEN" | jq
  ```

---

## Troubleshooting
- `curl: (56) Recv failure` right after start → the service may not be ready yet. The installer retries; you can retry a second later.
- `ERROR: No cameras returned` → check UniFi credentials, controller address, and that your account has permission to view those cameras. Also verify the controller is reachable from the server.
- Telegram not receiving images → confirm `TELEGRAM_TOKEN` and `TELEGRAM_CHAT`, and that your bot can DM you (send `/start` to your bot).
- Logs:
  ```bash
  docker logs --since=5m protectgram
  ```

---

## License
MIT
