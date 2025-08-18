#!/usr/bin/env bash
# v1.1.2 (cleanup rev) — Debian 12+
set -Eeuo pipefail
b_red=$'\e[1;31m'; b_grn=$'\e[1;32m'; b_cyn=$'\e[1;36m'; rst=$'\e[0m'
die(){ echo "${b_red}ERROR:${rst} $*" >&2; }
need_root(){ [[ $EUID -eq 0 ]] || { die "Run as root (sudo)."; exit 1; }; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
urlencode(){ python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

global_cleanup(){
  echo
  # Prefer explicit kill of the canonical container name first
  docker rm -f protectgram >/dev/null 2>&1 || true
  echo "Checked existing 'protectgram' container."
  echo "${b_cyn}[0/9] Preflight: removing previous ProtectGram/UniFi webhook containers…${rst}"
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
apt_install ca-certificates curl gnupg jq python3 python3-venv openssl
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME:-bookworm} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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
sleep 1
ready="no"
for i in {1..240}; do
  RESP="$(curl -fs "${BASE_WEBHOOK}/health" 2>/dev/null || true)"
  OK=$(jq -r 'try .ok catch "false"' <<<"$RESP" 2>/dev/null || echo "false")
  if [[ "$OK" == "true" ]]; then ready="yes"; break; fi
  sleep 0.5
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
  CAM_RAW="$(curl -sSk -b "$tmpjar" "${UNIFI_ADDR}/proxy/protect/api/cameras" || true)"
  rm -f "$tmpjar"
  [[ -n "$CAM_RAW" ]] || { die "Could not retrieve cameras. Check address/credentials."; exit 1; }
  CAMERAS_JSON="$(python3 - <<'PY'
import sys, json
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print("[]"); sys.exit(0)
def normalize(d):
    if isinstance(d, list): return d
    if isinstance(d, dict):
        for k in ("cameras","data","items","results"):
            v = d.get(k)
            if isinstance(v, list): return v
        vals = list(d.values())
        if all(isinstance(v, dict) for v in vals):
            return vals
    return []
out = []
for c in normalize(data):
    if not isinstance(c, dict): continue
    cid = c.get("id") or c.get("_id") or c.get("uuid") or c.get("mac")
    name = c.get("name") or c.get("displayName") or c.get("marketName") or f"camera_{(c.get('mac') or c.get('id') or c.get('uuid') or 'unknown')}"
    model = c.get("marketName") or c.get("type") or c.get("modelKey") or c.get("model") or "camera"
    out.append({"id": cid, "name": name, "model": model})
print(json.dumps(out))
PY
<<<"$CAM_RAW")"
fi

mapfile -t IDS   < <(jq -r '.[].id'   <<<"$CAMERAS_JSON")
mapfile -t NAMES < <(jq -r '.[].name' <<<"$CAMERAS_JSON")
mapfile -t MODELS< <(jq -r '.[].model'<<<"$CAMERAS_JSON")

(( ${#IDS[@]} )) || { die "No cameras returned."; exit 1; }

echo "${b_grn}Found cameras:${rst}"
for i in "${!IDS[@]}"; do
  printf "  [%d] %s — id: %s (%s)\n" "$i" "${NAMES[$i]}" "${IDS[$i]}" "${MODELS[$i]}"
done

read -rp "Enter camera number(s) (comma-separated): " SELECTION
SELECTION="${SELECTION// /}"
IFS=',' read -ra IDX <<< "$SELECTION"
SELECTED_IDS=(); SELECTED_NAMES=()
for s in "${IDX[@]}"; do 
  if [[ ! "$s" =~ ^[0-9]+$ ]]; then die "Bad index: $s"; exit 1; fi
  if (( s >= ${#IDS[@]} )); then die "Index out of range: $s"; exit 1; fi
  SELECTED_IDS+=("${IDS[$s]}"); SELECTED_NAMES+=("${NAMES[$s]}")
done

LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
BASE_URL="http://${LOCAL_IP:-127.0.0.1}:${SERVICE_PORT}"

echo "${b_cyn}[6/9] Webhook URLs (use in UniFi › Automations › Webhook)…${rst}"
: > webhook_urls.txt
for i in "${!SELECTED_IDS[@]}"; do
  id="${SELECTED_IDS[$i]}"; name="${SELECTED_NAMES[$i]}"
  cap="$(urlencode "Motion on ${name}")"
  u1="${BASE_URL}/hook/by-id/${id}?token=${WEBHOOK_TOKEN}&hq=true&stamp=1&stamp_tz=$(urlencode "${STAMP_TZ}")&caption=${cap}"
  u2="${BASE_URL}/hook/$(urlencode "${name}")?token=${WEBHOOK_TOKEN}&hq=true&stamp=1&stamp_tz=$(urlencode "${STAMP_TZ}")&caption=${cap}"
  echo "• ${name}" | tee -a webhook_urls.txt
  echo "  By ID (recommended): ${u1}" | tee -a webhook_urls.txt
  echo "  By Name            : ${u2}" | tee -a webhook_urls.txt
done

echo "${b_cyn}[7/9] (Optional) Send TEST snapshots now…${rst}"
read -rp "Send TEST snapshot to Telegram for each selected camera? [y/N]: " DO_TEST
DO_TEST="${DO_TEST:-N}"
if [[ "${DO_TEST,,}" == "y" ]]; then
  for i in "${!SELECTED_IDS[@]}"; do
    id="${SELECTED_IDS[$i]}"; name="${SELECTED_NAMES[$i]}"
    cap="$(urlencode "Test snapshot: ${name}")"
    echo "→ Testing ${name}…"
    curl -fsS -X POST "${BASE_WEBHOOK}/hook/by-id/${id}?token=${WEBHOOK_TOKEN}&hq=true&stamp=1&stamp_tz=$(urlencode "${STAMP_TZ}")&caption=${cap}" >/dev/null \
      && echo "  ${b_grn}Sent.${rst}" || echo "  ${b_red}Failed.${rst}"
  done
fi

echo "${b_cyn}[8/9] Final steps (copy to UniFi Automations):${rst}"
echo "  1) UniFi Protect → Automations → Your rule → Action: Webhook → Method: POST"
echo "  2) Paste URL from 'webhook_urls.txt' (By ID recommended)."
echo "  3) Save. Trigger your rule to verify."
echo "To see the webhook URLs again later, run:  cat webhook_urls.txt"
echo "Tip: send a text ping anytime:"
echo "  curl -fsS \"${BASE_WEBHOOK}/test/text?token=${WEBHOOK_TOKEN}&text=Hello\""

echo -e "\n${b_grn}Done.${rst}  Logs:  docker compose logs -f"
