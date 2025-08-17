#!/usr/bin/env bash
# Host-mode installer (kept for users who prefer host docker-compose build)
set -Eeuo pipefail
b_cyn=$'\e[1;36m'; b_grn=$'\e[1;32m'; b_red=$'\e[1;31m'; rst=$'\e[0m'
die(){ echo "${b_red}ERROR:${rst} $*" >&2; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
urlenc(){ python3 - <<'PY' "$1"; import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1])); PY
}
need_root(){ [[ $EUID -eq 0 ]] || { die "Run as root (sudo)."; exit 1; }; }

need_root
echo "${b_cyn}[1/3] Installing Docker if missing…${rst}"
apt-get update -y >/dev/null 2>&1 || true
apt_install ca-certificates curl gnupg jq python3 python3-venv openssl
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

echo "${b_cyn}[2/3] Create .env…${rst}"
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Edit .env before starting the service."
fi
echo "${b_cyn}[3/3] Start (image mode)…${rst}"
export IMAGE_REF=${IMAGE_REF:-docker.io/zalaghi/protectgram:latest}
docker compose -f compose.image.yml up -d
echo "${b_grn}Done. URLs in webhook_urls.txt are created by the interactive build installer, or construct them from /cameras and /hook endpoints.${rst}"
