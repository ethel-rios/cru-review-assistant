"""Read-only queries over the CRU database, shared by the REST API and the chatbot tools.

Nothing here reads the ground-truth tables (expected_call_events,
v_expected_cru_evidence): the chatbot has to reach its own conclusions.
"""

import json
from datetime import date

from .db import one, rows


def timestamp(sec: float) -> str:
    sec = int(sec)
    return f"{sec // 60}:{sec % 60:02d}"


# ---------------------------------------------------------------- policies

def find_policy(member_number: str, policy_number: str) -> dict:
    """Validate that the member owns the policy and return its current picture."""
    policy = one(
        """SELECT p.id, p.policy_number, p.issue_state, p.start_date, p.term_months, p.status,
                  m.member_number, m.full_name, m.eligibility, m.military_branch, m.state, m.city
           FROM policies p JOIN members m ON m.id = p.member_id
           WHERE p.policy_number = ?""",
        (policy_number,),
    )
    if not policy:
        return {"found": False, "error": f"No policy with number {policy_number}."}
    if policy["member_number"] != member_number:
        # Do not reveal who the policy belongs to.
        return {"found": False, "error": "The member number does not match this policy."}

    today = date.today().isoformat()
    policy_id = policy.pop("id")
    return {
        "found": True,
        "member": {k: policy.pop(k) for k in
                   ("member_number", "full_name", "eligibility", "military_branch", "state", "city")},
        "policy": policy,
        "current_term": one(
            """SELECT term_number, start_date, end_date FROM policy_terms
               WHERE policy_id = ? AND start_date <= ? AND ? < end_date""",
            (policy_id, today, today),
        ),
        "term_count_to_date": one(
            "SELECT COUNT(*) AS n FROM policy_terms WHERE policy_id = ? AND start_date <= ?",
            (policy_id, today),
        )["n"],
        "drivers": rows(
            "SELECT full_name, relationship, added_on, removed_on FROM drivers WHERE policy_id = ?",
            (policy_id,),
        ),
        "vehicles": rows(
            """SELECT id AS vehicle_id, model_year, make, model, body_type, vin, usage, lienholder,
                      added_on, removed_on
               FROM vehicles WHERE policy_id = ? ORDER BY added_on""",
            (policy_id,),
        ),
        "active_coverages": rows(
            """SELECT vehicle, coverage_code, coverage_name, limit_text, deductible, rental_tier,
                      rental_class, effective_from
               FROM v_active_coverages WHERE policy_number = ?
               ORDER BY vehicle, coverage_code""",
            (policy_number,),
        ),
    }


def get_policy_changes(policy_number: str, coverage_code: str | None = None,
                       change_type: str | None = None, date_from: str | None = None,
                       date_to: str | None = None) -> list[dict]:
    sql = "SELECT * FROM v_change_history WHERE policy_number = ?"
    params: list = [policy_number]
    for column, op, value in (("coverage_code", "=", coverage_code), ("change_type", "=", change_type),
                              ("transaction_date", ">=", date_from), ("transaction_date", "<=", date_to)):
        if value:
            sql += f" AND {column} {op} ?"
            params.append(value)
    return rows(sql + " ORDER BY transaction_date, transaction_id", tuple(params))


def get_coverages(policy_number: str, coverage_code: str | None = None,
                  as_of: str | None = None) -> list[dict]:
    """Coverage rows of a policy: the full history, or only those in force on `as_of`."""
    sql = """SELECT c.id AS coverage_id,
                    COALESCE(v.model_year||' '||v.make||' '||v.model, '(policy level)') AS vehicle,
                    c.coverage_code, cc.name AS coverage_name,
                    CASE WHEN rt.code IS NOT NULL
                         THEN printf('$%d/day, $%,d max', rt.daily_limit, rt.max_per_claim)
                         ELSE c.limit_text END AS limit_text,
                    c.deductible, c.rental_tier, rt.vehicle_class AS rental_class,
                    c.effective_from, c.effective_to
             FROM coverages c
             JOIN policies p ON p.id = c.policy_id
             JOIN coverage_catalog cc ON cc.code = c.coverage_code
             LEFT JOIN vehicles v ON v.id = c.vehicle_id
             LEFT JOIN rental_tiers rt ON rt.code = c.rental_tier
             WHERE p.policy_number = ?"""
    params: list = [policy_number]
    if coverage_code:
        sql += " AND c.coverage_code = ?"
        params.append(coverage_code)
    if as_of:
        sql += " AND c.effective_from <= ? AND (c.effective_to IS NULL OR c.effective_to > ?)"
        params += [as_of, as_of]
    return rows(sql + " ORDER BY vehicle, c.coverage_code, c.effective_from", tuple(params))


