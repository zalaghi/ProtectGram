#!/usr/bin/env bash
# Installer for ProtectGram HOTFIX6
set -Eeuo pipefail
b_red=$'\e[1;31m'; b_grn=$'\e[1;32m'; b_cyn=$'\e[1;36m'; rst=$'\e[0m'
die(){ echo "${b_red}ERROR:${rst} $*" >&2; }
need_root(){ [[ $EUID -eq 0 ]] || { die "Run as root (sudo)."; exit 1; }; }
DEBIAN_FRONTEND=noninteractive

global_cleanup(){
  echo "${b_cyn}[0/9] Preflight: removing previous ProtectGram containers/images/networks…${rst}"
  docker rm -f protectgram >/dev/null 2>&1 || true
  docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}' | \
    awk 'tolower($0) ~ /(unifi-protect-telegram-webhook|protectgram)/ {print $1}' | \
    xargs -r docker rm -f >/dev/null 2>&1 || true
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' | \
    awk 'tolower($0) ~ /(unifi-protect-telegram-webhook|protectgram)/ {print $2}' | \
    xargs -r docker rmi -f >/dev/null 2>&1 || true
  docker network ls --format '{{.Name}}' | \
    awk 'tolower($0) ~ /(unifi-protect-telegram-webhook|protectgram)/ {print $1}' | \
    xargs -r docker network rm >/dev/null 2>&1 || true
  if [[ -f docker-compose.yml ]]; then
    local touched_env=""
    [[ -f .env ]] || { : > .env; touched_env="yes"; }
    docker compose down -v --remove-orphans --rmi local >/dev/null 2>&1 || true
    [[ "$touched_env" == "yes" ]] && rm -f .env
  fi
  docker builder prune -f >/dev/null 2>&1 || true
  docker image prune -f >/dev/null 2>&1 || true
  echo "${b_grn}Cleanup complete.${rst}"
}

need_root
. /etc/os-release || true

global_cleanup

echo "${b_cyn}[1/9] Installing deps & Docker…${rst}"
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y ca-certificates curl gnupg jq python3 python3-venv openssl >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME:-bookworm} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

echo "${b_cyn}[2/9] Collecting config…${rst}"
read -rp "UniFi address (https://10.0.0.5 or https://unvr.local): " UNIFI_ADDR; UNIFI_ADDR="${UNIFI_ADDR%/}"
read -rp "UniFi Username: " UNIFI_USERNAME
read -rsp "UniFi Password: " UNIFI_PASSWORD; echo

TZ_DEFAULT="$(cat /etc/timezone 2>/dev/null || echo Europe/Madrid)"
read -rp "Timezone for timestamp overlay [${TZ_DEFAULT}]: " STAMP_TZ
STAMP_TZ="${STAMP_TZ:-$TZ_DEFAULT}"

read -rp "Telegram Bot Token: " TELEGRAM_TOKEN
read -rp "Telegram Chat ID: " TELEGRAM_CHAT
read -rp "Webhook shared token (blank=random): " WEBHOOK_TOKEN || true
[[ -n "${WEBHOOK_TOKEN:-}" ]] || WEBHOOK_TOKEN="$(openssl rand -hex 16)"
echo "Webhook token will be: ${WEBHOOK_TOKEN}"
read -rp "Service port [8080]: " SERVICE_PORT || true; SERVICE_PORT="${SERVICE_PORT:-8080}"

cat > .env <<ENV
UNIFI_ADDR=${UNIFI_ADDR}
UNIFI_USERNAME=${UNIFI_USERNAME}
UNIFI_PASSWORD=${UNIFI_PASSWORD}
TELEGRAM_TOKEN=${TELEGRAM_TOKEN}
TELEGRAM_CHAT=${TELEGRAM_CHAT}
WEBHOOK_TOKEN=${WEBHOOK_TOKEN}
SERVICE_PORT=${SERVICE_PORT}
STAMP_TZ=${STAMP_TZ}
ENV

echo "${b_cyn}[3/9] Building/starting container…${rst}"
docker compose up -d --build

echo "${b_cyn}[4/9] Waiting for service to be ready…${rst}"
BASE_WEBHOOK="http://127.0.0.1:${SERVICE_PORT}"
ready="no"
for i in {1..25}; do
  RESP="$(curl -fsS --max-time 2 --retry 10 --retry-delay 1 --retry-all-errors "${BASE_WEBHOOK}/health" 2>/dev/null || true)"
  OK=$(jq -r 'try .ok catch "false"' <<<"$RESP" 2>/dev/null || echo "false")
  if [[ "$OK" == "true" ]]; then ready="yes"; break; fi
  sleep 1
done
[[ "$ready" == "yes" ]] || echo "Service not confirmed yet; continuing…"

echo "${b_cyn}[5/9] Fetching cameras…${rst}"
RESP="$(curl -fsS "${BASE_WEBHOOK}/cameras?token=${WEBHOOK_TOKEN}" || true)"
USE_FALLBACK="yes"
if [[ -n "$RESP" ]]; then
  OK=$(jq -r 'try .ok catch "false"' <<<"$RESP" 2>/dev/null || echo "false")
  if [[ "$OK" == "true" ]]; then
    CAMERAS_JSON="$(jq -c '.cameras' <<<"$RESP")"
    USE_FALLBACK="no"
  fi
