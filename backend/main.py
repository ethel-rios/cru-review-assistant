"""CRU Review Assistant API.

Run:  .venv/Scripts/python -m uvicorn backend.main:app --reload
Docs: http://127.0.0.1:8000/docs
"""

import mimetypes

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from .api import calls, chat, policies
from .config import settings
from .services import audit
from .services.llm import MODEL

if not settings.mock_claude:
    audit.forget_simulated_output()

app = FastAPI(title="CRU Review Assistant")
app.include_router(policies.router)
app.include_router(calls.router)
app.include_router(chat.router)


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "model": MODEL, "db": settings.db_path.name}


# The single-page UI (frontend/index.html). Windows can map .js to text/plain,
# which browsers refuse for ES modules.
mimetypes.add_type("text/javascript", ".js")
mimetypes.add_type("text/css", ".css")
if settings.frontend_dir.is_dir():
    app.mount("/", StaticFiles(directory=settings.frontend_dir, html=True), name="frontend")
