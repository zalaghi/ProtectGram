#!/usr/bin/env bash
# Print ProtectGram webhook URLs without jq
set -Eeuo pipefail
HOST="${HOST:-}"
PORT="${PORT:-8080}"
TOKEN="${TOKEN:-}"
TZ="${STAMP_TZ:-Europe/Madrid}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --tz|--stamp-tz) TZ="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "$HOST" ]]; then
  HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$HOST" ]] || HOST="127.0.0.1"
fi

[[ -n "$TOKEN" ]] || { echo "ERROR: set --token or TOKEN=..."; exit 1; }

BASE="http://${HOST}:${PORT}"
for i in {1..10}; do curl -fsS --max-time 2 "${BASE}/health" >/dev/null 2>&1 && break || sleep 1; done
CAMS_JSON="$(curl -fsS "${BASE}/cameras?token=${TOKEN}" || true)"
python3 - <<PY | tee webhook_urls.txt
import os, sys, json, urllib.parse
BASE = {BASE!r}
TOKEN = {TOKEN!r}
TZ = {TZ!r}
try:
    data = json.loads({CAMS_JSON!r})
    cams = data.get("cameras") or []
except Exception as e:
    print("ERROR parsing cameras:", e, file=sys.stderr); cams=[]
def enc(s): return urllib.parse.quote(str(s), safe="")
for c in cams:
    if not isinstance(c, dict): continue
    cid = c.get("id") or c.get("_id") or c.get("uuid") or c.get("mac")
    name = c.get("name") or c.get("displayName") or c.get("marketName") or "camera"
    model = c.get("marketName") or c.get("type") or c.get("modelKey") or c.get("model") or "camera"
    caption = f"Motion on {name}"
    by_id = f"{BASE}/hook/by-id/{cid}?token={enc(TOKEN)}&hq=1&stamp=1&stamp_tz={enc(TZ)}&caption={enc(caption)}"
    by_nm = f"{BASE}/hook/{enc(name)}?token={enc(TOKEN)}&hq=1&stamp=1&stamp_tz={enc(TZ)}&caption={enc(caption)}"
    print(f"• {name} — id: {cid} ({model})")
    print(f"  By ID (recommended): {by_id}")
    print(f"  By Name            : {by_nm}\\n")
PY
echo; echo "Saved to: $(pwd)/webhook_urls.txt"
