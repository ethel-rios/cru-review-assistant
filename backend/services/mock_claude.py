"""Simulated Claude for rehearsing the demo without an API key (MOCK_CLAUDE=1).

Stands in for the AsyncAnthropic client: the chat agent, tools, database writes
and UI events all run for real; only the model's decisions are scripted.

- Chat: a fixed review flow (validate -> changes + calls -> transcripts +
  analyses -> coverages -> findings -> answer), with verdicts computed by simple
  rules from the tool results.
- Call analysis: built from the ground truth (expected_call_events). That table
  stays off-limits to the real chatbot; the simulation only uses it to fake
  plausible model output.
"""

import asyncio
import json
import re
from datetime import date
from itertools import count
from types import SimpleNamespace

from anthropic.types.beta import BetaMessage

from ..db import one, rows

COVERAGE_WORDS = {
    "rental": "RENTAL", "transportation": "RENTAL", "collision": "COLL", "deductible": "COLL",
    "comprehensive": "COMP", "roadside": "ROADSIDE", "accident forgiveness": "AF",
    "rideshare": "RSG", "car replacement": "CRA",
}
WINDOW_DAYS = 30
MOCK_MODEL = "mock-claude"  # stored in call_analysis.model / audit_findings.model
_ids = count(1)


def _message(content: list[dict], stop_reason: str) -> BetaMessage:
    return BetaMessage.model_validate({
        "id": f"msg_mock_{next(_ids)}", "type": "message", "role": "assistant", "model": MOCK_MODEL,
        "content": content, "stop_reason": stop_reason, "stop_sequence": None,
        "usage": {"input_tokens": 0, "output_tokens": 0},
    })


def _tool_use(name: str, **args) -> dict:
    return {"type": "tool_use", "id": f"toolu_mock_{next(_ids)}", "name": name, "input": args}


# ---------------------------------------------------------------- call analysis

def _action(description: str) -> str:
    text = description.lower()
    if any(w in text for w in ("upgrade", "lower", "raise")):
        return "MODIFY"
    if "remove" in text:
        return "REMOVE"
    return "ADD" if "add" in text else "MODIFY"


def mock_analysis(call_id: int) -> dict:
    call = one("SELECT reason FROM calls WHERE id = ?", (call_id,))
    events = rows(
        """SELECT e.event_type, e.description, e.coverage_code, s.seq, s.speaker, s.text
           FROM expected_call_events e JOIN call_segments s ON s.id = e.segment_id
           WHERE e.call_id = ? ORDER BY s.seq""",
        (call_id,),
    )
    turns = rows("SELECT seq, speaker FROM call_segments WHERE call_id = ? ORDER BY seq", (call_id,))
    changed_mind = any(e["event_type"] == "CHANGE_OF_MIND" for e in events)
    highlights, requested, promises = [], [], []
    for e in events:
        detail = re.sub(r";\s*NO transaction exists.*", "", e["description"])  # drop ground-truth notes
        highlights.append({"seq": e["seq"], "speaker": e["speaker"], "quote": e["text"], "why": detail})
        if e["event_type"] == "AGENT_PROMISE":
            promises.append({"seq": e["seq"], "coverage_code": e["coverage_code"], "detail": detail})
        elif e["event_type"] == "INQUIRY":
            requested.append({"seq": e["seq"], "coverage_code": e["coverage_code"], "action": "INQUIRY",
                              "detail": detail, "final_decision": "UNDECIDED"})
        else:
            withdrawn = e["event_type"] == "CHANGE_REQUEST" and changed_mind
            requested.append({"seq": e["seq"], "coverage_code": e["coverage_code"], "action": _action(detail),
                              "detail": detail, "final_decision": "WITHDRAWN" if withdrawn else "CONFIRMED"})
    return {
        "summary": f"{call['reason']}. " + " ".join(h["why"] + "." for h in highlights),
        "highlights": highlights,
        "sentiment": {"member_overall": "neutral", "agent_overall": "positive",
                      "timeline": [{"seq": t["seq"], "speaker": t["speaker"], "sentiment": "neutral"}
                                   for t in turns]},
        "requested_changes": requested,
        "agent_promises": promises,
    }


# ---------------------------------------------------------------- chat flow

