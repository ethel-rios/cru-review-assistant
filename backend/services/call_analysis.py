"""Call analysis with Claude: summary, highlights, sentiment, requested changes and
agent promises. Results are cached in call_analysis so the demo can replay them."""

import json

from .. import queries
from ..db import rows, write_conn
from .llm import FALLBACK, MODEL, ClaudeRefusal, client, require_credentials

COVERAGE_CODES = [r["code"] for r in rows("SELECT code FROM coverage_catalog ORDER BY code")]
_CODE = {"anyOf": [{"type": "string", "enum": COVERAGE_CODES}, {"type": "null"}]}
_SPEAKER = {"type": "string", "enum": ["MEMBER", "AGENT"]}


def _object(**properties) -> dict:
    return {"type": "object", "properties": properties,
            "required": list(properties), "additionalProperties": False}


def _list(item: dict) -> dict:
    return {"type": "array", "items": item}


SCHEMA = _object(
    summary={"type": "string"},
    highlights=_list(_object(seq={"type": "integer"}, speaker=_SPEAKER,
                             quote={"type": "string"}, why={"type": "string"})),
    sentiment=_object(
        member_overall={"type": "string", "enum": ["positive", "neutral", "negative", "mixed"]},
        agent_overall={"type": "string", "enum": ["positive", "neutral", "negative", "mixed"]},
        timeline=_list(_object(seq={"type": "integer"}, speaker=_SPEAKER,
                               sentiment={"type": "string", "enum": ["positive", "neutral", "negative"]})),
    ),
    requested_changes=_list(_object(
        seq={"type": "integer"}, coverage_code=_CODE,
        action={"type": "string", "enum": ["ADD", "REMOVE", "MODIFY", "INQUIRY"]},
        detail={"type": "string"},
        final_decision={"type": "string", "enum": ["CONFIRMED", "WITHDRAWN", "UNDECIDED"]},
    )),
    agent_promises=_list(_object(seq={"type": "integer"}, coverage_code=_CODE, detail={"type": "string"})),
)

SYSTEM = """You analyze recorded member calls for the USAA Coverage Response Unit (CRU), which audits \
auto-policy coverage changes against what members asked for on the phone.

Given one call transcript, return:
- summary: 2-3 sentences on why the member called and how the call ended.
- highlights: the few turns a CRU reviewer must hear (requests, decisions, promises, disclosures), \
quoting the transcript exactly.
- sentiment: overall for each speaker, plus one timeline point per turn.
- requested_changes: every coverage change or coverage question the member raised. A request the member \
later takes back is WITHDRAWN; the final version they agree to is CONFIRMED.
- agent_promises: every change the agent says they made or will make.

Reference turns by their seq number. Use coverage codes from the catalog below. Describe rental \
reimbursement by tier and vehicle class, never by car makes or models.

Coverage catalog: """ + ", ".join(COVERAGE_CODES)


def _render(transcript: dict) -> str:
    header = (f"Call {transcript['call_id']} on policy {transcript['policy_number']}, "
              f"{transcript['call_datetime']}, agent {transcript['agent_name']}.")
    lines = [f"#{t['seq']} [{t['timestamp']}] {t['speaker']}: {t['text']}" for t in transcript["turns"]]
    return header + "\n\n" + "\n".join(lines)


async def analyze_call(call_id: int, force: bool = False) -> dict:
    if not force and (cached := queries.get_call_analysis(call_id)):
        return {**cached, "cached": True}
    transcript = queries.get_transcript(call_id)
    if not transcript:
        raise LookupError(f"No call {call_id}.")
    require_credentials()

    response = await client.beta.messages.create(
        model=MODEL,
        max_tokens=16000,
        system=SYSTEM,
        output_config={"format": {"type": "json_schema", "schema": SCHEMA}},
        messages=[{"role": "user", "content": _render(transcript)}],
        **FALLBACK,
    )
    if response.stop_reason == "refusal":
        raise ClaudeRefusal(f"Claude declined to analyze call {call_id}.")
    analysis = json.loads(next(b.text for b in response.content if b.type == "text"))

    # Attach segment ids and timestamps so the UI can seek the audio.
    by_seq = {t["seq"]: t for t in transcript["turns"]}
    for item in analysis["highlights"] + analysis["requested_changes"] + analysis["agent_promises"]:
        turn = by_seq.get(item["seq"])
        item["segment_id"] = turn["segment_id"] if turn else None
        item["start_sec"] = turn["start_sec"] if turn else None
        item["timestamp"] = turn["timestamp"] if turn else None

    with write_conn() as conn:
        conn.execute(
            """INSERT OR REPLACE INTO call_analysis
               (call_id, summary, highlights, sentiment, requested_changes, agent_promises, model)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (call_id, analysis["summary"], json.dumps(analysis["highlights"]),
             json.dumps(analysis["sentiment"]), json.dumps(analysis["requested_changes"]),
             json.dumps(analysis["agent_promises"]), response.model),
        )
    return {**queries.get_call_analysis(call_id), "cached": False}
