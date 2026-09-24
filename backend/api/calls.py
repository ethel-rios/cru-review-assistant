import anthropic
from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from .. import queries
from ..config import settings
from ..services import call_analysis
from ..services.llm import ClaudeRefusal, MissingCredentials

router = APIRouter(prefix="/api/calls", tags=["calls"])


def _call_or_404(call_id: int) -> dict:
    if not (call := queries.get_call(call_id)):
        raise HTTPException(404, f"No call {call_id}.")
    return call


@router.get("/{call_id}")
def get_call(call_id: int) -> dict:
    """Call header plus its cached AI analysis (null until analyzed)."""
    return {**_call_or_404(call_id), "analysis": queries.get_call_analysis(call_id)}


@router.get("/{call_id}/transcript")
def get_transcript(call_id: int) -> dict:
    """Full transcript for the "Open full transcript" view."""
    _call_or_404(call_id)
    return queries.get_transcript(call_id)


@router.get("/{call_id}/audio")
def get_audio(call_id: int) -> FileResponse:
    _call_or_404(call_id)
    if not (audio_file := queries.audio_path(call_id)):
        raise HTTPException(404, f"Call {call_id} has no recording (scripted transcript).")
    data_dir = settings.data_dir.resolve()
    path = (data_dir / audio_file).resolve()
    if not path.is_relative_to(data_dir) or not path.is_file():
        raise HTTPException(404, f"Recording for call {call_id} not found.")
    return FileResponse(path, media_type="audio/mpeg")


@router.post("/{call_id}/analyze")
async def analyze(call_id: int, force: bool = False) -> dict:
    _call_or_404(call_id)
    try:
        return await call_analysis.analyze_call(call_id, force=force)
    except ClaudeRefusal as e:
        raise HTTPException(422, str(e)) from e
    except MissingCredentials as e:
        raise HTTPException(503, str(e)) from e
    except anthropic.AuthenticationError as e:
        raise HTTPException(503, "Claude API credentials are missing or invalid.") from e
    except anthropic.APIError as e:
        raise HTTPException(502, f"Claude API error: {e}") from e
