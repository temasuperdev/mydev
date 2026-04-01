from fastapi import FastAPI

app = FastAPI(title="Simple App")

@app.get("/")
def read_root():
    return {"message": "Hello from k3s with Traefik!"}

@app.get("/health")
def health():
    return {"status": "ok"}