def _this_turn(messages: list) -> list[tuple[str, dict, object]]:
    """(tool name, input, result) for every tool called since the reviewer's last question."""
    start = max(i for i, m in enumerate(messages) if m["role"] == "user" and isinstance(m["content"], str))
    uses, calls = {}, []
    for m in messages[start + 1:]:
        for block in m["content"]:
            if m["role"] == "assistant" and block.type == "tool_use":
                uses[block.id] = (block.name, block.input)
            elif m["role"] == "user" and block.get("type") == "tool_result":
                name, args = uses[block["tool_use_id"]]
                result = {"error": block["content"]} if block.get("is_error") else json.loads(block["content"])
                calls.append((name, args, result))
    return calls


def _last_step(messages: list) -> set[str]:
    last = messages[-2] if len(messages) >= 2 and messages[-2]["role"] == "assistant" else None
    return {b.name for b in last["content"] if b.type == "tool_use"} if last else set()


def _question(messages: list) -> str:
    return next(m["content"] for m in reversed(messages) if m["role"] == "user" and isinstance(m["content"], str))


def _cite(call_id: int, item: dict) -> str:
    return f"[Call {call_id} · {item['timestamp']}]"


def _change_text(txn: dict) -> str:
    if txn["old_rental_tier"] or txn["new_rental_tier"]:
        return f"{txn['old_rental_tier'] or 'none'} → {txn['new_rental_tier'] or 'removed'}"
    if txn["old_deductible"] is not None:
        return f"deductible ${txn['old_deductible']:,} → ${txn['new_deductible']:,}"
    return txn["new_value_text"] or txn["old_value_text"] or ""


def _findings(policy_number: str, changes: list, calls: list, analyses: dict, coverages: list) -> tuple[list, list]:
    """Verdicts by simple rules: (record_audit_finding inputs, context notes)."""
    findings, notes = [], []
    call_dates = {c["call_id"]: date.fromisoformat(c["call_datetime"][:10]) for c in calls}

    def near(call_id: int, day: str) -> bool:
        return abs((call_dates[call_id] - date.fromisoformat(day)).days) <= WINDOW_DAYS

    def finding(verdict, coverage_code, transaction_id, call_id, item, requested, applied, explanation):
        findings.append({"policy_number": policy_number, "verdict": verdict, "coverage_code": coverage_code,
                         "transaction_id": transaction_id, "call_id": call_id,
                         "segment_seq": item["seq"] if item else None,
                         "requested": requested, "applied": applied, "explanation": explanation})

    for txn in changes:
        if txn["change_type"] == "NEW_BUSINESS":
            continue
        if txn["channel"] != "PHONE":
            notes.append(f"[Txn {txn['transaction_id']}] {txn['change_type']} {txn['coverage_code'] or txn['target']} "
                         f"was made by the member via {txn['channel']} — no call needed.")
            continue
        support = [(cid, r) for cid, a in analyses.items() if near(cid, txn["transaction_date"])
                   for r in a["requested_changes"]
                   if r["final_decision"] == "CONFIRMED"
                   and (r["coverage_code"] == txn["coverage_code"] or txn["coverage_code"] is None)]
        if support:
            cid, r = support[-1]
            finding("MATCH", txn["coverage_code"], txn["transaction_id"], cid, r, r["detail"], _change_text(txn),
                    f"{txn['change_type']} {_change_text(txn)} [Txn {txn['transaction_id']}] matches what the "
                    f"member agreed to {_cite(cid, r)}.")
        else:
            finding("NO_CALL_EVIDENCE", txn["coverage_code"], txn["transaction_id"], None, None, None,
                    _change_text(txn), f"Phone change [Txn {txn['transaction_id']}] with no call that supports it.")

    for cid, a in analyses.items():
        for r in a["requested_changes"]:
            if r["final_decision"] == "WITHDRAWN":
                notes.append(f"Call {cid}: {r['detail']} {_cite(cid, r)} — withdrawn on the same call.")
            if r["action"] == "INQUIRY":
                notes.append(f"Call {cid}, question only (no change): {r['detail']} {_cite(cid, r)}.")
            if r["final_decision"] != "CONFIRMED" or r["action"] == "INQUIRY":
                continue
            applied = [t for t in changes if t["coverage_code"] == r["coverage_code"]
                       and near(cid, t["transaction_date"])]
            if applied:
                continue
            promise = next((p for p in a["agent_promises"] if p["coverage_code"] == r["coverage_code"]), None)
            active = [c for c in coverages if c["coverage_code"] == r["coverage_code"]]
            now = (f"{active[0]['rental_tier']} · {active[0]['rental_class']}" if active and active[0]["rental_tier"]
                   else "unchanged") if active else "no active coverage"
            finding("NOT_APPLIED", r["coverage_code"], None, cid, r, r["detail"], f"Still active: {now}",
                    f"{r['detail']} {_cite(cid, r)}"
                    + (f", and the agent promised to process it {_cite(cid, promise)}" if promise else "")
                    + f". No transaction was ever recorded, and the policy still shows {now}.")
    return findings, notes


