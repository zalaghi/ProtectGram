FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends fonts-dejavu-core curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/app.py ./app.py
LABEL org.opencontainers.image.title="ProtectGram — UniFi Protect → Telegram Snapshots"       org.opencontainers.image.description="Webhook service that sends UniFi Protect snapshots to Telegram"       org.opencontainers.image.url="https://github.com/your-user/unifi-protect-telegram-webhook"       org.opencontainers.image.source="https://github.com/your-user/unifi-protect-telegram-webhook"       org.opencontainers.image.licenses="MIT"
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5   CMD curl -fsS http://127.0.0.1:${PORT}/health | grep -q '"ok": true' || exit 1
CMD ["python", "app.py"]
