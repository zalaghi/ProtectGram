#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .env ]]; then echo ".env missing"; exit 1; fi
source ./.env
BASE="http://127.0.0.1:${SERVICE_PORT:-8080}"
case "${1:-}" in
  --list) curl -fsS "${BASE}/cameras?token=${WEBHOOK_TOKEN}" | jq -r '.cameras[] | "* \(.name) — id: \(.id)"' ;;
  --text) shift; curl -fsS "${BASE}/test/text?token=${WEBHOOK_TOKEN}&text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "${1:-Hello}")" >/dev/null && echo "Sent";;
  *) echo "Usage: bash scripts/test.sh --list | --text \"Hello\"";;
esac
