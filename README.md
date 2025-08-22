# ProtectGram — UniFi Protect → Telegram Snapshot Webhook (v1.1.2-github-HOTFIX6)

**What’s new in HOTFIX6**
- Fixes intermittent **401 Unauthorized** from UniFi Protect by:
  - Preferring **TOKEN cookie** auth for Protect endpoints.
  - **Re‑logging in and retrying once** on 401/403 automatically.
- No changes to your env or API; drop‑in replacement.

## Quick Start
```bash
# Build & run locally
docker compose up -d --build
docker logs -f protectgram

# Health
curl -fsS http://127.0.0.1:8080/health | jq

# List cameras
curl -fsS "http://127.0.0.1:8080/cameras?token=$WEBHOOK_TOKEN" | jq

# Optional: generate Webhook URLs (no jq)
./protectgram-urls.sh  # auto-detects WEBHOOK_TOKEN from container env
```
See **DOCKERHUB_OVERVIEW.md** for copy‑paste instructions for Docker Hub.
