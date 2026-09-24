"""Tools the chat agent can call. The model reaches the database only through
these fixed tools (no free-form SQL), and none of them reads the ground truth.

Tools use strict schemas so inputs always validate: every property is required
and optional values are nullable.
"""

import json

from .. import queries
from ..services import audit, call_analysis
from ..services.llm import MODEL

_STR = {"type": "string"}
_INT = {"type": "integer"}
_DATE = {"type": ["string", "null"], "description": "YYYY-MM-DD, or null for no limit."}
_CODE = {"anyOf": [{"type": "string", "enum": call_analysis.COVERAGE_CODES}, {"type": "null"}],
         "description": "Coverage code (e.g. RENTAL), or null for all coverages."}


def _tool(name: str, description: str, **properties) -> dict:
    return {
        "name": name,
        "description": description,
        "strict": True,
        "input_schema": {"type": "object", "properties": properties,
                         "required": list(properties), "additionalProperties": False},
    }


TOOLS = [
    _tool("find_policy",
          "Validate that a member number and policy number belong together. Returns the member, policy, "
          "current term, drivers, vehicles and coverages in force today. Call this first.",
          member_number=_STR, policy_number=_STR),
    _tool("get_policy_changes",
          "Policy transactions (NEW_BUSINESS / ADD / REMOVE / MODIFY) with their six-month term, channel "
          "(PHONE / APP / WEB), exact old/new rental tier and deductible, and the source call recorded by "
          "the policy system (a hint only).",
          policy_number=_STR, coverage_code=_CODE,
          change_type={"anyOf": [{"type": "string", "enum": ["NEW_BUSINESS", "ADD", "REMOVE", "MODIFY"]},
                                 {"type": "null"}]},
          date_from=_DATE, date_to=_DATE),
    _tool("get_coverages",
          "Coverage rows of a policy. With as_of, only those in force on that date (use it to check what the "
          "policy showed after a call); without it, the full history with effective dates.",
          policy_number=_STR, coverage_code=_CODE, as_of=_DATE),
    _tool("list_calls",
          "All member calls on a policy in a date range, whether or not they led to a transaction.",
          policy_number=_STR, date_from=_DATE, date_to=_DATE),
    _tool("find_calls_for_change",
          "Calls on the same policy within ±window_days of a transaction (default 30).",
          transaction_id=_INT, window_days={"type": ["integer", "null"]}),
    _tool("get_transcript",
          "Full transcript of a call: every turn with seq, speaker (MEMBER / AGENT), m:ss timestamp and text.",
          call_id=_INT),
    _tool("analyze_call",
          "AI analysis of a call: summary, highlights, sentiment per speaker, changes the member requested "
          "(with final decision) and promises the agent made, each tied to a turn. Cached after the first run.",
          call_id=_INT),
    _tool("record_audit_finding",
          "Store one audit verdict so it appears in the reviewer's findings panel. Use transaction_id null "
          "when nothing was applied, call_id null when no call supports the change, and segment_seq for the "
          "turn that proves it.",
          policy_number=_STR,
          verdict={"type": "string", "enum": list(audit.VERDICTS)},
          coverage_code=_CODE,
          transaction_id={"type": ["integer", "null"]},
          call_id={"type": ["integer", "null"]},
          segment_seq={"type": ["integer", "null"]},
          requested={"type": ["string", "null"], "description": "What was asked or promised on the call."},
          applied={"type": ["string", "null"], "description": "What the policy records show."},
          explanation=_STR),
]

# Status line the UI shows while each tool runs.
LABELS = {
    "find_policy": "Validating member and policy",
    "get_policy_changes": "Reading policy transactions",
    "get_coverages": "Checking coverages",
    "list_calls": "Listing member calls",
    "find_calls_for_change": "Finding calls around the change",
    "get_transcript": "Reading call transcript",
    "analyze_call": "Analyzing call",
    "record_audit_finding": "Recording audit finding",
}


class ToolError(Exception):
    pass


async def run_tool(name: str, args: dict) -> object:
    match name:
        case "find_policy":
            return queries.find_policy(**args)
        case "get_policy_changes":
            return queries.get_policy_changes(**args)
        case "get_coverages":
            return queries.get_coverages(**args)
        case "list_calls":
            return queries.list_calls(**args)
        case "find_calls_for_change":
            return queries.find_calls_for_change(args["transaction_id"], args["window_days"] or 30)
        case "get_transcript":
            if not (transcript := queries.get_transcript(args["call_id"])):
                raise ToolError(f"No call {args['call_id']}.")
            return transcript
        case "analyze_call":
            try:
                return await call_analysis.analyze_call(args["call_id"])
            except LookupError as e:
                raise ToolError(str(e)) from e
        case "record_audit_finding":
            try:
                return audit.record_finding(**args, model=MODEL)
            except audit.InvalidFinding as e:
                raise ToolError(str(e)) from e
    raise ToolError(f"Unknown tool {name}.")


def ui_event(name: str, args: dict, result: object) -> dict | None:
    """Extra event for the UI panels, sent after a tool succeeds."""
    if name == "find_policy" and isinstance(result, dict) and result.get("found"):
        return {"type": "policy", "policy_number": args["policy_number"]}
    if name in ("get_transcript", "analyze_call"):
        return {"type": "call", "call_id": args["call_id"]}
    if name == "record_audit_finding":
        return {"type": "finding", "finding": result}
    return None


def to_json(result: object) -> str:
    return json.dumps(result, ensure_ascii=False, default=str)
