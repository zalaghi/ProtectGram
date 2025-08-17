# ProtectGram — UniFi Protect → Telegram Snapshots (v1.1.4)

**Docker image:** `docker.io/zalaghi/protectgram:latest`

Create a **view-only** local user in UniFi for selected cameras, then run this webhook to send snapshots to Telegram.

## Quick Start (public Docker image)
```bash
mkdir -p ~/protectgram && cd ~/protectgram
curl -fsSLO https://raw.githubusercontent.com/<your-gh-user>/unifi-protect-telegram-webhook/main/compose.image.yml
curl -fsSLO https://raw.githubusercontent.com/<your-gh-user>/unifi-protect-telegram-webhook/main/.env.example
cp .env.example .env && nano .env
export IMAGE_REF=docker.io/zalaghi/protectgram:latest
docker compose -f compose.image.yml up -d
```

## Minimal run
```bash
docker run -d --name protectgram   --restart unless-stopped   --env-file .env   -p 8080:8080   docker.io/zalaghi/protectgram:latest
```

## Build locally (optional)
```bash
docker build -t youruser/protectgram:dev .
docker run -d --name protectgram --restart unless-stopped --env-file .env -p 8080:8080 youruser/protectgram:dev
```

## Webhook for UniFi Automations (POST)
```
http://<SERVER_IP>:8080/hook/by-id/<CAM_ID>?token=<WEBHOOK_TOKEN>&hq=true&stamp=1&stamp_tz=Europe/Madrid&caption=Front%20Door
```

## Test
```bash
curl -s "http://127.0.0.1:8080/cameras?token=$WEBHOOK_TOKEN" | jq
curl -s "http://127.0.0.1:8080/test/text?token=$WEBHOOK_TOKEN&text=Hello" > /dev/null
```
