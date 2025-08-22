FROM python:3.11-slim
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app
RUN apt-get update -y && apt-get install -yq --no-install-recommends fonts-dejavu-core curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/app.py ./app.py
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5   CMD curl -fsS http://127.0.0.1:${PORT}/health | grep -q '"ok": true' || exit 1
CMD ["python", "app.py"]
