from fastapi import FastAPI

app = FastAPI(title="My FastAPI App")

@app.get("/")
def read_root():
    return {"message": "Hello from K3s!"}

@app.get("/health")
def health():
    return {"status": "ok"}