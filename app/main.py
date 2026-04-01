import os
import socket
import datetime
from fastapi import FastAPI

app = FastAPI(title="K8s Pod Info App")

# Получаем имя пода (Kubernetes устанавливает HOSTNAME)
POD_NAME = os.environ.get('HOSTNAME', socket.gethostname())

# Получаем IP (пробуем через переменную окружения, если нет – через сокет)
POD_IP = os.environ.get('POD_IP')
if not POD_IP:
    try:
        POD_IP = socket.gethostbyname(POD_NAME)
    except:
        POD_IP = 'unknown'

# Дополнительные метаданные из Downward API (если они заданы)
POD_NAMESPACE = os.environ.get('POD_NAMESPACE', 'default')
POD_LABELS = os.environ.get('POD_LABELS', 'none')
POD_ANNOTATIONS = os.environ.get('POD_ANNOTATIONS', 'none')

# Версия приложения
VERSION = "1.0.0"
START_TIME = datetime.datetime.now().isoformat()

@app.get("/")
def root():
    return {
        "pod": POD_NAME,
        "ip": POD_IP,
        "message": "Hello from k3s with Traefik!"
    }

@app.get("/whoami")
def whoami():
    return {
        "pod": POD_NAME,
        "ip": POD_IP,
        "namespace": POD_NAMESPACE,
        "version": VERSION
    }

@app.get("/info")
def full_info():
    return {
        "pod": {
            "name": POD_NAME,
            "ip": POD_IP,
            "namespace": POD_NAMESPACE,
            "labels": POD_LABELS,
            "annotations": POD_ANNOTATIONS
        },
        "app": {
            "version": VERSION,
            "started_at": START_TIME
        },
        "hostname": socket.gethostname(),
        "environment": dict(os.environ)
    }

@app.get("/health")
def health():
    return {"status": "ok"}