def _next_turn(messages: list) -> BetaMessage:
    question = _question(messages)
    done = _this_turn(messages)
    last = _last_step(messages)
    result = {name: res for name, _, res in done}

    if not done:
        policy = re.search(r"AUT-\d{7}-\d{4}", question)
        member = re.search(r"\b\d{2}-\d{4}-\d{3}\b|\b\d{6}\b", question.replace(policy.group(), "") if policy else question)
        if not (policy and member):
            return _message([{"type": "text", "text": "To start a CRU review I need both the **member number** "
                              "and the **policy number** (for example `AUT-0123456-7103`, member `123456`)."}],
                            "end_turn")
        return _message([{"type": "text", "text": "I'll start by validating the member and the policy."},
                         _tool_use("find_policy", member_number=member.group(), policy_number=policy.group())],
                        "tool_use")

    policy_number = next(args["policy_number"] for name, args, _ in done if name == "find_policy")
    coverage = next((code for word, code in COVERAGE_WORDS.items() if word in question.lower()), None)

    if last == {"find_policy"}:
        if not result["find_policy"].get("found"):
            return _message([{"type": "text", "text": f"I can't review this policy: {result['find_policy']['error']}"}],
                            "end_turn")
        return _message([_tool_use("get_policy_changes", policy_number=policy_number, coverage_code=coverage,
                                   change_type=None, date_from=None, date_to=None),
                         _tool_use("list_calls", policy_number=policy_number, date_from=None, date_to=None)],
                        "tool_use")
    if "list_calls" in last and result["list_calls"]:
        steps = [_tool_use(name, call_id=c["call_id"]) for c in result["list_calls"]
                 for name in ("get_transcript", "analyze_call")]
        return _message([{"type": "text", "text": f"Found {len(result['list_calls'])} call(s) on this policy. "
                          "Reading and analyzing them."}, *steps], "tool_use")
    if "analyze_call" in last or "list_calls" in last:
        return _message([_tool_use("get_coverages", policy_number=policy_number, coverage_code=coverage,
                                   as_of=date.today().isoformat())], "tool_use")

    analyses = {args["call_id"]: res for name, args, res in done if name == "analyze_call" and "error" not in res}
    findings, notes = _findings(policy_number, result["get_policy_changes"], result["list_calls"], analyses,
                                result["get_coverages"])
    if last == {"get_coverages"} and findings:
        return _message([_tool_use("record_audit_finding", **f) for f in findings], "tool_use")

    member = result["find_policy"]["member"]["full_name"]
    scope = coverage or "all coverages"
    lines = [f"**CRU review · {policy_number} ({member}) · {scope}**", ""]
    lines += [f"- **{f['verdict']}** · {f['coverage_code'] or 'Vehicle'} — {f['explanation']}" for f in findings] \
        or ["- No coverage changes or call requests to audit for this scope."]
    if notes:
        lines += ["", "Context:"] + [f"- {n}" for n in notes]
    lines += ["", "_Simulated response (MOCK_CLAUDE=1)._"]
    return _message([{"type": "text", "text": "\n".join(lines)}], "end_turn")


# ---------------------------------------------------------------- client surface

class _Stream:
    def __init__(self, response: BetaMessage):
        self.response = response

    async def __aenter__(self):
        await asyncio.sleep(0.4)  # feel of a model call
        return self

    async def __aexit__(self, *exc):
        return False

    async def __aiter__(self):
        for block in self.response.content:
            if block.type == "text":
                for word in re.findall(r"\S+\s*", block.text):
                    await asyncio.sleep(0.02)
                    yield SimpleNamespace(type="text", text=word)

    async def get_final_message(self) -> BetaMessage:
        return self.response


class _Messages:
    def stream(self, *, messages: list, **_) -> _Stream:
        return _Stream(_next_turn(messages))

    async def create(self, *, messages: list, **_) -> BetaMessage:
        call_id = int(re.match(r"Call (\d+) on policy", messages[0]["content"]).group(1))
        await asyncio.sleep(0.8)
        return _message([{"type": "text", "text": json.dumps(mock_analysis(call_id))}], "end_turn")


class MockClaude:
    api_key = "mock"
    auth_token = credentials = None

    def __init__(self):
        self.beta = SimpleNamespace(messages=_Messages())
