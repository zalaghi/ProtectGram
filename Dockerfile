FROM python:3.11-slim
ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /app
RUN apt-get update -y && apt-get install -yq --no-install-recommends fonts-dejavu-core curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/app.py ./app.py
ENV PORT=8080
EXPOSE 8080
CMD ["python", "app.py"]
