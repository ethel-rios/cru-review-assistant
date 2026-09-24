"""Split a Whisper transcript into MEMBER / AGENT turns.

Whisper does not tell speakers apart, so its segments can mix both voices
(e.g. "Sure. It's Fanny Rios. Thank you, Fanny."). This script rebuilds the
turns from word timestamps, given the second at which each speaker starts.
For now the speaker changes are marked by hand; in the app, Claude will
label them (see README, "Speaker labels").

Usage:  python scripts/label_speakers.py
Reads data/transcripts/call_008.json, writes data/transcripts/call_008.turns.json
and prints the call_segments rows for data/schema.sql.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSCRIPT = ROOT / "data" / "transcripts" / "call_008.json"
CALL_ID = 7

# (second the speaker starts talking, speaker)
SPEAKER_CHANGES = [
    (0.0, "AGENT"), (5.0, "MEMBER"), (14.5, "AGENT"), (22.4, "MEMBER"),
    (24.3, "AGENT"), (27.4, "MEMBER"), (32.7, "AGENT"), (55.4, "MEMBER"),
    (58.7, "AGENT"), (75.3, "MEMBER"), (83.9, "AGENT"), (97.0, "MEMBER"),
]

# Speech-to-text errors fixed by hand: the audio names a model that does not exist
CORRECTIONS = {"CX3O": "EX30", "CX30": "EX30", "CX-30": "EX30"}


def speaker_at(sec: float) -> str:
    return [spk for start, spk in SPEAKER_CHANGES if start <= sec][-1]


def build_turns(transcript: dict) -> list[dict]:
    turns: list[dict] = []
    for seg in transcript["segments"]:
        for w in seg["words"]:
            spk = speaker_at(w["start"])
            if not turns or turns[-1]["speaker"] != spk:
                turns.append({"speaker": spk, "start_sec": w["start"], "end_sec": w["end"], "text": ""})
            turns[-1]["end_sec"] = w["end"]
            turns[-1]["text"] += w["word"]
    for t in turns:
        text = t["text"].strip()
        for wrong, right in CORRECTIONS.items():
            text = text.replace(wrong, right)
        t["text"] = text
    return turns


def main() -> None:
    transcript = json.loads(TRANSCRIPT.read_text(encoding="utf-8"))
    turns = build_turns(transcript)
    out = TRANSCRIPT.with_suffix(".turns.json")
    out.write_text(json.dumps({"call_id": CALL_ID, "source": transcript["model"], "turns": turns},
                              indent=2, ensure_ascii=False), encoding="utf-8")
    rows = [
        f"({CALL_ID},{i},{t['start_sec']},{t['end_sec']},'{t['speaker']}','{t['text'].replace(chr(39), chr(39) * 2)}')"
        for i, t in enumerate(turns, 1)
    ]
    print(",\n".join(rows) + ";")


if __name__ == "__main__":
    main()
