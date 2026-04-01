import socket
from fastapi import FastAPI

app = FastAPI(title="Pod Info App")

@app.get("/")
def root():
    hostname = socket.gethostname()
    return {
        "pod": hostname,
        "message": "Hello from k3s with Traefik!"
    }

@app.get("/whoami")
def whoami():
    hostname = socket.gethostname()
    return {
        "pod": hostname,
        "ip": socket.gethostbyname(hostname)
    }

@app.get("/health")
def health():
    return {"status": "ok"}