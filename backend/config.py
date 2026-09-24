"""Settings read from the environment (and .env at the project root)."""

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")


def _path(env: str, default: str) -> Path:
    path = Path(os.getenv(env) or default)
    return path if path.is_absolute() else ROOT / path


@dataclass(frozen=True)
class Settings:
    db_path: Path = _path("DB_PATH", "data/cru.db")
    # calls.audio_file is stored relative to this folder (e.g. "audio/call_008.mp3")
    data_dir: Path = ROOT / "data"
    frontend_dir: Path = ROOT / "frontend"
    model: str = os.getenv("CLAUDE_MODEL") or "claude-opus-5"
    # Rehearse the demo with simulated Claude responses (no API calls)
    mock_claude: bool = os.getenv("MOCK_CLAUDE") == "1"


settings = Settings()