# ---------------------------------------------------------------- calls

_CALL_COLUMNS = """call_id, policy_number, member_name, call_datetime, agent_name, duration_sec,
                   reason, transcript_source, audio_file IS NOT NULL AS has_audio, turn_count"""


def list_calls(policy_number: str, date_from: str | None = None,
               date_to: str | None = None) -> list[dict]:
    sql = f"""SELECT {_CALL_COLUMNS},
                     EXISTS (SELECT 1 FROM call_analysis a WHERE a.call_id = t.call_id) AS analyzed
              FROM v_call_transcripts t WHERE policy_number = ?"""
    params: list = [policy_number]
    if date_from:
        sql += " AND date(call_datetime) >= ?"
        params.append(date_from)
    if date_to:
        sql += " AND date(call_datetime) <= ?"
        params.append(date_to)
    return rows(sql + " ORDER BY call_datetime", tuple(params))


def find_calls_for_change(transaction_id: int, window_days: int = 30) -> dict:
    """Calls on the same policy within ±window_days of a transaction."""
    txn = one(
        """SELECT t.id, t.policy_id, t.transaction_date, t.source_call_id, p.policy_number
           FROM transactions t JOIN policies p ON p.id = t.policy_id WHERE t.id = ?""",
        (transaction_id,),
    )
    if not txn:
        return {"found": False, "error": f"No transaction {transaction_id}."}
    calls = rows(
        f"""SELECT {_CALL_COLUMNS},
                   CAST(julianday(date(call_datetime)) - julianday(?) AS INTEGER) AS days_from_change
            FROM v_call_transcripts
            WHERE policy_number = ?
              AND date(call_datetime) BETWEEN date(?, ?) AND date(?, ?)
            ORDER BY call_datetime""",
        (txn["transaction_date"], txn["policy_number"],
         txn["transaction_date"], f"-{window_days} days", txn["transaction_date"], f"+{window_days} days"),
    )
    for call in calls:
        call["is_recorded_source_call"] = call["call_id"] == txn["source_call_id"]
    return {"found": True, "transaction_id": transaction_id, "transaction_date": txn["transaction_date"],
            "window_days": window_days, "calls": calls}


def get_call(call_id: int) -> dict | None:
    return one(f"SELECT {_CALL_COLUMNS} FROM v_call_transcripts t WHERE call_id = ?", (call_id,))


def get_transcript(call_id: int) -> dict | None:
    """Call header plus every turn, in order, with timestamps for citations."""
    call = get_call(call_id)
    if not call:
        return None
    turns = rows(
        """SELECT id AS segment_id, seq, start_sec, end_sec, speaker, text
           FROM call_segments WHERE call_id = ? ORDER BY seq""",
        (call_id,),
    )
    for turn in turns:
        turn["timestamp"] = timestamp(turn["start_sec"])
    return {**call, "turns": turns}


def get_call_analysis(call_id: int) -> dict | None:
    found = one("SELECT * FROM call_analysis WHERE call_id = ?", (call_id,))
    if found:
        for key in ("highlights", "sentiment", "requested_changes", "agent_promises"):
            found[key] = json.loads(found[key]) if found[key] else None
    return found


def list_audit_findings(policy_number: str) -> list[dict]:
    return rows(
        """SELECT f.*, s.seq AS segment_seq, s.start_sec, s.speaker, s.text AS quote
           FROM audit_findings f
           JOIN policies p ON p.id = f.policy_id
           LEFT JOIN call_segments s ON s.id = f.segment_id
           WHERE p.policy_number = ? ORDER BY f.id""",
        (policy_number,),
    )


def audio_path(call_id: int) -> str | None:
    found = one("SELECT audio_file FROM calls WHERE id = ?", (call_id,))
    return found["audio_file"] if found else None