fi

if [[ "$USE_FALLBACK" == "yes" ]]; then
  echo "Service camera listing failed; logging in and querying Protect API directly…"
  tmpjar="$(mktemp)"
  curl -sSk -c "$tmpjar" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${UNIFI_USERNAME}\",\"password\":\"${UNIFI_PASSWORD}\"}" \
    "${UNIFI_ADDR}/api/auth/login" >/dev/null || true

  CAM_RAW=""
  for ep in /proxy/protect/api/cameras /proxy/protect/api/bootstrap /proxy/protect/v1/cameras; do
    r="$(curl -sSk -b "$tmpjar" "${UNIFI_ADDR}${ep}" || true)"
    if [[ -n "$r" && "$r" != "null" ]]; then CAM_RAW="$r"; break; fi
  done
  rm -f "$tmpjar"
  [[ -n "$CAM_RAW" ]] || { echo "ERROR: Could not retrieve cameras. Check address/credentials."; exit 1; }

  CAMERAS_JSON="$(
python3 - <<'PY'
import sys, json
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print("[]"); sys.exit(0)

def looks_like_cam(d):
    return isinstance(d, dict) and any(k in d for k in ("id","_id","uuid","mac")) and any(k in d for k in ("name","displayName","marketName","type","modelKey","model"))

def pick_cameras(obj):
    if isinstance(obj, list):
        return [c for c in obj if looks_like_cam(c)]
    if isinstance(obj, dict):
        for k in ("cameras","data","items","results"):
            v = obj.get(k)
            if isinstance(v, list):
                cams = [c for c in v if looks_like_cam(c)]
                if cams: return cams
        for v in obj.values():
            if isinstance(v, list):
                cams = [c for c in v if looks_like_cam(c)]
                if cams: return cams
            if isinstance(v, dict):
                for vv in v.values():
                    if isinstance(vv, list):
                        cams = [c for c in vv if looks_like_cam(c)]
                        if cams: return cams
    return []

cams = pick_cameras(data)
print(json.dumps([
    {
        "id": (c.get("id") or c.get("_id") or c.get("uuid") or c.get("mac")),
        "name": (c.get("name") or c.get("displayName") or c.get("marketName") or f"camera_{(c.get('mac') or c.get('id') or c.get('uuid') or 'unknown')}"),
        "model": (c.get("marketName") or c.get("type") or c.get("modelKey") or c.get("model") or "camera"),
    } for c in cams if isinstance(c, dict)
]))
PY
<<<"$CAM_RAW")"
fi

# Render URLs
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}'); LOCAL_IP=${LOCAL_IP:-127.0.0.1}
BASE_URL="http://${LOCAL_IP}:${SERVICE_PORT}"
export BASE_URL WEBHOOK_TOKEN STAMP_TZ CAMERAS_JSON
python3 - <<'PY' | tee webhook_urls.txt
import os, json, urllib.parse
BASE = os.environ.get("BASE_URL","")
TOKEN = os.environ.get("WEBHOOK_TOKEN","")
STAMP_TZ = os.environ.get("STAMP_TZ","Europe/Madrid")
cams = json.loads(os.environ.get("CAMERAS_JSON","[]"))
def enc(s): return urllib.parse.quote(str(s), safe="")
for c in cams:
    cid = c.get("id") or c.get("_id") or c.get("uuid") or c.get("mac")
    name = c.get("name") or c.get("displayName") or c.get("marketName") or "camera"
    model = c.get("model") or c.get("marketName") or c.get("type") or c.get("modelKey") or "camera"
    caption = f"Motion on {name}"
    by_id = f"{BASE}/hook/by-id/{cid}?token={enc(TOKEN)}&hq=true&stamp=1&stamp_tz={enc(STAMP_TZ)}&caption={enc(caption)}"
    by_nm = f"{BASE}/hook/{enc(name)}?token={enc(TOKEN)}&hq=true&stamp=1&stamp_tz={enc(STAMP_TZ)}&caption={enc(caption)}"
    print(f"• {name} — id: {cid} ({model})")
    print(f"  By ID (recommended): {by_id}")
    print(f"  By Name            : {by_nm}\\n")
PY

echo "${b_cyn}[6/9] Sending test text to Telegram…${rst}"
curl -fsS "http://127.0.0.1:${SERVICE_PORT}/test/text?token=${WEBHOOK_TOKEN}&text=ProtectGram%20is%20ready%20✅" >/dev/null || true

echo "${b_cyn}[7/9] Where to paste the webhook URLs…${rst}"
echo "Protect → Automations → your rule → Action: Webhook (POST) → paste a By-ID URL from webhook_urls.txt"

echo "${b_cyn}[8/9] Print webhook URLs…${rst}"
cat webhook_urls.txt || true

echo "${b_cyn}[9/9] Done.${rst}"
