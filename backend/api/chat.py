import json

from fastapi import APIRouter
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from ..chat import agent
from ..services import audit

router = APIRouter(prefix="/api", tags=["chat"])


class ChatRequest(BaseModel):
    message: str
    session_id: str | None = None  # omit to start a new conversation


@router.post("/chat")
async def chat(request: ChatRequest) -> StreamingResponse:
    """Stream the agent's answer as Server-Sent Events (see backend/chat/agent.py)."""
    session_id = request.session_id or agent.new_session()

    async def events():
        async for event in agent.chat(session_id, request.message):
            yield f"event: {event['type']}\ndata: {json.dumps(event, ensure_ascii=False, default=str)}\n\n"

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@router.post("/demo/reset")
def reset_demo() -> dict:
    """Clear AI analyses, findings and conversations so the demo can replay the full flow."""
    audit.reset_ai_output()
    agent.SESSIONS.clear()
    return {"ok": True}
