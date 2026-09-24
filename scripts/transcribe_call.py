"""Transcribe a call recording with local Whisper (faster-whisper).

Usage:  python scripts/transcribe_call.py data/audio/call_008.mp3

Writes data/transcripts/<name>.json with timestamped segments. The model is
downloaded once into models/ (git-ignored) and runs offline afterwards.
"""

import json
import sys
import time
from pathlib import Path

from faster_whisper import WhisperModel

ROOT = Path(__file__).resolve().parent.parent
MODEL = "small.en"
OUT_DIR = ROOT / "data" / "transcripts"


def transcribe(audio: Path) -> dict:
    model = WhisperModel(MODEL, device="cpu", compute_type="int8",
                         download_root=str(ROOT / "models"))
    started = time.time()
    segments, info = model.transcribe(str(audio), language="en", beam_size=5,
                                      word_timestamps=True)
    result = {
        "audio_file": audio.relative_to(ROOT / "data").as_posix(),
        "model": f"whisper-{MODEL}",
        "duration_sec": round(info.duration, 2),
        "segments": [
            {
                "start_sec": round(s.start, 2),
                "end_sec": round(s.end, 2),
                "text": s.text.strip(),
                "words": [{"start": round(w.start, 2), "end": round(w.end, 2), "word": w.word}
                          for w in s.words],
            }
            for s in segments
        ],
    }
    result["elapsed_sec"] = round(time.time() - started, 1)
    return result


def main() -> None:
    audio = (ROOT / sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "data/audio/call_008.mp3"
    result = transcribe(audio)
    OUT_DIR.mkdir(exist_ok=True)
    out = OUT_DIR / f"{audio.stem}.json"
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    for s in result["segments"]:
        print(f"[{s['start_sec']:6.2f}-{s['end_sec']:6.2f}] {s['text']}")
    print(f"\n{len(result['segments'])} segments, {result['duration_sec']} s audio, "
          f"{result['elapsed_sec']} s to transcribe -> {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
