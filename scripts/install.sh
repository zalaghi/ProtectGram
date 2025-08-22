#!/usr/bin/env bash
# Installer for ProtectGram HOTFIX7
# - Prompts for envs
# - Runs container with `docker run -e ...` (no compose)
# - At the END: writes a .env file for your records/compose (optional)
set -Eeuo pipefail
b_red=$'\e[1;31m'; b_grn=$'\e[1;32m'; b_cyn=$'\e[1;36m'; rst=$'\e[0m'
die(){ echo "${b_red}ERROR:${rst} $*" >&2; exit 1; }
ask(){ local p="$1" d="$2" v; read -rp "$p [$d]: " v; printf '%s' "${v:-$d}"; }
ask_secret(){ local p="$1" d="$2" v; read -rsp "$p [$d]: " v; echo; printf '%s' "${v:-$d}"; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
DEBIAN_FRONTEND=noninteractive

# Ensure we run from project root (write .env here at the END)
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || die "Cannot cd to project dir: $PROJECT_DIR"

echo "${b_cyn}[0/8] Preflight: removing old container…${rst}"
docker rm -f protectgram >/dev/null 2>&1 || true
docker network ls --format '{{.Name}}' | awk 'tolower($0) ~ /(unifi-protect-telegram-webhook|protectgram)/ {print $1}' | xargs -r docker network rm >/dev/null 2>&1 || true

echo "${b_cyn}[1/8] Installing minimal deps (Debian/Ubuntu only)…${rst}"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl python3 openssl jq >/dev/null 2>&1 || true
fi

echo "${b_cyn}[2/8] Collecting configuration…${rst}"
DEF_UNIFI_ADDR="https://10.0.0.5"
DEF_UNAME="unifi_user_readonly"
DEF_UPASS=""
DEF_TG_TOKEN=""
DEF_TG_CHAT=""
DEF_TOKEN="$(openssl rand -hex 16)"
DEF_PORT="8080"
DEF_TZ="$(cat /etc/timezone 2>/dev/null || echo Europe/Madrid)"
DEF_TAG="1.1.2-hotfix7"

UNIFI_ADDR="$(ask "UniFi address (https://unvr.local or https://10.0.0.5)" "$DEF_UNIFI_ADDR")"
UNIFI_USERNAME="$(ask "UniFi username" "$DEF_UNAME")"
UNIFI_PASSWORD="$(ask_secret "UniFi password" "$DEF_UPASS")"
TELEGRAM_TOKEN="$(ask "Telegram bot token" "$DEF_TG_TOKEN")"
TELEGRAM_CHAT="$(ask "Telegram chat ID" "$DEF_TG_CHAT")"
WEBHOOK_TOKEN="$(ask "Webhook shared token (blank=random)" "$DEF_TOKEN")"
SERVICE_PORT="$(ask "Service port" "$DEF_PORT")"
STAMP_TZ="$(ask "Timestamp timezone" "$DEF_TZ")"
IMAGE_TAG="$(ask "Docker image tag (latest or 1.1.2-hotfix7)" "$DEF_TAG")"

echo
echo "${b_cyn}Summary:${rst}"
echo "  UNIFI_ADDR     = ${UNIFI_ADDR}"
echo "  UNIFI_USERNAME = ${UNIFI_USERNAME}"
echo "  UNIFI_PASSWORD = (hidden)"
echo "  TELEGRAM_TOKEN = ${TELEGRAM_TOKEN}"
echo "  TELEGRAM_CHAT  = ${TELEGRAM_CHAT}"
echo "  WEBHOOK_TOKEN  = ${WEBHOOK_TOKEN}"
echo "  STAMP_TZ       = ${STAMP_TZ}"
echo "  SERVICE_PORT   = ${SERVICE_PORT}"
echo "  IMAGE TAG      = ${IMAGE_TAG}"
read -rp "Is this correct? [y/N]: " OK
[[ "${OK,,}" == "y" || "${OK,,}" == "yes" ]] || die "Aborted."

echo "${b_cyn}[3/8] Pulling image zalaghi/protectgram:${IMAGE_TAG}…${rst}"
docker pull "zalaghi/protectgram:${IMAGE_TAG}" >/dev/null

echo "${b_cyn}[4/8] Starting container…${rst}"
docker run -d \
  --name protectgram \
  --restart unless-stopped \
  -p "${SERVICE_PORT}:8080" \
  -e UNIFI_ADDR="${UNIFI_ADDR%/}" \
  -e UNIFI_USERNAME="${UNIFI_USERNAME}" \
  -e UNIFI_PASSWORD="${UNIFI_PASSWORD}" \
  -e TELEGRAM_TOKEN="${TELEGRAM_TOKEN}" \
  -e TELEGRAM_CHAT="${TELEGRAM_CHAT}" \
  -e WEBHOOK_TOKEN="${WEBHOOK_TOKEN}" \
  -e STAMP_TZ="${STAMP_TZ}" \
  "zalaghi/protectgram:${IMAGE_TAG}" >/dev/null

echo "${b_cyn}[5/8] Waiting for service to be ready…${rst}"
for i in {1..30}; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SERVICE_PORT}/health" || true)"
  if [[ "$code" == "200" ]]; then break; fi
  sleep 1
done

echo "${b_cyn}[6/8] Fetching cameras and printing webhook URLs…${rst}"
CAMS="$(curl -fsS "http://127.0.0.1:${SERVICE_PORT}/cameras?token=${WEBHOOK_TOKEN}" || true)"
python3 - <<PY | tee webhook_urls.txt
import os, json, urllib.parse
BASE = f"http://{os.environ.get('HOST','127.0.0.1')}:{os.environ.get('SERVICE_PORT','8080')}"
TOKEN = {WEBHOOK_TOKEN!r}
TZ = {STAMP_TZ!r}
try:
    data=json.loads('''{CAMS}''')
    cams=data.get("cameras") or []
except Exception as e:
    print("No cameras:", e); cams=[]
def enc(s): return urllib.parse.quote(str(s), safe="")
for c in cams:
    if not isinstance(c, dict): continue
    cid = c.get("id") or c.get("_id") or c.get("uuid") or c.get("mac")
    name = c.get("name") or c.get("displayName") or c.get("marketName") or "camera"
    model = c.get("model") or c.get("marketName") or c.get("type") or c.get("modelKey") or "camera"
    cap = f"Motion on {name}"
    by_id = f"{BASE}/hook/by-id/{cid}?token={enc(TOKEN)}&hq=1&stamp=1&stamp_tz={enc(TZ)}&caption={enc(cap)}"
    by_nm = f"{BASE}/hook/{enc(name)}?token={enc(TOKEN)}&hq=1&stamp=1&stamp_tz={enc(TZ)}&caption={enc(cap)}"
    print(f"• {name} — id: {cid} ({model})")
    print(f"  By ID (recommended): {by_id}")
    print(f"  By Name            : {by_nm}\\n")
PY

echo "${b_cyn}[7/8] Writing .env for your records (compose optional)…${rst}"
cat > .env <<ENV
UNIFI_ADDR=${UNIFI_ADDR%/}
UNIFI_USERNAME=${UNIFI_USERNAME}
UNIFI_PASSWORD=${UNIFI_PASSWORD}
TELEGRAM_TOKEN=${TELEGRAM_TOKEN}
TELEGRAM_CHAT=${TELEGRAM_CHAT}
WEBHOOK_TOKEN=${WEBHOOK_TOKEN}
SERVICE_PORT=${SERVICE_PORT}
STAMP_TZ=${STAMP_TZ}
ENV
echo "${b_grn}Saved ${PROJECT_DIR}/.env${rst}"
echo "You can later use:  docker compose up -d   (compose file is included, uses image tag 1.1.2-hotfix7)"

echo
echo "${b_grn}Done.${rst} Webhook URLs saved to ./webhook_urls.txt"
echo "Paste a By-ID URL into Protect → Automations → Webhook (POST)."
