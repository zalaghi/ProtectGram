#!/usr/bin/env bash
set -Eeuo pipefail
PORT="${PORT:-8080}"
TOKEN="${TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  echo "Set TOKEN env to your WEBHOOK_TOKEN"; exit 1
fi
if [[ "${1:-}" == "--list" ]]; then
  curl -fsS "http://127.0.0.1:${PORT}/cameras?token=${TOKEN}" | python3 -c 'import sys,json;d=json.load(sys.stdin);[print("*",c.get("name"),"— id:",c.get("id")) for c in d.get("cameras",[])]'
  exit 0
fi
if [[ "${1:-}" == "--text" ]]; then
  shift
  TEXT="${*:-Hello from ProtectGram}"
  curl -fsS "http://127.0.0.1:${PORT}/test/text?token=${TOKEN}&text=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$TEXT")" | jq
  exit 0
fi
echo "Usage: $0 --list | --text \"message\""
